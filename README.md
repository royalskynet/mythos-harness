# mythos-harness

[![test](https://github.com/royalskynet/mythos-harness/actions/workflows/test.yml/badge.svg)](https://github.com/royalskynet/mythos-harness/actions/workflows/test.yml)

用 Claude Code 實作 [DeepSeek Harness super-agent](https://x.com/DeepSeekHarness/article/2116857257245987236) 的**雙層架構**：
你跟 **Sonnet** 聊天（Router），它只聊天、派工、轉述：每件事都交給獨立的背景 **worker**（`bin/dispatch-bg` 起的 `claude --bg` haiku session，Router 重啟也不斷；起不來才退回 haiku dispatcher 子代理），它判難度後自己做或**派到 O**（`dcq`：免費模型先、全敗才升訂閱），做完由零 token 腳本把結果打回對話。Router 自己不跑指令、不讀檔（派工閘全工具白名單硬擋）。

A Claude Code implementation of the two-layer (Router / Worker) super-agent pattern:
chat with Sonnet; every request goes to a background haiku worker that triages and delegates real work to free models first.

> 2026-11-08 起 Telegram 前台改跑 Hermes，見下節〈現行架構〉；再往下是 Claude Code TUI 版，`bin/cutover-hermes` 可切回。
> Since 2026-11-08 the Telegram front end runs on Hermes (see *Current architecture* below). Everything after it describes the Claude Code TUI version, which `bin/cutover-hermes` can roll back to.

## 現行架構：Hermes / Current architecture (2026-11-08)

**一個 Mythos。** 你在 Telegram 對話的這一段，和替你動手做事的每個 session，都是同一個 Mythos。給你看的話不提派工、工單、代號、別人：Mythos 自己去做，做完自己告訴你。`bin/adhd-lint.mjs` 會擋這類斷裂用語，出口把含這些詞的句子刪掉。

```
你 ──Telegram──▶ Hermes gateway（profile mythos，beam-free；/model 可換 deepseek-v4.1-flash）
                   │  這段對話只有三個工具：mythos_dispatch、mythos_recall、mythos_full_text
                   │  （platform_toolsets 只給 mythos、不掛 MCP、關 tool_search；router-guard 的 pre_tool_call 白名單再擋一次）
                   ├─ 問以前的事 ─▶ mythos_recall（一輪最多一次，查不到才動手）
                   └─ 要做事 ─▶ mythos_dispatch ─▶ bin/dispatch-bg（DISPATCH_BG_WORKER=hermes，Laya 先判難度）
                                     └─▶ hermes -p mythos-worker -z（detached；claude-mem 只掛在這裡）
                                           結束：stdout／stderr／結束碼分檔，rc≠0 或空輸出判 FAIL
                                           結束當下觸發 bin/dispatch-watch（launchd 每 120 秒補漏）
                                           └─▶ 收件匣 ─▶ 外掛每秒注入同一段對話，Mythos 用自己的口吻講結果
```

- **追問、取消、改方向**：`mythos_dispatch` 的 `mode` 有 queue（預設，補充排隊）、cancel（停掉整個行程樹，結果不再送回）、interrupt（停掉後帶原需求＋新指示重做）。
- **送達確認**：注入後查對話紀錄確認真的落地；逾時沒落地就直接發 Telegram。
- **多 profile 共用 gateway**：外掛由自己所在的目錄推 profile 的 `state.db`，不看 `HERMES_HOME`（gateway 行程裡它指向主機 profile）。
- profile 端的 SOUL、config、外掛（mythos-tools、router-guard、adhd-outlet）正本在 `profiles/`，以 Hermes 原生 profile distribution 裝到 `~/.hermes/profiles/`，見下方「升級 Hermes」。
- **已知問題**：Telegram 回合裡還沒觀察到出口外掛被呼叫（oneshot 正常），追查中；一次實測 worker 第一次模型回應等了 150 秒（單獨跑同題 13 秒），原因未明。

**One Mythos.** The Telegram conversation and every session that does work for you are the same Mythos. User-facing text never mentions dispatching, tickets, ids or anyone else; `bin/adhd-lint.mjs` rejects such wording and the outlet drops those sentences.

- The conversation gets exactly three tools: `mythos_dispatch`, `mythos_recall` (at most once per turn) and `mythos_full_text`. `platform_toolsets` exposes only the mythos toolset with no MCP, `tool_search` is off, and router-guard's `pre_tool_call` allowlist blocks anything else.
- `mythos_dispatch` → `bin/dispatch-bg` with `DISPATCH_BG_WORKER=hermes` (Laya pre-classifies difficulty) → detached `hermes -p mythos-worker -z`. claude-mem is attached to the worker profile only. stdout, stderr and the exit code are stored separately; a non-zero exit or empty output is a FAIL. The worker triggers `bin/dispatch-watch` as soon as it exits (launchd every 120 s is the backstop), and the result goes through an inbox the plugin injects into the same conversation every second.
- `mode`: queue (default), cancel (kills the whole process tree; the result is never delivered), interrupt (kills it and redoes the original request plus the new instruction).
- Delivery is confirmed against the conversation log; if the injected message never lands it is sent to Telegram directly.
- Plugins locate `state.db` from their own directory, not `HERMES_HOME`, because the shared multi-profile gateway process points that at the host profile.
- The profiles' SOUL, config and plugins live in `profiles/` and are installed as native Hermes profile distributions; see “Upgrading Hermes” below.
- **Known issues:** the outlet plugin has not yet been observed running on Telegram turns (it works in one-shot runs); under investigation. In one live run the worker's first model response took 150 s versus 13 s when run alone; cause unknown.

```
你 ──Telegram──▶ Router：Sonnet（只聊天、派工、轉述）
                    │  PreToolUse 派工閘：主 session 只能 Telegram／ToolSearch／TaskStop／背景 dispatcher＋一條 bin/dispatch-bg
                    ├─ 唯讀小問題 ─▶ bin/quick --push（閘改成背景跑；opencode 免費模型、唯讀稽核）─▶ brief-answer 秘書口吻直送你
                    ├─ 問過去的事 ─▶ bin/recall --ask（閘改成背景跑；claude-mem HTTP＋fixindex＋memory 目錄）─▶ brief-answer 直送你
                    └─ bin/dispatch-bg --from-chat（prompt 由 transcript 自動抓原話；Router 只回「收到」）─▶ claude --bg worker：判難度、驗收、retry／cancel
                                       │  （難度先由本機 Laya 判好寫進 prompt；haiku 只能往上改）
                                       ├─ easy ─▶ 自己做
                                       ├─ mid  ─▶ bin/plan-ticket ─▶ O 寫計畫 ─PASS▶ dispatch-watch 自動派執行單 ─▶ dcq（DCQ_ORDER=default：免費先、全敗升訂閱）
                                       │         easy 派工仍走 DCQ_ORDER=free（只用免費層）
                                       └─ hard ─▶ bin/plan-ticket ─▶ 同上，dcq（DCQ_ORDER=default：免費先、全敗升訂閱）；資料不能出機才 DISPATCH_HARD_BACKEND=bg（sonnet）
                                                      ▲
        dispatch-watch（每 2 分、零 token）── 先落 events.jsonl；ACK＝Router 已收到事件，不代表處理完 ──▶ 打回 Router
                       │                 未 ACK 10 分鐘重送、上限 5 次；取消的票不再投遞
                       └─ 終態先投遞，抽查後跑 review-judge（免費模型，timeout 硬砍 90 秒）：ON_TRACK 不打擾 Router
        watchdog（每 5 分）── L0 零 token：死鎖、重送用盡、Router 未回、pending 逾 6 小時、deep 停滯、背景 agent 卡權限 → brief-lines
                      └─ log 錯誤行進待判 → L1 免費模型（每小時上限；白名單→scrub 去識別→canary）→ 退路鏈 → 規則表 → 判不了才告警
```

## 升級 Hermes / Upgrading Hermes

Mythos 不改 hermes-agent 原始碼，只靠三樣東西接上它：`profiles/` 兩個 distribution、`bin/` 的外部腳本、`bin/hermes-contract` 的契約檢查。

- **正本在 repo**：`profiles/mythos`（Router）、`profiles/mythos-worker`（worker）各有 `distribution.yaml`，`distribution_owned` 明列 SOUL、config、外掛；skills、cron、記憶、session 都是本機資料，update 不碰。config 的 Telegram chat id 寫成 `${MYTHOS_TG_CHAT_ID}`，線上 config 在 update 時保留（不加 `--force-config` 就不覆蓋）。
- **改 SOUL／外掛**：改 `profiles/` 裡的檔 → `hermes profile update mythos -y`（worker 同理）→ `bin/hermes-contract`。直接改 `~/.hermes/profiles/` 會被契約檢查判成漂移。
- **升 Hermes**：一律跑 `bin/hermes-upgrade`：先 pull 最新 Hermes（`hermes update --keep-stash`，會重啟同一安裝下所有 gateway），再從 repo pull 兩個 profile（`hermes profile update`），最後跑契約檢查，通過才重啟 mythos gateway。hermes-agent 的在地修改先存成 `state/hermes-upgrade/<時間>-local.diff`，升級後逐檔 `git apply -3` 套回；衝突或上游刪檔就退回上游版並列 `WARN`。Hermes 自己遷移過的 config（`_config_version` 等）會回寫進 `profiles/`，chat id 換回變數，跑完要 commit。契約不過時跑 `bin/hermes-upgrade --rollback` 回到升級前的 commit。驗收 `tests/test-hermes-upgrade.sh`。契約檢查項：外掛用到的掛鉤名與 `ctx` 方法（從外掛原始碼抓，不手列）、per-platform `interim_assistant_messages` 解析、`gateway.standalone` 過渡 shim、`auxiliary.background_review.enabled`、per-model `stale_timeout_seconds`、worker 的 `hermes -z` 入口還在、oneshot 沒再關 logging、線上 profile 與 repo 一致、worker 的 claude-mem symlink。
- **新機安裝**：`hermes profile install profiles/mythos` 與 `profiles/mythos-worker`，在 profile `.env` 填 `MYTHOS_TG_CHAT_ID`、bot token，再 `ln -s ~/.hermes/plugins/claude-mem ~/.hermes/profiles/mythos-worker/plugins/claude-mem`（distribution 不收 symlink）。

Mythos never patches hermes-agent. It attaches through two profile distributions in `profiles/`, external scripts in `bin/`, and the `bin/hermes-contract` check. Edit files under `profiles/`, then `hermes profile update <name> -y`. Upgrade with `bin/hermes-upgrade`: it pulls the latest Hermes (`hermes update --keep-stash`), pulls both profiles from this repo (`hermes profile update`), runs `bin/hermes-contract`, and restarts the mythos gateway only if the contract passes. Local hermes-agent edits are saved as a diff and re-applied per file with `git apply -3`; conflicts and upstream-deleted files fall back to upstream with a `WARN`. Config migrations made by Hermes are written back into `profiles/` (chat id scrubbed) for you to commit. `bin/hermes-upgrade --rollback` returns to the pre-upgrade commit. The contract derives hook names and `ctx` methods from the plugin sources, checks the per-platform interim-message setting, the `gateway.standalone` shim, the background-review and per-model timeout keys, the worker `hermes -z` entry point and that oneshot no longer disables logging, profile drift against this repo, and the worker's claude-mem symlink.

## 秒回 / Instant replies

Router 的回合只做一件事：回你一句、或派出去。凡是會佔住回合的事都移到 Router 外面（11-07）：

- **派工**：`bin/dispatch-bg --from-chat <代號>` 由 `bin/chat-prompt.mjs` 從 Router transcript 抓你的原話＋近 8 則脈絡寫成 worker prompt，Router 不再自己寫長 prompt，派完只回「收到」。
- **快查／記憶查詢**：派工閘用 PreToolUse `updatedInput` 把 `bin/quick`、`bin/recall --ask` 改成 `run_in_background`，答案由 `bin/brief-answer`（`claude -p` 一次改寫）寫成秘書口吻直接送給你，Router 不等也不轉述。
- **忙碌時**：`bin/tg-commands.mjs`（telegram MCP 的 stdio proxy）訊息一進來就每 4 秒補送「輸入中」；Router 正在跑就先替它回「收到，等等處理」。零 token。
- **結果**：`bin/dispatch-watch` 把 bg 單的 PASS 改寫成秘書口吻直送；FAIL／STALL 先自動重派一次（STALL 先 cancel），再失敗才直接告訴你，都不經 Router。
- **背景進度**：worker 也掛 `bin/tg-progress.mjs --worker`，在 Telegram 顯示「⏳ 背景在做：…（第 N 步）」，做完刪掉。
- **壓縮**：`bin/ctx-guard` 在 Router 閒置 ≥3 分鐘、context 超過 140K 時先送 `/compact`，不等撞到上限才在你說話時壓。
- 子代理只用 haiku（派工閘把 Agent／Task 一律改寫成 `model: haiku`＋背景）；haiku 做不來就不派子代理，改派 O 或 `bin/oc-free-ask`。
- haiku 只做勝任的事：難度由本機 Laya 先判（零 token），haiku 只能往上改；mid／hard 的計畫與驗收由 O 寫（`bin/plan-ticket`），haiku 只負責找工作目錄、交原話。例外：Laya 對純查詢常沒把握而判 mid，所以 mid 的唯讀查詢 haiku 可以自己查，仍受 8 次上限。派工閘把標了 mid／hard 的 worker 自做額度縮到 8 次（`MYTHOS_TIER_CAP`），硬做會被擋。

## 對照文章 / Mapping

| 文章模組 | 這裡的實作 |
|---|---|
| 兩層架構（Router 不執行） | `bin/dispatch-gate.mjs`：PreToolUse 全工具白名單，主 session 只放 Telegram 回覆三個工具、ToolSearch、TaskStop、SendMessage 與背景 dispatcher，不靠 prompt 自律（文章 7.1：只靠 prompt 叫自己派工，5 跑 0 次） |
| 何時定方向／宣告完成 | dispatcher（子代理）；`router/ROUTER.md` 是 Router 的規則 |
| Worker 一次性行程 | `bin/dispatch-bg`：獨立 `claude --bg` session（worker 目錄 `~/bots/mythos-worker`，範本 `router/worker/` 由 `router/worker-sync.sh` 同步）；`bin/dispatch`：mid／hard → `dcq`（hard 走 default 序：免費先；`DISPATCH_HARD_BACKEND=bg` 才 bg-hard、`=deep` 才 `deep-run`），背景跑、Router 不等 |
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

### 選用元件 / Optional components

核心只要上面的需求＋`dcq`。下面每一項都可以不裝：沒裝的功能會自己跳過或回 exit 6，Router 照常派 worker，不會壞。

| 功能 | 需要 | 沒裝會怎樣 |
|---|---|---|
| Telegram 對話 | telegram plugin | `CHANNELS= router/start.sh`，在 tmux 裡直接打字 |
| 快查 `bin/quick` | [opencode](https://opencode.ai)；`dcq`（給免費模型清單） | 沒 opencode exit 6、沒 `dcq` 或列不出免費層 exit 5，都改派 worker；不寫死模型名，`FREE_MODELS='a b'`（空白分隔）可手動指定 |
| 記憶快查 `bin/recall` | 三選任意：claude-mem worker（HTTP `:37701`）、`fixindex`、Claude Code auto-memory 目錄 | 有哪個查哪個；一個都沒有 exit 6，改派 worker。`RECALL_SOURCES=md` 只用部分 |
| mid 免費全敗升訂閱層 | OpenCode Go 訂閱（月費＝花錢） | 設 `DISPATCH_MID_ORDER=free`，mid 只用免費層 |
| hard 走 Claude | `claude --bg`；`deep-run` 選用 | 預設 hard 走 O（`dcq`）；`DISPATCH_HARD_BACKEND=bg` 才起 sonnet bg-hard、`=deep` 才要 `deep-run` |
| 判難度 | orchestrator 的 `triage`（`DISPATCH_GATE_TRIAGE` 可改路徑） | dispatcher 自己判 |
| 驗收路徑檢查 | orchestrator 的 `wo-verify` | 改用內建解析器收驗收段 |
| 抽查／watchdog 的免費模型判斷 | opencode＋本機 PII 去識別 `:4102/scrub`；`local-llm` 要 `:4000` OpenAI 相容閘道 | 去識別不通就不送（fail closed）：抽查一律回 UNKNOWN 照常喚醒 Router，watchdog 改走規則表 |
| watchdog 出機前掃描 | sensitive-canary plugin | 用內建 regex 掃 |
| 秘書口吻改寫 `bin/brief-answer` | 本機 PII 去識別 `:4102/scrub`＋opencode 免費模型；`claude` CLI（haiku 墊底） | 去識別不通就不叫任何模型、直接送原文；免費模型都失敗才用 haiku，再失敗送原文 |
| 告警與直發結果 | 寫進 `BRIEF_LINES_DIR`（預設 `~/.cache/brief-lines`）的文字檔，給自家彙整程式讀 | 檔案照寫；沒有彙整程式就只能自己看，或把 `BRIEF_LINES_DIR` 指到你會看的地方 |
| Telegram `/fix`、`/wheel` | `~/.claude/commands/fix.md`、`wheel.md` | 不用這兩個指令就不影響 |
| 自做上限豁免 | `state/cap-exempt.txt`（一行一個字串，不進版控） | 只豁免 bg-hard |

背景監看用 launchd：`bash launchd/install.sh` 把 `launchd/*.plist` 範本的 `__REPO__`／`__HOME__` 換成 clone 位置與家目錄，寫進 `~/Library/LaunchAgents/`（`NO_LOAD=1` 只產檔）。現有三份：`ai.mythos.dispatch-watch`（回報與抽查）、`ai.mythos.watchdog`（卡住偵測）、`ai.mythos.idle-reset`（閒置 `/clear`）。`ONLY=<label>` 只處理那一份。載入要帶完整 service target：`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<label>.plist`。

## 元件 / Components

| 檔案 | 作用 |
|---|---|
| `router/settings.json`、`ROUTER.md`、`start.sh` | Router 層：模型分層、派工閘 hook、Router 規則、tmux 啟動 |
| `bin/dispatch-gate.mjs` | 主 session 全工具白名單（Telegram 只放 reply／react／edit_message）；子代理不能直接回 Telegram；pinGuard、fail-closed |
| `bin/lib-ledger.sh`、`lib-events.mjs` | 共同 ledger 鎖（flock，行程死了自動釋放；ledger 與 events 同一把）、8 欄 schema、事件佇列（原子替換寫入）與精確 ACK 比對 |
| `bin/watchdog` | L0：死鎖、重送用盡、Router 未回（只認成功的 reply 結果）、pending 逾 6 小時、deep transcript 停滯、`claude agents` 背景 worker blocked；L1：log 錯誤行交免費模型判 KNOWN／NEW／NOISE（出機前欄位白名單→scrub 去識別→sensitive-canary 掃去識別後文字，scrub 每日自檢，退路鏈 免費池第 1 名→第 2 名→local-llm→`state/watchdog-known.tsv`）；L2：只提議白名單旋鈕，兩棒不同體系同值才套用；`bin/watchdog ask "<問題>"` |
| `bin/quick` | 快查線（11-06）：`bin/quick <cwd 絕對路徑> '<問題>'`。模型取 `bin/free-models`（dcq 免費 opencode 層，隨每日 probe 同步），只走免費層；要付費墊底才設 `QUICK_PAID`（預設空）；`opencode run --agent plan --dir <cwd>` 讀不到 cwd 以外；掃 JSON 事件，寫檔或改狀態的 bash 一律作廢（exit 3）；問題含 PII 不出機（exit 4）；答案每個結論附指令＋原始輸出，呼叫端挑一條重跑對照。派工閘只放行 `^bin/quick /abs '<單引號問題>'$` |
| `bin/brief-answer`、`chat-prompt.mjs` | 秒回（11-07）：前者把快查答案／worker 結論改寫成秘書口吻直送（先過 `:4102/scrub`，再試免費池前 `BRIEF_FREE_MAX`＝2 名，最後 haiku；整個行程群組逾時硬砍；`--not-found` 送固定句不叫模型；exit 7＝確定沒送、8＝送出結果不明，呼叫端不可再轉述）；後者從 Router transcript 抓使用者原話寫 worker prompt（`dispatch-bg --from-chat`），已交背景的工具呼叫會切成邊界，不混進下一題 |
| `bin/plan-ticket` | 規劃單（11-07）：`printf '<原話>' \| bin/plan-ticket <mid\|hard> <cwd>` 產一張「寫可執行工單」的單交 O；驗收＝執行單存在且過 `deep-lint`。PASS 後 `dispatch-watch` 依第一行 `<!-- mythos:then-run … -->` 零 token 派出執行單（同 thread／cwd／tier），派不出去寫原因 |
| `bin/free-models` | 印出 dcq 目前的免費 opencode 模型（一行一個）；`quick`、`oc-free-ask`、`watchdog`、`brief-answer` 都從這裡取，模型隨 opencode 政策換掉也不用改程式。取不到就 exit 1 什麼都不印，不退回寫死的名字 |
| `bin/ctx-guard` | context 守門：Router 超限送 `/compact`；閒置 ≥`CTX_ROUTER_QUIET_SEC`（180）秒且超過 `CTX_ROUTER_IDLE`（140000）先壓，只壓最新 session，`CTX_ROUTER_IDLE=0` 關閉 |
| `bin/recall` | 記憶快查（11-07）：`bin/recall '<關鍵字>'` 一次查 claude-mem（只打 worker 的 HTTP GET `/api/search`，不載 plugin，Mythos 對話不寫進去）、`fixindex find`（只留內文真含關鍵字的條目）、主 session memory 目錄；`--obs <id>`／`--fix <id>` 展開單筆。零 LLM、不出機。exit 0 有結果／1 三處都沒有 |
| `bin/dispatch`、`dispatch-retry`、`dispatch-cancel`、`dispatch-deep-run` | 派工（先持鎖登錄再啟動後端）、重派（沿用原後端）、取消（deep 只照 `state/deep/<id>.handle`；bg 用 `claude stop <短id>`，停不掉不標 cancelled）、deep 背景執行 |
| `bin/dispatch-bg`、`router/worker/`、`router/worker-sync.sh` | 背景 worker：`claude --bg`（工具白名單 `Bash Read Write Edit Glob Grep`、不給 Telegram），ledger 記 `bg-<短id>`；`--thread` 續同一 session、預設 `--model haiku`；`--hard` 用 `hard.json`（sonnet＋advisor）並要求 worktree；結果寫 `state/bg/<短id>.result`，`--thread` 續派前先向 `claude agents` 換回完整 sessionId（只給短 id 會起一個不動的 copy）；`dispatch-watch` 以 `claude agents --json --all` 判 done，STALL 看 transcript 最後寫入（`BG_STALL_MIN` 預設 60；開派 `BG_NOSTART_MIN`＝5 分鐘仍無 transcript 算沒開工）；done 但 result 還沒寫先寬限 `BG_RESULT_GRACE_SEC`（預設 120）秒，仍缺才發 PASS 並標「result 缺檔」，內容退讀 claude logs（去 ANSI）或 transcript 最後一段 |
| `bin/dispatch-watch` | 回報＋停滯／抽查，pane 閒置才打進去；bg 單 PASS 經 `brief-answer` 改寫直送，FAIL／STALL 自動重派一次（prompt 檔名帶 `-autoretry-`），再失敗直接告訴使用者（`BG_AUTOHEAL=0` 關閉） |
| `bin/latency-report` | 唯讀、零 token：Telegram 使用者訊息到第一個 `__reply` 的延遲摘要（`n p50_s p90_s max_s over60 no_reply pending_tail`：終點取 `mcp__telegram__reply` 對到、成功的 tool_result 時間；每檔各自配對、連發併一筆；`pending_tail`＝檔尾還在等、不算沒回；`no_reply`＝上一輪沒回、距本輪最後一則使用者訊息超過 `LATENCY_MERGE_SEC`（環境變數，預設 300 秒）又來新訊息，舊輪算沒回並重起一輪，沒超過就併筆；`--days N`、`--json`；`--max-detail` 只印一行 `max_s= start= merged= file=`（最大延遲的秒數、起點、併筆數、檔名），不印訊息內文） |
| `bin/tg-send`、`tg-plugin-patch`、`tg-commands.mjs` | bg 的 PASS 直發（exit 0 已送／1 確定沒送／2 不明／97 測試守門，15 秒總時限，送出的訊息記在 `state/tg-msg-thread.tsv`）；patch telegram plugin 補 `reply_to_message_id`；斜線指令 proxy，回覆直發訊息時加 `[回覆 bg thread= job=]` 標註 |
| `bin/review-judge`、`oc-free-ask`、`local-llm` | 免費模型判 Worker 有沒有跑歪；判不出來或格式不對一律 UNKNOWN＝照舊喚醒 Router |
| `bin/idle-reset` | 04／05／06 點試，pane 不忙且 30 分沒動才 `/clear`，一天一次 |
| `bin/tg-progress.mjs` | PreToolUse／Stop hook，零 token：每回合第一個工具就靜音發一則「步驟」進度、之後逐步改它，回合結束刪掉；`--worker` 給背景 worker 用（發給 access.json 第一位使用者，標題取任務原話，每 5 秒最多改一次） |
| `bin/daily-log`、`session-context` | PreCompact／SessionEnd 把 Telegram 收發內容過 PII 閘道後摘要成 `memory/daily/YYYY-MM-DD.md`（閘道不通就不送、下次重試）；SessionStart 把今天／昨天日誌尾段注入開場 |
| `bin/remind` | 提醒：`add "<when>" "<內容>"`／`list`／`rm`；launchd 每分鐘到點直發 Bot API；`--ask` 到點把內容打進 Router、`--digest` 併進晨報 |

## 測試 / Tests

全部用假的 tmux／模型／triage／dcq，不連網、不需要金鑰；CI（macos-latest）每次 push 跑。

```bash
bash tests/test_router_template.sh     # Router 模板＋派工閘真的接起來
node --test tests/test_dispatch_gate.mjs   # 49 項，含 Codex 審計的繞過反例、haiku 改寫、難度上限
bash tests/test-review-judge.sh && bash tests/test-dispatch-route.sh && bash tests/test_idle_reset.sh
bash tests/test_dispatch_deep.sh && bash tests/test_dispatch_watch.sh
bash tests/test_launchd_install.sh     # 範本無寫死路徑、換完是合法 plist、ONLY= 只產一份
bash tests/test-watchdog.sh            # watchdog v2：L0 不叫模型、上限、白名單／canary（含突變）、scrub 自檢、退路、L2
bash tests/test-knob-timing.sh && bash tests/test-latency-report.sh && bash tests/test-repo-queue.sh   # 旋鈕時序（含突變）、延遲量測、同 repo 佇列
bash tests/test-dispatch-bg.sh && bash tests/test-dispatch-bg-watch.sh && bash tests/test-dispatch-gate-bg.sh   # 背景 worker：啟動／續派／hard、回報與取消、Router 閘
bash tests/test-tg-send.sh && bash tests/test-tg-plugin-patch.sh && bash tests/test-tg-reply-thread.sh    # 直發至多一次（本機 stub）、plugin patch、回覆標註
bash tests/test-bg-autoheal.sh && bash tests/test-tg-snappy.sh   # 秒回：失敗自癒重派、秘書口吻直送；輸入中＋忙碌先回
node --test tests/test_tg_progress.mjs && bash tests/test-ctx-guard.sh   # 進度訊息（含 worker 模式）、閒置先壓縮
bash tests/test-plan-ticket.sh         # 規劃單、PASS 後自動派執行單、dispatch-bg 寫難度行
bash tests/test-free-models.sh && bash tests/test-brief-answer.sh && node --test tests/test_chat_prompt.mjs   # 動態免費池（不寫死模型）、免費先＋去識別＋exit 對照、對話邊界
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
- **11-07 省 token 審計**（Codex，主題：少花非免費模型、Router 永遠能聊天）：初判不通過。主 session 逐條裁決後修補：子代理一律 haiku、worker 預設 haiku、hard 改派 O、`brief-answer` 免費先＋去識別、免費模型改由 `bin/free-models` 動態取得、送出結果不明不重複轉述、telegram proxy 的 RPC 不再被頻道佇列卡住、`--from-chat` 參數解析、Router 開場注入只留必要段落（約 6.7KB → 2.3KB）。不採納：mid 預設改免費（訂閱是使用者選的品質換成本，可設 `DISPATCH_MID_ORDER=free`）。
- **11-07 審計六項修補**（尚未部署）：
  - `quick` 在 macOS 以 `/usr/bin/sandbox-exec` 事前 deny `file-write*`，只放行 OpenCode 的 XDG 資料／快取子目錄、`$TMPDIR` 與 `/dev/null`；cwd 一般檔仍禁止寫入（OpenCode 自身資料／快取例外）。保留事後 JSON 稽核。Linux／CI 沒有該工具時 stderr 警告降級；有工具卻套用失敗就停止，不會無聲退回。
  - 同 profile 禁讀 `$HOME/.creds`、`.ssh`、`.aws`、`.gnupg` 與任何 `.env*` 路徑。`QUICK_DENY_READ=/path/a:/path/b` 可追加；cwd（含 symlink 實體路徑）落在敏感目錄時 exit 4。**殘餘風險：一般檔案內容仍原樣送免費模型，沒有逐段 scrub；無 sandbox-exec 的系統只有敏感 cwd 拒絕與事後偵測，不能防止工具讀寫。**
  - 沙箱擋了憑證目錄後，若 `opencode.json` 有 provider 的金鑰引用那裡的檔案，OpenCode 會整個起不來。所以 `quick` 先寫一份去掉 `mcp` 與「引用檔案的 provider」的暫存設定，用 `XDG_CONFIG_HOME` 指過去；免費模型兩者都用不到（11-07 實測）。
  - `dispatch-bg` 在既有 ledger 鎖內 reserve，持鎖到 launcher 交接與登錄。thread 已有 running／未知狀態 worker 時，訊息以單檔原子 rename 存入 `state/mailbox/<thread>/`，不再 resume 複製。`dispatch-watch` 看到終態才把一批訊息續派同 thread，成功後清除該批；新訊息留給下一輪。
  - autoheal 先原子落地含 eid、固定 prompt 路徑的 intent，再重派；watch 下輪優先恢復 intent，已有對應 ledger 列只補 ACK，沒有才補派。launcher 已登錄後中斷不會重派第二次；登錄前完全中斷則依 intent 重做交接。
  - inbound 以 `tg:<chat_id>:<message_id>` 串起 received／ack／queued／worker-start／answer-sent，紀錄不含訊息內文。`latency-report --by-id [--json]` 輸出 `ack_s`（收件→確認）、`answer_s`（worker 開始→送答）、`completion_s`（收件→送答）、`queue_s`、`start_s`；缺階段印 `-`／null，不猜時間。原本沒有 id 的資料仍走既有 n／p50 與 `--stages`。
  - `ctx-guard` 在送 `/compact` 前取得 proxy 共用 maintenance lock，送文字前與 Enter 前各重查 transcript mtime／大小和 pane 輸入列。proxy 在鎖期間先確認收到、持久化排隊 channel，RPC 照常透傳；看到新的 `compact_boundary` 且輸入列閒置後釋放，最遲 600 秒過期。**殘餘風險：等待壓縮期間訊息只先確認；看不到完成標記時等到鎖逾期，並非零等待服務。**
- **2026-11-07 six audit fixes** (not deployed):
  - On macOS, `quick` wraps OpenCode with `/usr/bin/sandbox-exec`: deny file writes except OpenCode's XDG data/cache directories, `$TMPDIR` and `/dev/null`, while ordinary files in the query cwd stay read-only (OpenCode data/cache remains exempt). JSON event auditing remains. Missing sandbox-exec emits a downgrade warning; failure to apply an installed sandbox stops execution.
  - The same profile denies reads of `$HOME/.creds`, `.ssh`, `.aws`, `.gnupg` and any `.env*` path. Append colon-separated paths with `QUICK_DENY_READ`; a sensitive cwd, including its resolved symlink target, exits 4 before any model call. **Residual risk: ordinary file contents still go to free models without per-content scrubbing. Without sandbox-exec, only cwd rejection and after-the-fact auditing remain; tool reads/writes cannot be prevented.**
  - Because the profile blocks the credentials directory, OpenCode would refuse to start when its config points a provider key at a file there. `quick` therefore writes a temporary copy of `opencode.json` without `mcp` and without any provider that references a file, and points `XDG_CONFIG_HOME` at it. Free models need neither (verified live on 2026-11-07).
  - `dispatch-bg` reserves under the ledger lock and holds it through launch and registration. A running or unknown worker gets one atomic mailbox file per new message instead of another resume. After a terminal event, watch resumes the same thread with a persisted batch, removes that batch after successful handoff, and leaves newer messages for the next round.
  - Autoheal atomically persists an intent containing the eid and stable prompt before redispatch. The next watch resumes unfinished intents; an existing matching ledger row needs only ACK, otherwise one dispatch is retried. A crash after registration does not launch twice; a crash before registration retries the handoff from the intent.
  - `tg:<chat_id>:<message_id>` links received, ack, queued, worker-start and answer-sent in a content-free event log. `latency-report --by-id [--json]` reports receipt-to-ack (`ack_s`), worker-start-to-answer (`answer_s`), receipt-to-answer (`completion_s`), plus queue/start delays. Missing stages are `-`/null. Legacy n/p50 and `--stages` still use the existing transcript calculation.
  - Before `/compact`, ctx-guard takes a maintenance lock shared with the proxy and rechecks transcript mtime/size and pane input both before typing and before Enter. The proxy ACKs and persists channel messages while continuing RPC forwarding. A new `compact_boundary` with idle input releases the lock; expiry is capped at 600 seconds. **Residual risk: queued messages wait for compaction; if no completion marker is visible, they wait for lock expiry. This does not provide zero-wait service.**
- Each round Codex audits the repo against the article; the main session adjudicates every finding (partial agreement allowed) before fixing. Must-fix P0/P1 went 10 → 9 → 2 → 3 → **0 in round 5 (2026-11-04), VERDICT: PASS**; restart, watchdog install and public push were all cleared.
- P2 (2026-11-04): all three work orders converged under a "main session rules and writes the spec → executor → Codex audit / post-mortem → per-finding verdicts" loop, capped at 3 rounds each, fixing only reproducible in-scope highs:
  - **C**: behavioural knob-timing tests, Router reply latency measurement (`bin/latency-report`), and a per-repo queue. Codex rounds 6–9: highs 3 → 2 → 1 → 0.
  - **D**: the dispatcher becomes an independent `claude --bg` worker, and hard jobs become bg-hard. Rounds 10–11: highs 3 → 0.
  - **E**: latency stage breakdown (`--stages`). A bg job's PASS result is pushed straight to the user by `bin/tg-send`, at most once (`direct` = sending/sent/failed/unknown; an unknown outcome is never resent and raises an alert instead). When the user replies to that message, the proxy tags it `[回覆 bg thread=… job=…]` and lets the Router decide whether to continue the same worker. A spec review ran before dispatch (11 findings, 10 accepted); rounds 12–13 then took highs 1 → 0.
  - Many-to-many subscriptions and fan-out were ruled out: there is one user and one Router.
- **2026-11-07 token-saving audit** (Codex; scope: spend less on non-free models, keep the Router always free to chat). Initial verdict: not passing. After per-finding adjudication: every subagent is forced to haiku, the bg worker defaults to haiku, hard jobs go to O (free first), `brief-answer` is free-model-first behind the PII scrubber, the free model list comes from `bin/free-models` at run time, an unknown send outcome is never relayed twice, the Telegram proxy's RPC no longer waits behind the channel queue, `--from-chat` parsing is fixed, and the Router's injected rules shrink from ~6.7 KB to ~2.3 KB. Declined: making mid free by default (the subscription is the owner's chosen quality/cost trade; set `DISPATCH_MID_ORDER=free`).

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

**Architecture.** You chat with a Sonnet **Router** over Telegram. The Router never runs tools itself: a PreToolUse hook (`bin/dispatch-gate.mjs`) allows only Telegram replies, `ToolSearch`, `TaskStop`, `SendMessage`, background `dispatcher` subagents, and a few exact Bash shapes (`bin/dispatch-bg --from-chat <thread>` or `bin/dispatch-bg <thread> state/bg/<file>.md`, `Write` into `state/bg/`, `bin/quick <abs-cwd> '<question>'`, `bin/recall '<keywords>' --ask '<question>'`), so delegation is enforced by code, not by prompt. By default the Router hands each request to an independent `claude --bg` worker (`bin/dispatch-bg`, haiku) that survives Router restarts; the in-process dispatcher subagent is the fallback. The gate rewrites every subagent call to `model: haiku` in the background; work haiku cannot handle goes to O or `bin/oc-free-ask` instead of a bigger Claude model. Difficulty is pre-classified by a local ONNX model (Laya, zero tokens) and written into the worker prompt; the haiku worker may only raise it. Haiku never writes plans: for mid/hard it finds the working directory and hands the user's words to `bin/plan-ticket`, which asks O to write an executable work order; once that passes `deep-lint`, `bin/dispatch-watch` dispatches it automatically with zero tokens. The gate caps a mid/hard-tagged worker at 8 own tool calls (`MYTHOS_TIER_CAP`). The worker triages: easy → does it itself; mid → `bin/dispatch` to `dcq` with `DCQ_ORDER=default` (free models first, escalating to the OpenCode Go subscription — a real cost — only when every free model fails; easy jobs stay on `DCQ_ORDER=free`); hard → `dcq` with `DCQ_ORDER=default` (free models first, the subscription only after all free ones fail; `DISPATCH_HARD_BACKEND=bg` restores Sonnet bg-hard, `=deep` the old `deep-run`).

**Instant replies (2026-11-07).** The Router's turn only ever answers or dispatches. `bin/dispatch-bg --from-chat <thread>` builds the worker prompt from the Router transcript (`bin/chat-prompt.mjs`: the user's own words plus the last 8 messages), so the Router just says "收到" (got it). The gate rewrites `bin/quick` and `bin/recall --ask` through PreToolUse `updatedInput` to run in the background, and `bin/brief-answer` rewrites the answer as a plain secretary-style report sent straight to the user: the text is PII-scrubbed first (scrubber down = no model call, raw text sent), then up to two free models are tried, then haiku. Exit 7 means definitely not sent; exit 8 means the outcome is unknown, so callers must not relay it again. While the Router is busy, the Telegram proxy keeps the "typing…" indicator alive every 4 s and replies "收到，等等處理" (got it, will handle shortly). `bin/dispatch-watch` sends bg PASS results the same way, retries a failed or stalled bg job once on its own, and tells the user directly if the retry fails too. Workers show live progress via `bin/tg-progress.mjs --worker`, and `bin/ctx-guard` compacts the Router while it is idle (≥ 3 min, > 140K tokens) instead of mid-conversation.

**Quick lane.** `bin/quick` answers read-only questions with OpenCode free models (`bin/free-models` reads the dcq free tier at run time, so no model name is hard-coded; a paid fallback only if `QUICK_PAID` is set). On macOS it runs `opencode run --agent plan --dir <cwd>` inside sandbox-exec with read/write restrictions (other platforms warn and downgrade), audits the JSON tool events and discards the answer on any write or state-changing shell command, refuses questions containing PII, and requires every claim to quote the command and raw output so the caller can re-run one and compare.

**Memory lane.** `bin/recall '<keywords>'` lets the Router answer "what did we decide before" questions itself, with zero LLM calls: it queries claude-mem over its local HTTP API (read-only; the plugin is not loaded, so Mythos chats are not written into the shared memory), `fixindex find` (keeping only entries whose text actually contains the keywords, since the semantic ranker always returns something), and the main session's memory folder. `--obs <id>` / `--fix <id>` expand one record. The gate allows exactly `bin/recall '<text>'` or `bin/recall --obs|--fix <digits>`.

**Results and supervision (zero Router tokens).**
- `bin/dispatch-watch` (every 2 min) writes worker results to `state/events.jsonl` first, then delivers them to the Router pane; un-ACKed events are resent every 10 min, up to 5 times. A bg job's PASS result goes straight to the user via `bin/tg-send`, sent at most once; it only falls back to the Router when the send provably did not happen. Terminal states are delivered before any review; `bin/review-judge` (free model, hard time budget) filters out ON_TRACK spot checks so they never wake the Router.
- `bin/watchdog` (every 5 min): **L0** zero-token checks — stale locks, exhausted resends, Router not replying, jobs pending > 6 h, stalled deep transcripts, background agents blocked on permission prompts. **L1** only for what L0 cannot classify (new error lines in logs): a free model labels them KNOWN / NEW / NOISE. Payloads leaving the machine are field-whitelisted, then PII-scrubbed, then the scrubbed text is scanned with sensitive-canary rules (scrub down = nothing is sent); the scrubber is self-tested daily with fake PII. Fallback chain: first free model → second free model → local LLM gateway → rule table → plain alert. **L2** may only propose whitelisted knobs, applied when two different model families agree and the value is within bounds. `bin/watchdog ask "<question>"` answers questions about recent watchdog activity.

**State.** One ledger (`state/dispatch-jobs.tsv`, 8 columns) and the event queue share a single `flock` lock that is released automatically if the holder dies. Deep jobs are cancelled only through their recorded handle, never by guessing.

**Optional pieces.** Only Claude Code, Node, jq, tmux and `dcq` are required. Everything else degrades on its own: `bin/quick` needs opencode (exit 6 without it, so the Router dispatches a worker instead); `bin/recall` uses whichever of claude-mem's local worker, `fixindex` and the Claude Code auto-memory folder exist (pick with `RECALL_SOURCES=mem,fix,md`; exit 6 if none); mid tickets fall back to the OpenCode Go subscription (a monthly cost) after the free models fail, set `DISPATCH_MID_ORDER=free` to stay free-only; Telegram is optional (`CHANNELS=`). Also optional: `triage` and `wo-verify` from orchestrator (built-in fallbacks), the local PII scrubber `:4102` and `:4000` gateway for the free-model review/watchdog legs (fail closed: review returns UNKNOWN and the Router is woken as before), the sensitive-canary plugin (built-in regex), and `state/cap-exempt.txt` for extra self-cap exemptions. See the table under *Quick start*.

**Install.** See *Quick start* above; `launchd/install.sh` renders the plist templates (`ONLY=<label>` for one job, `NO_LOAD=1` to only render). Tests use fake tmux / models / dcq, need no network or keys, and run on macOS CI.

## License

MIT
