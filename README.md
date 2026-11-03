# mythos-harness

[![test](https://github.com/royalskynet/mythos-harness/actions/workflows/test.yml/badge.svg)](https://github.com/royalskynet/mythos-harness/actions/workflows/test.yml)

用 Claude Code 實作 [DeepSeek Harness super-agent](https://x.com/DeepSeekHarness/article/2116857257245987236) 的**雙層架構**：
你跟 **Sonnet** 聊天（Router），它只聊天、派工、轉述：每件事都交給背景 **dispatcher** 子代理，dispatcher 判難度後自己做或**派到背景 Worker**（免費模型層或 `deep-run`），做完由零 token 腳本把結果打回對話。Router 自己不跑指令、不讀檔（派工閘全工具白名單硬擋）。

A Claude Code implementation of the two-layer (Router / Worker) super-agent pattern:
chat with Sonnet; every request goes to a background dispatcher subagent that triages and delegates real work to background workers.

```
你 ──Telegram──▶ Router：Sonnet（只聊天、派工、轉述）
                    │  PreToolUse 派工閘：主 session 只能 Telegram／ToolSearch／TaskStop／背景 dispatcher
                    └─ Agent(dispatcher, 背景) ─▶ dispatcher：判難度、驗收、retry／cancel
                                       ├─ easy ─▶ 自己做
                                       ├─ mid  ─▶ bin/dispatch ─▶ dcq（免費模型層）
                                       └─ hard ─▶ bin/dispatch ─▶ deep-run（背景多步自主）
                                                      ▲
        dispatch-watch（每 2 分、零 token）── 先落 events.jsonl；ACK＝Router 已收到事件，不代表處理完 ──▶ 打回 Router
                       │                 未 ACK 10 分鐘重送、上限 5 次；取消的票不再投遞
                       └─ 終態先投遞，抽查後跑 review-judge（免費模型，timeout 硬砍 90 秒）：ON_TRACK 不打擾 Router
        watchdog（每 5 分）── L0 零 token：死鎖、重送用盡、Router 未回、pending 逾 6 小時、deep 停滯、背景 agent 卡權限 → brief-lines
                      └─ log 錯誤行進待判 → L1 免費模型（每小時上限；白名單→canary→scrub）→ 退路鏈 → 規則表 → 判不了才告警
```

## 對照文章 / Mapping

| 文章模組 | 這裡的實作 |
|---|---|
| 兩層架構（Router 不執行） | `bin/dispatch-gate.mjs`：PreToolUse 全工具白名單，主 session 只放 Telegram 回覆三個工具、ToolSearch、TaskStop、SendMessage 與背景 dispatcher，不靠 prompt 自律（文章 7.1：只靠 prompt 叫自己派工，5 跑 0 次） |
| 何時定方向／宣告完成 | dispatcher（子代理）；`router/ROUTER.md` 是 Router 的規則 |
| Worker 一次性行程 | `bin/dispatch`：mid → `dcq`，hard → `deep-run`，背景跑、Router 不等 |
| 全雙工／async start() | `bin/dispatch-watch`：結果事後打進 Router 的 tmux pane，Router 派完就回去聊天 |
| Watchdog | `dispatch-watch` 停滯／逾時偵測＋`bin/review-judge` 兩段過濾 |
| session 生命週期 | `bin/idle-reset`：每天清晨閒置才 `/clear` |

## 快速開始 / Quick start

需求：macOS、bash、Node ≥ 20、jq、tmux、[Claude Code](https://code.claude.com)。

```bash
git clone https://github.com/royalskynet/mythos-harness && cd mythos-harness
# Worker 層（另兩個公開 repo）：
#   dcq、triage → https://github.com/royalskynet/orchestrator     （放進 PATH）
#   deep-run    → https://github.com/royalskynet/deepclaude-flash （放進 PATH）
# Telegram（可省略）：在 Claude Code 裡 /plugin install telegram@claude-plugins-official，再 /telegram:configure
router/start.sh                      # 不要 Telegram：CHANNELS= router/start.sh
tmux -L mythos attach -t mythos
```

背景監看用 launchd：`bash launchd/install.sh` 把 `launchd/*.plist` 範本的 `__REPO__`／`__HOME__` 換成 clone 位置與家目錄，寫進 `~/Library/LaunchAgents/`（`NO_LOAD=1` 只產檔）。現有三份：`ai.mythos.dispatch-watch`（回報與抽查）、`ai.mythos.watchdog`（卡住偵測）、`ai.mythos.idle-reset`（閒置 `/clear`）。`ONLY=<label>` 只處理那一份。載入要帶完整 service target：`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<label>.plist`。

## 元件 / Components

| 檔案 | 作用 |
|---|---|
| `router/settings.json`、`ROUTER.md`、`start.sh` | Router 層：模型分層、派工閘 hook、Router 規則、tmux 啟動 |
| `bin/dispatch-gate.mjs` | 主 session 全工具白名單（Telegram 只放 reply／react／edit_message）；子代理不能直接回 Telegram；pinGuard、fail-closed |
| `bin/lib-ledger.sh`、`lib-events.mjs` | 共同 ledger 鎖（flock，行程死了自動釋放；ledger 與 events 同一把）、8 欄 schema、事件佇列（原子替換寫入）與精確 ACK 比對 |
| `bin/watchdog` | L0：死鎖、重送用盡、Router 未回（只認成功的 reply 結果）、pending 逾 6 小時、deep transcript 停滯、`claude agents` 背景 worker blocked；L1：log 錯誤行交免費模型判 KNOWN／NEW／NOISE（出機前欄位白名單＋sensitive-canary＋scrub 每日自檢，退路鏈 beam-free→OC Go 次選→local-llm→`state/watchdog-known.tsv`）；L2：只提議白名單旋鈕，兩棒不同體系同值才套用；`bin/watchdog ask "<問題>"` |
| `bin/dispatch`、`dispatch-retry`、`dispatch-cancel`、`dispatch-deep-run` | 派工（先持鎖登錄再啟動後端）、重派、取消（deep 只照 `state/deep/<id>.handle`）、deep 背景執行 |
| `bin/dispatch-watch` | 回報＋停滯／抽查，pane 閒置才打進去 |
| `bin/review-judge`、`oc-free-ask`、`local-llm` | 免費模型判 Worker 有沒有跑歪；判不出來或格式不對一律 UNKNOWN＝照舊喚醒 Router |
| `bin/idle-reset` | 04／05／06 點試，pane 不忙且 30 分沒動才 `/clear`，一天一次 |

## 測試 / Tests

全部用假的 tmux／模型／triage／dcq，不連網、不需要金鑰；CI（macos-latest）每次 push 跑。

```bash
bash tests/test_router_template.sh     # Router 模板＋派工閘真的接起來
node --test tests/test_dispatch_gate.mjs   # 36 項，含 Codex 審計的 10 個繞過反例
bash tests/test-review-judge.sh && bash tests/test-dispatch-route.sh && bash tests/test_idle_reset.sh
bash tests/test_dispatch_deep.sh && bash tests/test_dispatch_watch.sh
bash tests/test_launchd_install.sh     # 範本無寫死路徑、換完是合法 plist、ONLY= 只產一份
bash tests/test-watchdog.sh            # watchdog v2：L0 不叫模型、上限、白名單／canary（含突變）、scrub 自檢、退路、L2
```

## 限制 / Limits

- 派工閘是紀律閘不是沙箱：字串切段判斷，不是完整 shell 解析。要擋寫入用 OS 層沙箱（Claude Code sandbox／Seatbelt）。
- `oc-free-ask` 送出前會打本機 `:4102/scrub` 去識別，`local-llm` 走本機 `:4000` LiteLLM；沒有這兩個服務，review-judge 會判 UNKNOWN（照舊喚醒 Router），不影響派工。

## 狀態 / Status

- 每輪由 Codex 對照文章審計，主 session 逐條裁決後修補。第 3 輪（2026-11-04）：必修從 9 降到 2，剩 deep 取消前驗證程序身分（PID 重用）、judge 逾時強制 KILL，修補中。
- Each round is audited by Codex against the article; findings are adjudicated item by item before fixing. Round 3 (2026-11-04): must-fix dropped from 9 to 2 — process-identity check before cancelling a deep job (PID reuse) and a hard KILL after the judge timeout. Fixes in progress.

## English summary

**Architecture.** You chat with a Sonnet **Router** over Telegram. The Router never runs tools itself: a PreToolUse hook (`bin/dispatch-gate.mjs`) allows only Telegram replies, `ToolSearch`, `TaskStop`, `SendMessage` and background `dispatcher` subagents, so delegation is enforced by code, not by prompt. The dispatcher triages each request: easy → does it itself; mid → `bin/dispatch` to `dcq` (free-model tier); hard → `deep-run` (background multi-step agent).

**Results and supervision (zero Router tokens).**
- `bin/dispatch-watch` (every 2 min) writes worker results to `state/events.jsonl` first, then delivers them to the Router pane; un-ACKed events are resent every 10 min, up to 5 times. Terminal states are delivered before any review; `bin/review-judge` (free model, hard time budget) filters out ON_TRACK spot checks so they never wake the Router.
- `bin/watchdog` (every 5 min): **L0** zero-token checks — stale locks, exhausted resends, Router not replying, jobs pending > 6 h, stalled deep transcripts, background agents blocked on permission prompts. **L1** only for what L0 cannot classify (new error lines in logs): a free model labels them KNOWN / NEW / NOISE. Payloads leaving the machine are field-whitelisted, PII-scrubbed and scanned with sensitive-canary rules; the scrubber is self-tested daily with fake PII. Fallback chain: beam-free → second OC Go free model → local LLM gateway → rule table → plain alert. **L2** may only propose whitelisted knobs, applied when two different model families agree and the value is within bounds. `bin/watchdog ask "<question>"` answers questions about recent watchdog activity.

**State.** One ledger (`state/dispatch-jobs.tsv`, 8 columns) and the event queue share a single `flock` lock that is released automatically if the holder dies. Deep jobs are cancelled only through their recorded handle, never by guessing.

**Install.** See *Quick start* above; `launchd/install.sh` renders the plist templates (`ONLY=<label>` for one job, `NO_LOAD=1` to only render). Tests use fake tmux / models / dcq, need no network or keys, and run on macOS CI.

## License

MIT
