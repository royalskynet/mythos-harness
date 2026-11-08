# DEVLOG

開發紀錄，新的在上面。只記做了什麼、為什麼；不含本機路徑、帳號與內部計畫。
Development log, newest first. It records what changed and why, without local paths, accounts or internal plans.

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
