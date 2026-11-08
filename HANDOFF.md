# HANDOFF — 接手開發用

最後更新：2026-11-08。完成的事記在 DEVLOG.md，這份只記「現在狀態、怎麼部署、還沒做完的事」。新的進度直接改這份。

## 這輪做了什麼（2026-11-08 晚）

使用者抱怨 Router 不說人話、問「那是什麼」答不出來。已上線：

1. **說話規則套 Genie 本體，不複製**：`bin/genie-context` 找 Genie、印 `router/prefs.py context`。
   - 找法：`MYTHOS_GENIE_DIR` → Claude Code 裝的版本（`~/.claude/plugins/installed_plugins.json` 裡 `genie-harness@genie-harness` 的 user scope `installPath`，帶版本號，每次現查）→ `~/dev/genie-harness`。
   - 偏好檔 `state/genie-prefs.json`（runtime，不進 git）。改等級：`GENIE_PREFS=state/genie-prefs.json python3 <genie>/router/prefs.py set level <beginner|intermediate|expert>`。
   - Router：`profiles/mythos/plugins/mythos-tools` 的 `pre_llm_call` 每回合注入（約 0.2 秒，不快取）。
   - 背景摘要：`bin/dispatch-bg` 把同一段附在 worker prompt 尾端，限「摘要：」段。
2. **字數放寬**：`bin/adhd-lint.mjs` 預設 500 字／12 行／每行 60；清單後可留一行不編號收尾。worker 的 SOUL 同步改成 500。
3. **追問結果直接解釋**：
   - Router SOUL 把「答案在對話裡就白話答」放在「系統問題一律派工」前面，寫明優先。
   - 外掛偵測「短句問意思＋近 8 則有［背景結果］」時，每回合多注入一行提醒（`_asks_about_last_result`）。

## 部署步驟（改 profiles/ 下的檔之後）

1. 備份並複製到 `~/.hermes/profiles/<profile>/` 對應位置（`bin/` 下的檔直接從 repo 執行，不用複製）。
2. 改了外掛：`launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway-mythos`，等 `logs/gateway.error.log` 出現新的 `Connected to Telegram`（約 20–40 秒）。
3. **改了 SOUL.md 一定要做**：Hermes 每段對話把系統提示凍結在 `state.db`，重啟不會重讀。
   - 刷新：`hermes -p mythos sessions refresh-prompts --session <session_id>`（保留對話）。
   - 驗證：`sqlite3 -readonly ~/.hermes/profiles/mythos/state.db "select p.prompt from sessions s join system_prompts p on p.hash=s.system_prompt_hash where s.id='<id>'" | grep <新字串>`。

## 測試

- 本輪新增或改動：`tests/test-genie-context.py`、`tests/test-adhd-lint.sh`（g）、`tests/test-dispatch-metadata.py`（Genie 兩例）。都做過突變檢查，改壞會紅。
- `tests/` 被 `.gitignore` 白名單擋，新測試要 `git add -f`。
- `test-compact-lock`（CI 紅燈）已修：測 Claude TUI 流程的測試要 `export MYTHOS_RUNTIME=claude`，ctx-guard 預設是 Hermes 模式。
- 既有紅燈（本輪之前就紅，與本輪無關）：`test-superagent-replay.py`、`test-test-guard.sh`。`check_1107.py` 是輔助腳本，要帶 mode 參數，單獨跑會 IndexError，不算紅燈。

## 還沒做完 / 待驗證

1. **真實對話還沒驗證**：Router 用免費模型。若被追問仍回「我查一下」，下一步在 `router-guard` 的 `pre_tool_call` 擋 `mythos_dispatch`（條件同 `_asks_about_last_result`），附訊息叫它直接答。
2. 背景摘要套 Genie 後的實際效果，等下一則摘要看。
3. P6 追問影子模式：觀察到 20 個候選後用 `bin/followup-report --routed` 比對。
4. 結果防幻覺（P6h）的本機判斷 ledger：約 11-22 看誤判率，決定要不要讓它擋。
5. 派工佇列（O／dcq）有兩個已知問題：測試的 runner 漏到正式 socket、逐單指定模型無效。已在派工工具的 repo 開 issue，由另一條線處理，這裡不動。

---

Handoff for the next developer. Done work is in DEVLOG.md; this file holds current state, deploy steps and open items. On 2026-11-08 the Router started applying Genie's voice rules from the installed Genie (resolved via Claude Code's installed_plugins.json, not copied). Background summaries got the same rules. Reply limits went to 500 characters, and follow-up "what is that" questions are now answered in place. Hermes freezes the system prompt per conversation, so after any SOUL change run `hermes sessions refresh-prompts`. The red `test-compact-lock` in CI was fixed by setting `MYTHOS_RUNTIME=claude`. Open items: real-chat verification, P6 observation, and the claim-guard ledger review.
