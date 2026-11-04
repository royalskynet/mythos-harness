# mythos-harness

[![test](https://github.com/royalskynet/mythos-harness/actions/workflows/test.yml/badge.svg)](https://github.com/royalskynet/mythos-harness/actions/workflows/test.yml)

用 Claude Code 實作 [DeepSeek Harness super-agent](https://x.com/DeepSeekHarness/article/2116857257245987236) 的**雙層架構**：
你跟 **Sonnet** 聊天（Router），它只聊天、派工、轉述：每件事都交給獨立的背景 **worker**（`bin/dispatch-bg` 起的 `claude --bg` session，Router 重啟也不斷；起不來才退回 dispatcher 子代理），它判難度後自己做或**派到背景 Worker**（免費模型層、bg-hard 或 `deep-run`），做完由零 token 腳本把結果打回對話。Router 自己不跑指令、不讀檔（派工閘全工具白名單硬擋）。

A Claude Code implementation of the two-layer (Router / Worker) super-agent pattern:
chat with Sonnet; every request goes to a background dispatcher subagent that triages and delegates real work to background workers.

```
你 ──Telegram──▶ Router：Sonnet（只聊天、派工、轉述）
                    │  PreToolUse 派工閘：主 session 只能 Telegram／ToolSearch／TaskStop／背景 dispatcher＋一條 bin/dispatch-bg
                    └─ bin/dispatch-bg（claude --bg worker；失敗才 Agent(dispatcher)）─▶ 判難度、驗收、retry／cancel
                                       ├─ easy ─▶ 自己做
                                       ├─ mid  ─▶ bin/dispatch ─▶ dcq（免費模型層）
                                       └─ hard ─▶ bin/dispatch ─▶ dispatch-bg --hard（sonnet＋Opus advisor，worktree；DISPATCH_HARD_BACKEND=deep 才走 deep-run）
                                                      ▲
        dispatch-watch（每 2 分、零 token）── 先落 events.jsonl；ACK＝Router 已收到事件，不代表處理完 ──▶ 打回 Router
                       │                 未 ACK 10 分鐘重送、上限 5 次；取消的票不再投遞
                       └─ 終態先投遞，抽查後跑 review-judge（免費模型，timeout 硬砍 90 秒）：ON_TRACK 不打擾 Router
        watchdog（每 5 分）── L0 零 token：死鎖、重送用盡、Router 未回、pending 逾 6 小時、deep 停滯、背景 agent 卡權限 → brief-lines
                      └─ log 錯誤行進待判 → L1 免費模型（每小時上限；白名單→scrub 去識別→canary）→ 退路鏈 → 規則表 → 判不了才告警
```

## 對照文章 / Mapping

| 文章模組 | 這裡的實作 |
|---|---|
| 兩層架構（Router 不執行） | `bin/dispatch-gate.mjs`：PreToolUse 全工具白名單，主 session 只放 Telegram 回覆三個工具、ToolSearch、TaskStop、SendMessage 與背景 dispatcher，不靠 prompt 自律（文章 7.1：只靠 prompt 叫自己派工，5 跑 0 次） |
| 何時定方向／宣告完成 | dispatcher（子代理）；`router/ROUTER.md` 是 Router 的規則 |
| Worker 一次性行程 | `bin/dispatch-bg`：獨立 `claude --bg` session（worker 目錄 `~/bots/mythos-worker`，範本 `router/worker/` 由 `router/worker-sync.sh` 同步）；`bin/dispatch`：mid → `dcq`，hard → bg-hard（`DISPATCH_HARD_BACKEND=deep` 才 `deep-run`），背景跑、Router 不等 |
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
| `bin/watchdog` | L0：死鎖、重送用盡、Router 未回（只認成功的 reply 結果）、pending 逾 6 小時、deep transcript 停滯、`claude agents` 背景 worker blocked；L1：log 錯誤行交免費模型判 KNOWN／NEW／NOISE（出機前欄位白名單→scrub 去識別→sensitive-canary 掃去識別後文字，scrub 每日自檢，退路鏈 beam-free→OC Go 次選→local-llm→`state/watchdog-known.tsv`）；L2：只提議白名單旋鈕，兩棒不同體系同值才套用；`bin/watchdog ask "<問題>"` |
| `bin/dispatch`、`dispatch-retry`、`dispatch-cancel`、`dispatch-deep-run` | 派工（先持鎖登錄再啟動後端）、重派（沿用原後端）、取消（deep 只照 `state/deep/<id>.handle`；bg 用 `claude stop <短id>`，停不掉不標 cancelled）、deep 背景執行 |
| `bin/dispatch-bg`、`router/worker/`、`router/worker-sync.sh` | 背景 worker：`claude --bg`（工具白名單 `Bash Read Write Edit Glob Grep`、不給 Telegram），ledger 記 `bg-<短id>`；`--thread` 續同一 session、`--hard` 用 `hard.json`（sonnet＋advisor）並要求 worktree；結果寫 `state/bg/<短id>.result`，`dispatch-watch` 以 `claude agents --json --all` 判 done／STALL（`BG_STALL_MIN`，預設 60） |
| `bin/dispatch-watch` | 回報＋停滯／抽查，pane 閒置才打進去 |
| `bin/latency-report` | 唯讀、零 token：Telegram 使用者訊息到第一個 `__reply` 的延遲摘要（`n p50_s p90_s max_s over60 no_reply pending_tail`：終點取 `mcp__telegram__reply` 對到、成功的 tool_result 時間；每檔各自配對、連發併一筆；`pending_tail`＝檔尾還在等、不算沒回；`no_reply`＝上一輪沒回、距本輪最後一則使用者訊息超過 `LATENCY_MERGE_SEC`（環境變數，預設 300 秒）又來新訊息，舊輪算沒回並重起一輪，沒超過就併筆；`--days N`、`--json`；`--max-detail` 只印一行 `max_s= start= merged= file=`（最大延遲的秒數、起點、併筆數、檔名），不印訊息內文） |
| `bin/tg-send`、`tg-plugin-patch`、`tg-commands.mjs` | bg 的 PASS 直發（exit 0 已送／1 確定沒送／2 不明／97 測試守門，15 秒總時限，送出的訊息記在 `state/tg-msg-thread.tsv`）；patch telegram plugin 補 `reply_to_message_id`；斜線指令 proxy，回覆直發訊息時加 `[回覆 bg thread= job=]` 標註 |
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
bash tests/test-knob-timing.sh && bash tests/test-latency-report.sh && bash tests/test-repo-queue.sh   # 旋鈕時序（含突變）、延遲量測、同 repo 佇列
bash tests/test-dispatch-bg.sh && bash tests/test-dispatch-bg-watch.sh && bash tests/test-dispatch-gate-bg.sh   # 背景 worker：啟動／續派／hard、回報與取消、Router 閘
bash tests/test-tg-send.sh && bash tests/test-tg-plugin-patch.sh && bash tests/test-tg-reply-thread.sh    # 直發至多一次（本機 stub）、plugin patch、回覆標註
node tests/test_tg_commands.mjs        # 本機限定：會讀 ~/.claude/commands 的 fix.md／wheel.md
MYTHOS_E2E=1 bash tests/test-dispatch-bg-e2e.sh   # 真 claude --bg（haiku）；沒設 MYTHOS_E2E 只印 SKIP
```

## 限制 / Limits

- 派工閘是紀律閘不是沙箱：字串切段判斷，不是完整 shell 解析。要擋寫入用 OS 層沙箱（Claude Code sandbox／Seatbelt）。
- `oc-free-ask` 送出前會打本機 `:4102/scrub` 去識別，`local-llm` 走本機 `:4000` LiteLLM；沒有這兩個服務，review-judge 會判 UNKNOWN（照舊喚醒 Router），不影響派工。

## 狀態 / Status

- 每輪由 Codex 對照文章審計，主 session 逐條裁決（可部分同意）後修補。必修 P0／P1：第 1 輪 10 → 9 → 2 → 3 → **第 5 輪（2026-11-04）0，VERDICT: PASS**，重啟、載入 watchdog、公開 push 三件事皆 GO。
- P2（2026-11-04）三張工單都已收斂，流程是「主 session 裁決＋寫規格 → 執行 → Codex 驗收／驗屍 → 逐條裁決打回」，每張最多 3 輪，只修範圍內可重現的 high：
  - **C**：旋鈕時序行為測試、Router 回覆延遲量測（`bin/latency-report`）、同 repo 佇列。Codex 第 6–9 輪 high 3 → 2 → 1 → 0。
  - **D**：dispatcher 改成獨立 `claude --bg` worker，hard 改 bg-hard。第 10–11 輪 high 3 → 0。
  - **E**：延遲分段（`--stages`）；bg 單的 PASS 由 `bin/tg-send` 直發給使用者，至多一次（`direct`＝sending／sent／failed／unknown，結果不明不重送、改寫告警）；使用者回覆直發訊息時，proxy 加上 `[回覆 bg thread=… job=…]` 交 Router 判斷要不要續派。派工前先做規格審查（11 條，accept 10），之後第 12–13 輪 high 1 → 0。
  - 多對多訂閱表＋fan-out 裁定不做：只有一個使用者、一個 Router。
- Each round Codex audits the repo against the article; the main session adjudicates every finding (partial agreement allowed) before fixing. Must-fix P0/P1 went 10 → 9 → 2 → 3 → **0 in round 5 (2026-11-04), VERDICT: PASS**; restart, watchdog install and public push were all cleared.
- P2 (2026-11-04): all three work orders converged under a "main session rules and writes the spec → executor → Codex audit / post-mortem → per-finding verdicts" loop, capped at 3 rounds each, fixing only reproducible in-scope highs:
  - **C**: behavioural knob-timing tests, Router reply latency measurement (`bin/latency-report`), and a per-repo queue. Codex rounds 6–9: highs 3 → 2 → 1 → 0.
  - **D**: the dispatcher becomes an independent `claude --bg` worker, and hard jobs become bg-hard. Rounds 10–11: highs 3 → 0.
  - **E**: latency stage breakdown (`--stages`). A bg job's PASS result is pushed straight to the user by `bin/tg-send`, at most once (`direct` = sending/sent/failed/unknown; an unknown outcome is never resent and raises an alert instead). When the user replies to that message, the proxy tags it `[回覆 bg thread=… job=…]` and lets the Router decide whether to continue the same worker. A spec review ran before dispatch (11 findings, 10 accepted); rounds 12–13 then took highs 1 → 0.
  - Many-to-many subscriptions and fan-out were ruled out: there is one user and one Router.

## 已知問題 / Known issues

依收斂規則留下沒修的項目（medium 以下，或要改的範圍超出本輪）。完整清單在 `state/workorders/p2-backlog.md`。

- **回覆標註要重啟才生效**：`bin/tg-plugin-patch` 會在 telegram plugin 的通知裡補 `reply_to_message_id`，但 plugin 升版會蓋掉這處修改。`run.sh` 每次啟動前都會重跑它（冪等，失敗只記 log），所以要等 Mythos 下次重啟才生效。重啟後的真實回覆路徑還沒實測。
- **標註可偽造**：標註是寫在訊息內文裡的文字，在 allowlist 內的發送者可以自己打出同樣字樣。現在 allowlist 只有使用者本人，標註也只是給 Router 的提示，不會繞過 Router 直接派工。
- **dispatch-bg 停止失敗時的回傳**：登錄失敗後，如果連停止 worker 都失敗，仍會 exit 1，Router 的 fallback 可能再派一次。要修得改 Router 的 fallback 契約，超出這次的範圍。
- **延遲分段精度**（r12 F2–F5）：
  - `--stages` 的 `reply_use_ts` 取的是 result 時間，不是 reply 工具呼叫的時間。
  - 找快樣本配對時，沒有排除時間相距超過 600 秒的候選。
  - 晚到的舊 assistant 紀錄會把 `first_assistant_ts` 往前改。
  - 訊息內文出現 `message_id="…"` 時，會被誤當成去重鍵。
  - 以上不影響 n／p50 的主要量測。
- **既有問題，不在 P2 範圍**：Telegram 送 `/fix`、`/wheel` 時，proxy 展開的內容沒有被轉發出去。另外 proxy 的 `setMyCommands` 在測試 sandbox 裡沒有守門。

Items left open by the convergence rule (medium or lower, or a fix that would widen scope). The full list is in `state/workorders/p2-backlog.md`.

- **Reply tagging needs a restart.** `bin/tg-plugin-patch` adds `reply_to_message_id` to the telegram plugin's notifications, but a plugin upgrade overwrites that change. `run.sh` re-applies the patch before every launch (idempotent; a failure is only logged), so it takes effect on the next Mythos restart. The live reply path after a restart has not been tested yet.
- **The tag can be forged.** It is plain text in the message body, so an allowlisted sender could type it. The allowlist is only the owner, and the tag is a hint for the Router: it never dispatches work on its own.
- **dispatch-bg exit code when stopping fails.** If registration fails and stopping the worker also fails, `dispatch-bg` still exits 1, so the Router fallback may dispatch again. Fixing it means changing the Router's fallback contract, which is out of scope here.
- **Latency stage precision** (r12 F2–F5):
  - `reply_use_ts` in `--stages` records the result time, not the time of the reply tool call.
  - Fast-sample pairing does not exclude candidates more than 600 s apart.
  - A late-arriving old assistant record can move `first_assistant_ts` earlier.
  - A `message_id="…"` string inside the message text is mistaken for the dedup key.
  - None of these affect the headline n / p50 numbers.
- **Pre-existing, outside P2.** When Telegram sends `/fix` or `/wheel`, the proxy's expanded text is not forwarded. Separately, the proxy's `setMyCommands` call has no guard inside the test sandbox.

## English summary

**Architecture.** You chat with a Sonnet **Router** over Telegram. The Router never runs tools itself: a PreToolUse hook (`bin/dispatch-gate.mjs`) allows only Telegram replies, `ToolSearch`, `TaskStop`, `SendMessage`, background `dispatcher` subagents, and exactly one Bash shape (`bin/dispatch-bg <thread> state/bg/<file>.md`, plus `Write` into `state/bg/`), so delegation is enforced by code, not by prompt. By default the Router hands each request to an independent `claude --bg` worker (`bin/dispatch-bg`) that survives Router restarts; the in-process dispatcher subagent is the fallback. The worker triages: easy → does it itself; mid → `bin/dispatch` to `dcq` (free-model tier); hard → `bin/dispatch-bg --hard` (Sonnet with an Opus advisor, in a git worktree; `DISPATCH_HARD_BACKEND=deep` keeps the old `deep-run`).

**Results and supervision (zero Router tokens).**
- `bin/dispatch-watch` (every 2 min) writes worker results to `state/events.jsonl` first, then delivers them to the Router pane; un-ACKed events are resent every 10 min, up to 5 times. A bg job's PASS result goes straight to the user via `bin/tg-send`, sent at most once; it only falls back to the Router when the send provably did not happen. Terminal states are delivered before any review; `bin/review-judge` (free model, hard time budget) filters out ON_TRACK spot checks so they never wake the Router.
- `bin/watchdog` (every 5 min): **L0** zero-token checks — stale locks, exhausted resends, Router not replying, jobs pending > 6 h, stalled deep transcripts, background agents blocked on permission prompts. **L1** only for what L0 cannot classify (new error lines in logs): a free model labels them KNOWN / NEW / NOISE. Payloads leaving the machine are field-whitelisted, then PII-scrubbed, then the scrubbed text is scanned with sensitive-canary rules (scrub down = nothing is sent); the scrubber is self-tested daily with fake PII. Fallback chain: beam-free → second OC Go free model → local LLM gateway → rule table → plain alert. **L2** may only propose whitelisted knobs, applied when two different model families agree and the value is within bounds. `bin/watchdog ask "<question>"` answers questions about recent watchdog activity.

**State.** One ledger (`state/dispatch-jobs.tsv`, 8 columns) and the event queue share a single `flock` lock that is released automatically if the holder dies. Deep jobs are cancelled only through their recorded handle, never by guessing.

**Install.** See *Quick start* above; `launchd/install.sh` renders the plist templates (`ONLY=<label>` for one job, `NO_LOAD=1` to only render). Tests use fake tmux / models / dcq, need no network or keys, and run on macOS CI.

## License

MIT
