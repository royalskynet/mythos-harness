# DEVLOG

開發紀錄，新的在上面。只記做了什麼、為什麼；不含本機路徑、帳號與內部計畫。
Development log, newest first. It records what changed and why, without local paths, accounts or internal plans.

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
