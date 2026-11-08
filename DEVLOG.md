# DEVLOG

開發紀錄，新的在上面。只記做了什麼、為什麼；不含本機路徑、帳號與內部計畫。
Development log, newest first. It records what changed and why, without local paths, accounts or internal plans.

## 2026-11-08 — Router 套 Genie 說話規則、放寬字數 / Router uses Genie voice rules, longer replies

- 使用者回報 Router 不說人話，問「那是什麼」也講不出來。原因有兩個：Router 沒有白話規則可依；字數上限 220 字、6 行，又要求第二行起全部編號，解釋一件事根本放不下。
- Router 外掛每回合執行本機已安裝的 Genie `prefs.py context`，把輸出當本回合提示注入；不複製規則，Genie 更新就跟著更新。偏好檔放 runtime 目錄。找不到 Genie 或執行失敗就不注入，不擋對話。
- 上限放寬為 500 字、12 行、每行 60 字；清單後可留一行不編號的收尾。SOUL 加一條：「那是什麼」的答案在這段對話裡就自己白話解釋，要查機器上的事實才派工。
- 背景工作直接寄給使用者的摘要也套同一份規則：派工時把 Genie 輸出附在工作指示尾端，限定用在「摘要：」段。
- 上線後她仍回「我查一下」，原因有兩個：舊規則「系統／專案問題一律派工」壓過新規則；Hermes 每段對話會凍結當時的系統提示，重啟也不會換。已把白話解釋那條移到最前面並寫明優先；外掛在使用者追問剛轉過的結果時，每回合加一行提醒；並用 `hermes sessions refresh-prompts` 讓進行中的對話改用新規則。
- 新增 `tests/test-genie-context.py`；`test-adhd-lint` 加一則約 270 字、7 行的回覆，預設上限改回 220 時會失敗。舊測試釘住舊上限，照原意驗格式。

- The user reported that the Router did not talk plainly and could not explain "what is that". Two causes: the Router had no plain-language rules, and the 220-character, 6-line cap with mandatory numbering after the first line left no room to explain anything.
- The Router plugin now runs the locally installed Genie `prefs.py context` every turn and injects its output as turn context. The rules are not copied, so Genie updates apply automatically. The prefs file lives in the runtime directory. If Genie is missing or fails, nothing is injected and the chat continues.
- Limits are now 500 characters, 12 lines and 60 characters per line, and a list may end with one unnumbered closing line. SOUL gained a rule: when the answer to "what is that" is already in the conversation, explain it plainly; dispatch only for facts on the machine.
- Summaries that background workers send straight to the user follow the same rules: dispatch appends the Genie output to the worker prompt, scoped to the summary section.
- After deploy she still answered "let me check". Two causes: the older "always dispatch system or project questions" rule outranked the new one, and Hermes freezes the system prompt per conversation, so a restart does not reload it. The explain rule now comes first and says it takes priority, the plugin adds a one-line hint when the user asks about a result just relayed, and `hermes sessions refresh-prompts` moved the running conversation to the new rules.
- Added `tests/test-genie-context.py`. `test-adhd-lint` gained a reply of about 270 characters in 7 lines that fails if the default cap goes back to 220. Older tests pin the old limits so they still check format as intended.

## 2026-11-08 — 「詳細」全文送不出 / Full-text replies failed

- 使用者回「詳細」時，Router 回報「權限問題」。原因是外掛直接執行 `bin/tg-send`，這支腳本在 git 裡是 644，執行時拋出 PermissionError；Mythos 的權限設定與此無關。收件匣的 TG 退路也走同一支腳本。外掛測試用的假執行檔會自己 chmod，所以測試沒抓到。已補上執行權，並新增 `tests/test-plugin-bin-exec.sh`：外掛直接執行的 bin 在 git 裡必須是 100755。

- Replying "詳細" (details) produced a "permission problem" message. The plugin executes `bin/tg-send` directly, but git stored the script as 644, so the call raised PermissionError; Mythos permission settings were not involved. The inbox Telegram fallback calls the same script. Plugin tests missed this because their fake executables chmod themselves. The script is now executable, and `tests/test-plugin-bin-exec.sh` requires every bin the plugin executes directly to be 100755 in git.

## 2026-11-08 — P6 決策備忘 / P6 decision notes

- 不採用程式碼知識圖譜（Graphify 類）給 worker 找檔。實測一題系統提問 18 次模型呼叫，卡點在拼湊執行中設定（模型、派工順序、排程），不在找檔；圖譜只知道程式碼位置，查設定還指到過時文件。社群 360 次試驗（srijansriv.com/graphify-benchmark）與上游 issue（Graphify-Labs/graphify#985）也未見準確率或成本改善。改用 `bin/system-facts` 直接讀設定。
- 防幻覺的 LLM 層只走本機 Laya（laya-only）。本機 cascade 未限制可上雲的呼叫者，不帶 laya-only 就會打付費雲端，且 worker 結果可能含個資；本機判斷不出機、不花錢。先只記錄，累積約兩週 ledger 後依誤判率決定是否讓它擋。Hermes 上游查無可用的防幻覺外掛（相關 PR 未接進執行流程）。
- 回歸基準：main 上既有紅燈為 test-bg-autoheal、test-compact-lock、test-dispatch-bg-watch、test-tg-send、test-watchdog、test-test-guard、adhd-outlet，與 P6 無關、尚未處理。回歸比對排除會讀外部工具目錄的 test_no_cabinet。
- 工單教訓：禁令寫得比需要寬（禁讀整個外部目錄、禁讀所有 *.env），會與驗收要跑的測試衝突，執行人照規則停工，連續兩次。之後派工單先過 lint，禁令只列真實憑證位置，並註明測試自建的夾具可讀寫。

- No code-knowledge graph (Graphify-style) for worker file discovery. A measured system question took 18 model calls; the cost came from assembling runtime settings (models, dispatch order, schedules), not from finding files. The graph only knows code locations and pointed to stale docs for settings. A 360-trial community benchmark and an upstream issue showed no accuracy or cost gain. `bin/system-facts` reads the settings directly instead.
- The LLM layer of the claim guard uses local Laya only (laya-only). The local cascade does not restrict which callers may reach the paid cloud judge, so a request without laya-only would spend money and could send personal data off the machine. Local judgement stays on the machine and is free. It is observation-only until about two weeks of ledger data show its error rate. No usable anti-hallucination plugin exists upstream in Hermes.
- Regression baseline: the existing red checks on main are test-bg-autoheal, test-compact-lock, test-dispatch-bg-watch, test-tg-send, test-watchdog, test-test-guard and adhd-outlet; they are unrelated to P6 and remain open. Regression comparison excludes test_no_cabinet, which reads an external tool directory.
- Ticket lesson: prohibitions wider than needed (a whole external directory, every *.env file) conflicted with tests the acceptance had to run, and the executor stopped twice by the rules. Tickets now pass lint first, list only real credential locations, and state that fixtures created by tests may be read and written.

## 2026-11-08 — P6h 結果防幻覺 / P6h claim guard

- worker 摘要直發前新增零 LLM 檢查：commit 必須存在於工作 repo 或 Mythos，網址必須出現在該 job 工單、結果細節或工具輸出。worker session 無法唯一對應時，網址只記錄原因。
- 查不到的 commit／網址改交 Router 轉述，附白話警示與單次告警。guard 故障保留直發並記 log。送出後背景復用 checkClaims，固定本機 cascade 的 laya-only 模式；三秒逾時、503 或錯誤記 undecided，缺程式庫記 unavailable，不影響投遞。
- ledger 留在忽略的 runtime 目錄，摘要最多二百字。新增離線 git／SQLite／cascade 夾具，涵蓋退路與單次告警，並以移除 header／SHA 驗證的突變確認測試會紅。

- 指定驗收與兩個突變檢查通過。完整回歸新增一項綠燈，四項既有失敗均在原始版本重現，沒有新增失敗；保留既有八個測試檔改動。

- Worker summaries now pass a zero-LLM check before direct delivery: commits must exist in the working repository or Mythos, and URLs must appear in the job prompt, result details or tool output. Ambiguous worker sessions make URL findings observation-only with a recorded reason.
- Missing commits or unsourced URLs route through the Router with a plain warning and one alert. Guard failures preserve delivery and log the error. After delivery, background checkClaims uses the local cascade with a fixed laya-only header; a three-second timeout, HTTP 503 or errors record undecided, and a missing library records unavailable, without affecting delivery.
- The ledger stays in ignored runtime storage and keeps at most two hundred summary characters. Offline Git, SQLite and cascade fixtures cover fallback and single alerts; removing the header or SHA verification must fail the tests.

- Required checks and both mutation checks passed. Full regression adds one passing check with no new failures; all four existing failures reproduce on the original version. The eight pre-existing test-file edits remain untouched.

## 2026-11-08 — P6g 閒聊直接回 / P6g direct small talk

- Router 對閒聊與情緒話用同一個口吻直接回一兩句，不呼叫工具、不派工。判斷原則：回答需要這台機器上的事實才派工，不需要就自己回；要查、要做、問系統／專案現況、要意見或分析仍照舊派工。
- The Router answers small talk and emotional remarks directly in the same voice, using one or two sentences without tools or dispatch. Dispatch when the answer requires facts from this machine; otherwise answer directly. Requests to investigate, act, report system or project status, or provide opinions or analysis still use dispatch.

## 2026-11-08 — P6f 小派工省力 / P6f lighter small dispatches

- Router 秒回改用短口語，一句結束並輪換說法。
- 新增零 LLM 的 `bin/system-facts`，從原始設定與呼叫點解析角色模型、fallback、派工順序、規劃與唯讀快查來源；缺項明確報錯並回非零。worker 先查這份摘要，缺哪項才補查哪項。
- Router 範本測試未隔離 worker 目錄，讓測試 checkout 路徑污染正式 worker 範本。測試改用暫存目錄；worker-sync 拒絕 linked worktree 未指定目標的同步。新增離線夾具與拒寫測試，並以突變驗證防護有效。

- Router acknowledgements now use one short conversational sentence with varied wording.
- Added zero-LLM `bin/system-facts` to parse role models, fallbacks, dispatch order, planning and read-only lookup sources from settings and call sites. Missing fields report their source and return nonzero. Workers consult this summary first, then inspect only missing facts.
- The Router template test used the default worker destination, contaminating production templates with a test checkout path. It now uses a temporary destination, and worker-sync rejects linked worktrees without an explicit destination. Offline fixtures and refusal tests include mutation checks.

## 2026-11-08 — P6e observe 上線與接續 / P6e observe rollout and next steps

- 2026-11-08 起，線上 Mythos gateway 以 `MYTHOS_FOLLOWUP_DIRECT=observe` 執行，由 gateway 的服務管理器環境變數注入。新版 mythos-tools 外掛已部署，`bin/hermes-contract` 無 FAIL。
- observe 對 Router 行為無影響：所有訊息仍交 Router，背景只寫觀察紀錄。上線當下 `bin/followup-report` 為 candidates=0、would_queue=0。
- 回退方式：移除該環境變數並重啟 gateway；部署前的外掛與服務設定都有備份。
- 部署備忘：改了服務管理器的環境變數後，只 stop/start 不夠時需明確 kickstart。本次第一次重新載入後 gateway 未自動起來，手動啟動後恢復。
- 接續開發（未完）：累積真實回覆樣本後，用 `bin/followup-report` 逐則核對 would_queue 與實際 Router 決定是否一致，再人工決定是否切 auto。
- 切 auto 前確認：停止請求一律交 Router；claim 逾時時重複而不漏；`hermes-contract` 仍檢查 async hook 被 await 與 inbound skip。
- Telegram proxy（tg-commands）目前未在線上載入，`--seen` 只供它使用；若之後啟用 proxy，需另驗 observe／auto 在該路徑的行為。
- main 上既有的 6 個紅燈測試（test-bg-autoheal、test-compact-lock、test-dispatch-bg-watch、test-tg-send、test-watchdog、adhd-outlet）與 P6 無關，尚未處理。

- Since 2026-11-08, the live Mythos gateway runs with `MYTHOS_FOLLOWUP_DIRECT=observe`, injected through the gateway service manager's environment variables. The updated mythos-tools plugin is deployed, and `bin/hermes-contract` reports no FAIL.
- observe has no effect on Router behavior: all messages still go to the Router, while the background only writes observations. At rollout, `bin/followup-report` showed candidates=0 and would_queue=0.
- Rollback: remove the environment variable and restart the gateway. The plugin and service configuration were both backed up before deployment.
- Deployment note: after changing the service manager's environment variables, an explicit kickstart is required when stop/start alone is insufficient. The gateway did not start automatically after the first reload in this rollout; starting it manually restored service.
- Next steps (unfinished): collect real reply samples, then use `bin/followup-report` to compare would_queue with the actual Router decision for each reply before manually deciding whether to enable auto.
- Before enabling auto, verify that stop requests always go to the Router, claim timeouts allow duplicates rather than lost messages, and `hermes-contract` still checks that the async hook is awaited and inbound skip is supported.
- The Telegram proxy (tg-commands) is not currently loaded in production; `--seen` is only for that proxy. If the proxy is enabled later, verify observe / auto behavior on that path separately.
- The 6 existing failing tests on main (test-bg-autoheal, test-compact-lock, test-dispatch-bg-watch, test-tg-send, test-watchdog, adhd-outlet) are unrelated to P6 and remain unresolved.

## 2026-11-08 — P6d 喚醒不遺失 / P6d no lost wake-ups

- dispatch-bg 完成後的單次喚醒若撞上 dispatch-watch 鎖，原本直接退出，持鎖者已掃過的新完成單只能等排程補掃。現在撞鎖先建立鎖旁的持久待掃旗標；持鎖者消費旗標再掃，釋鎖後再檢查並嘗試接手，登記者也再取一次鎖以關閉延遲登記空窗。
- 每支最多八輪，超限釋鎖且保留旗標，交下次喚醒或排程接手。EXIT／逾時與 watchdog 的 stale lock 清理維持既有鎖目錄契約，旗標獨立保留。固定次數睡眠重試無法涵蓋正常長掃描，且耗盡後仍可能丟失喚醒，因此不採用。
- brief 改寫案例先等前輪解鎖；離線測試另強制持鎖、注入最後檢查與釋鎖間的完成通知，確認自動接手、TG／brief 各一次，並驗證持續流量的輪數上限。

- A completion wake-up previously exited immediately when dispatch-watch was locked. If the owner had already scanned the ledger, newly completed jobs waited for the scheduled sweep. Contenders now persist a rescan marker beside the lock. The owner consumes it and scans again, then checks after release and attempts to reacquire. Contenders also retry acquisition after registration to close delayed-registration races.
- Each process runs at most eight scans, releasing the lock and preserving pending work at the limit for the next wake-up or scheduled sweep. EXIT, deadline and watchdog stale-lock cleanup retain the existing lock-directory contract; the marker survives independently. Fixed-count sleep retries cannot cover normal long scans and can still lose wake-ups when exhausted.
- The brief-rewrite case waits for the prior scan to unlock. Separate offline cases force contention and inject a completion between the final check and lock release, verifying automatic handoff and exactly one TG delivery and brief call. Continuous wake-ups also verify the scan bound.

## 2026-11-08 — P6c 接 auto 前的加固 / P6c hardening before auto

- 依 DSH Subscriptions／Handing back 原則，訊息在入站即定唯一擁有者。async hook await 入列，成功回 `skip`；worker 擁有的訊息不交 Router 決策，停止請求則交 Router 取消。預設仍 off，建議先 observe、看過 Decisions 再人工切 auto。
- 新增 `--claim-router`，與入列共用 ledger 鎖；queued 回 `seen`，否則寫 routed，晚到入列以 stale／exit 8 拒絕。入列 2 秒、claim 1 秒，逾時 kill 並回收子行程群組；claim 失敗仍交 Router，避免漏訊息。
- 移除 session 綁定、行程全域入站 context、chat 對照檔與外掛派工前的 `--seen` 檢查。`--seen` 仍供 Telegram proxy 使用；S3 重播改為入站歸屬模型，S1／S2 指標維持不變、S3 重複結果為 0。
- meta.json 存在即唯一權威，repo 空不退讀正文。無 meta 舊檔保留開頭標頭相容；一般入口先遷移正式標頭，interrupt／信箱批次繼承舊 job 宣告，Hermes 佇列保留 meta。
- 加入 claim 20 輪競爭、逾時清理與事件迴圈前進、停止請求、meta 權威與舊格式繼承測試。Hermes 契約檢查 async callback 仍被 await、入站仍接受 skip，並驗證移除行為會失敗。

- Following DSH Subscriptions / Handing back, each message gets one owner at ingress. The async hook awaits queueing and returns `skip` on success. Worker-owned input bypasses Router decisions; stop requests go to the Router for cancellation. Default remains off: observe first, review Decisions, then enable auto manually.
- `--claim-router` shares the ledger lock with queueing: queued input returns `seen`; otherwise a routed receipt rejects late queueing as stale with exit 8. Queueing has a 2-second bound, claiming 1 second; timeout kills and reaps the subprocess group. Claim failure falls through to the Router to avoid lost messages.
- Removed session binding, process-global inbound context, chat mapping files and the plugin's dispatch-time `--seen` check. The Telegram proxy still uses `--seen`. S3 replay now models ingress ownership; S1 / S2 metrics are unchanged and S3 duplicate results remain zero.
- Existing meta.json is the sole authority; an empty repo never falls back to body headers. Legacy files without metadata retain opening-header compatibility. Normal ingress migrates formal headers; interrupts and mailbox batches inherit legacy job declarations; the Hermes queue preserves metadata.
- Added 20-round claim races, timeout cleanup and event-loop progress, stop requests, metadata authority and legacy inheritance tests. Hermes contracts verify callbacks are awaited and inbound skip remains accepted, with negative cases for removed behavior.

## 2026-11-08 — P6 追問影子模式 / P6 follow-up shadow mode

- `MYTHOS_FOLLOWUP_DIRECT` 分成 `off`（預設）、`observe`、`auto`；舊值 `1` 等同 `auto`。影子模式只把是否接受、thread 提案與判定理由寫入 `state/followup/observations.jsonl`，不入列；`bin/followup-report` 依事件鍵去重，統計候選、接受數與 Router thread 一致率，先量測再接自動派工。
- Hermes 外掛新增 `pre_gateway_dispatch`：只觀察 allowlist 內、帶 reply 的 Telegram 訊息。子行程在背景執行、上限 2 秒，例外全吞，hook 永遠回 `None`；觀察檔不存使用者原文。Hermes 的 `auto` 本輪仍強制走 `observe`，並記錄尚未接線，避免未驗證的直通入列影響前台。
- 收據以 `chat_id + message_id` 為事件鍵，區分 `pending`、`queued`、`stale`。入列中斷後依信箱檔與 generation 對帳，不重複入列、不復活取消前的訊息；`followup-direct --seen` 讓 Router 派工前查已直通事件，命中回「已接續原工作」。P5 重播的 S3 重複結果降為 0。
- repo 與唯讀旗標移到 `<prompt>.meta.json`，避免正文中段的 `repo=`／`readonly=1` 改變排程。沒有 meta 的舊檔只讀開頭 5 行標頭；續派繼承同 thread 前一張 job 的 meta，interrupt 也能繼承舊格式標頭。
- 取消時把 generation bump、清信箱與清佇列放進同一把 ledger 鎖，與追問入列互斥，防止取消後留下舊方向訊息。
- **P6c 已處理**：auto／Router 競態以入站歸屬與 routed 收據解決；session 綁定改為移除，不再依賴 hook key 與 turn key 相等；meta 存在時為唯一權威，repo 空不讀正文。

- `MYTHOS_FOLLOWUP_DIRECT` now supports `off` (default), `observe` and `auto`; legacy `1` means `auto`. Shadow mode only records acceptance decisions, proposed threads and reasons in `state/followup/observations.jsonl`, without queueing. `bin/followup-report` deduplicates by event key and reports candidates, acceptance counts and Router thread agreement, so routing can be measured before automatic dispatch is connected.
- The Hermes plugin adds `pre_gateway_dispatch`, restricted to allowlisted Telegram replies. A background subprocess has a 2-second limit; exceptions are swallowed and the hook always returns `None`. Observations omit the user's text. Hermes `auto` is still forced to `observe` in this release and logs that automatic queueing is not wired, keeping unverified direct queueing out of the front end.
- Receipts use `chat_id + message_id` as the event key, with `pending`, `queued` and `stale` states. Recovery reconciles mailbox files and generations without duplicate queueing or reviving cancelled messages. Before dispatching, the Router checks `followup-direct --seen` and replies “已接續原工作” for an event already queued directly. Duplicate results in the P5 S3 replay fell to 0.
- Repo and read-only declarations move to `<prompt>.meta.json`, so `repo=` / `readonly=1` in the middle of a request cannot change scheduling. Legacy files without metadata only read headers in the first 5 lines. Follow-ups inherit metadata from the previous job in the same thread; interrupts also inherit legacy headers.
- Cancellation now bumps the generation and clears the mailbox and queue under the same ledger lock used by follow-up queueing, preventing stale instructions from surviving cancellation.
- **Addressed in P6c**: ingress ownership and routed receipts resolve the auto / Router race; session binding was removed rather than relying on equal hook and turn keys; existing metadata is the sole authority, including an empty repo.

## 2026-11-08 — Hermes 版上線 / Hermes goes live

- Telegram 前台從 Claude Code TUI 換到 Hermes。Router（profile `mythos`）只有三個工具；worker（profile `mythos-worker`）用 `hermes -z` 單次行程。
- 兩個 profile 收成 Hermes 原生 distribution。`bin/hermes-contract` 檢查外殼與 Hermes 的接點；`bin/hermes-upgrade` 先 pull Hermes、再 pull profile，契約過才重啟。
- worker 結果第一行固定狀態行（完成／已轉交／受阻／失敗）。受阻、失敗、空輸出都轉免費派工鏈重做，不直接丟回使用者。
- 同時最多 3 個 worker，超出的 FIFO 排隊，取消會刪排隊項。
- 「詳細」優先取該對話串的全文，對不到才退回最新一則。
- 公開檔案的本機路徑改成 `~`／`${HOME}`。

- The Telegram front end moved from the Claude Code TUI to Hermes. The Router (profile `mythos`) has three tools; the worker (profile `mythos-worker`) runs one-shot `hermes -z`.
- Both profiles became native Hermes distributions. `bin/hermes-contract` checks every attachment point; `bin/hermes-upgrade` pulls Hermes, then the profiles, and restarts only when the contract passes.
- Worker results start with a fixed status line. Blocked, failed and empty results are retried through the free-model dispatch chain instead of reaching the user.
- At most 3 concurrent workers; the rest queue FIFO, and cancel removes queued items.
- "Details" now prefers the full text of the same thread and falls back to the newest one.
- Local paths in public files were replaced with `~` / `${HOME}`.

## 2026-11-07 — 秒回與省 token / Instant replies and token savings

- Router 收到要做的事只回「收到」，背景 worker 從對話紀錄自己抓原話。
- 子代理一律用小模型；困難任務先派免費模型。免費模型清單執行時動態取得，不寫死。
- 給使用者的訊息加格式檢查（ADHD 五條：先講結果、短行、少列表）。
- 唯讀快查加 macOS sandbox：禁寫、禁讀憑證目錄。
- 延遲量測改用訊息 id 串起收件、確認、派工、送答各階段。

- The Router answers work requests with a short acknowledgement; the background worker reads the original request from the transcript.
- Subagents use a small model; hard tasks go to free models first, and the free-model list is fetched at run time.
- User-facing messages pass a format check: result first, short lines, few lists.
- Read-only quick lookups run under a macOS sandbox that blocks writes and credential directories.
- Latency is measured per message id across receipt, acknowledgement, dispatch and answer.

## 2026-11-03 – 11-04 — 雙層架構成形 / The two-layer design

- 對照 DSH super-agent 文章做 Router／Worker 雙層。每輪由另一個模型審計，主 session 逐條裁決後修補，必修項 10 → 0。
- worker 改成獨立背景行程，Router 重啟也不斷。
- 零 token 的 `dispatch-watch` 收結果、重送、抽查；`watchdog` 抓死鎖與卡住。
- 抽查先給免費模型判斷，沒跑歪的不打擾 Router。

- Built the Router / Worker split against the DSH super-agent article. Each round another model audited the repo and every finding was adjudicated; must-fix items went from 10 to 0.
- The worker became an independent background process that survives Router restarts.
- A zero-token `dispatch-watch` collects results, retries and spot-checks; `watchdog` catches deadlocks and stalls.
- Spot checks are judged by a free model first, so on-track work never interrupts the Router.
