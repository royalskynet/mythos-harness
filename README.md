# mythos-harness

[![test](https://github.com/royalskynet/mythos-harness/actions/workflows/test.yml/badge.svg)](https://github.com/royalskynet/mythos-harness/actions/workflows/test.yml)

跑在 [Hermes](https://github.com/NousResearch/Hermes-Agent) 上的 Telegram 助手外殼，現役架構以 [CLAUDE.md](CLAUDE.md) 為準。

A Telegram assistant shell on [Hermes](https://github.com/NousResearch/Hermes-Agent). The current architecture is defined in [CLAUDE.md](CLAUDE.md).

## 現役架構 / Current Architecture

- **Gateway**：`ai.hermes.gateway-mythos`，由 launchd 管理，異常結束自動重啟。/ Managed by launchd with automatic restart.
- **人格與行為 / Persona & behavior**：`profiles/mythos/SOUL.md`。
- **派工 / Dispatch**：使用 Hermes 內建 `delegate_task`，由子代理背景執行工具。/ Uses Hermes built-in `delegate_task`; subagents run tools in the background.
  - 追問接續 / Follow-ups：任務還在跑時，補充或改方向用 `action="steer"`，取消用 `stop`，問進度先 `list`；任務結束才重新派。/ While a task runs, use `steer` to redirect, `stop` to cancel, `list` before answering "is it done?"; spawn anew only after it ends.
  - 結構化回報 / Structured results：`router-guard` 自動補 `output_schema`（含多 task 逐一補），子代理回傳 `status`（done／needs_human／failed）、`evidence`、`artifacts`、`question`、`remaining`；Router 依 status 轉述，沒有 JSON 就照原文講。/ `router-guard` injects an `output_schema` (per task too); the Router relays by `status` and falls back to raw text.
  - 隔離修改 / Isolated edits：子代理改 git repo 前先 `git worktree add`，驗過再合回（寫在 `AGENTS.md`，未開 Hermes 原生 `worktree_isolation`）。/ Subagents edit git repos in a `git worktree` first (rule in `AGENTS.md`; Hermes native `worktree_isolation` stays off).
- **記憶 / Memory**：`memory.provider: claude-mem`；線上 `plugins/claude-mem` symlink 到 `~/.hermes/plugins/claude-mem`。每輪注入由 gateway plist 的 `CLAUDE_MEM_HERMES_TURN_LIMIT=0`、`TURN_MAX=300` 控制。/ Turn injection throttled by gateway plist env vars.
- **Hard 判定**：本機分級器只算最高一級、機率過 0.3（`MYTHOS_TRIAGE_CONFIG`，11-12 用 42 筆派工重播校準，21→3）；手動用 `/hard [任務]`（10 分鐘內下一件派工）。hard 子代理先跑 `bin/plan-hard`（回合上限 `MYTHOS_PLANNER_MAX_TURNS`，預設 6）。
- **省 token**：`compression.threshold_tokens`、`compression.proactive_prune_tokens`、`delegation.max_summary_chars`、`delegation.compression_threshold_tokens`（config.yaml，11-12 起）。
- **記憶分工**：長期記憶＝Hermes 內建 `memories/`（MEMORY.md、USER.md）＋claude-mem；`state.db` 只是對話紀錄庫，`sessions.auto_prune` 保留 7 天，Router 不用 `session_search`。
- **線上 profile / Live profile**：`~/.hermes/profiles/mythos`，保留本機設定。/ Local settings preserved.
- **`profiles/mythos-worker/`**：deprecated，保留當 one-shot 參考；派工走 mythos 的 `delegate_task`。/ Retired; kept for one-shot reference.

### 兩層架構：Router ↔ Worker

**Router（前台）**：只負責聊天、查記憶、派工。`router-guard` 的 PreToolUse 閘**硬擋**所有動手工具（`terminal`、`write_file`、`read_file`、`browser_navigate`、`web_search` 等），只放行 `delegate_task`、`mythos_recall`、`memory`。

**Worker（背景子代理）**：實際執行工具。`router-guard` 強制 `background=true` 並自動為每個 task 注入 `output_schema`（含 `status`/`evidence`/`artifacts`/`question`/`remaining`）。子代理結束時回傳結構化 JSON，Router 依 `status` 轉述；缺 JSON 時照原文回覆。

追問工具：任務進行中用 `steer` 改方向、`stop` 取消、`list` 查進度；任務結束才能重新派工。

### Delegation Fallback 鏈（11-25 設計）

`delegation.fallback_providers` 是**釘住子代理**專屬的鏈（**不繼承頂層** `model.fallback_providers`）。設計階梯：

1. **of 免費層**（opencode-go `*-free` 系列）：`hy4-flash-free`、`beam-free`、`iceman-contributor-free` — Zen 免費層可直打 API、不吃月配額
2. **od 品質腿**（deepseek）：`deepseek-v4.1-flash` — 配額健康時當品質腿，配額死時自動跳過
3. **oo 自有 key**（omniroute `nim-pool`）：跨 provider 活路，NIM 池冷啟動可能幾分鐘，只當最後手段

**為什麼要這樣**：429 會把同 provider 的憑證池標記 exhausted，導致該 provider 所有 model 被 `_candidate_pool_exhausted` 跳過；Go 月配額耗盡時，只有非 Go 腿（omniroute）能存活。

Router 層同樣有頂層 `model.fallback_providers`（`beam-free` → `glm-5.3-flash` → `beam-free` → `iceman-contributor-free` → `omniroute/nim-pool`），兩層各自獨立運作。

### 三個 Plugin（`profiles/mythos/plugins/`）

| Plugin | 功能 / Role |
|---|---|
| `mythos-tools` | `mythos_recall` 呼叫 `bin/recall`；每回合呼叫 `bin/genie-context` 注入上下文。 |
| `router-guard` | 前台只聊天、查記憶與派工；`delegate_task` 強制背景並補 `output_schema`；fail-closed（策略異常時 Router 擋、一般子代理放、hard 子代理照擋）。/ Frontend chats/recalls/dispatches only; forces background and injects `output_schema`; fail-closed. |
| `path-guard` | 誤操作防線：字串比對擋常見刪除／搬移／截斷，不是安全邊界。受保護清單放 profile 根目錄 `path-guard.json`（本機，不進 repo；格式見 `path-guard.example.json`），沒有設定就只擋清理工具。/ Mistake guard: string-matches common delete/move/truncate on protected paths; not a security boundary. The protected list lives in a local `path-guard.json` (see `path-guard.example.json`). |

### 記憶系統

- Provider：`claude-mem`（MCP server，寫入 `~/.claude/plugins/marketplaces/thedotmack/...`）
- Hermes 內建長期記憶：`memories/MEMORY.md`、`memories/USER.md`
- 對話紀錄：`state.db`（SQLite），`sessions.auto_prune: true`、`retention_days: 7`
- 注入節流：gateway plist 環境變數 `CLAUDE_MEM_HERMES_TURN_LIMIT=0`、`TURN_MAX=300`（11-12 起關掉 prefetch；`hermes gateway install` 重產 plist 會洗掉，`tests/test-claude-mem-local-patch.py` 會抓到）

### Hard 任務與觀測工具

- **Hard 判定**：本機分級器（`bin/triage`）只算最高一級，`hard_score_at=2.5`、`hard_needs_probability=0.3`；`/hard [任務]` 強制下一件走 hard（10 分鐘有效，只管一件）。
- **規劃人**：hard 子代理先跑 `bin/plan-hard`（唯讀、強模型、回合上限 6、預算 1 USD），印出計畫再由執行人照做。
- **觀測**：`bin/delegation-latency [--platform {all,subagent,telegram,cli}] [--since "YYYY-MM-DD HH:MM"]` 統計各腿 API 延遲（p50/p95）、429 次數、pool-skip 次數、fallback 啟動記錄。

## 外掛 / Plugins (`profiles/mythos/plugins/`)

| Plugin | 功能 / Role |
|---|---|
| `mythos-tools` | `mythos_recall` 呼叫 `bin/recall`；每回合呼叫 `bin/genie-context`。 |
| `router-guard` | 前台只聊天、查記憶與派工；`delegate_task` 強制背景並補 `output_schema`。/ Frontend chats/recalls/dispatches only; forces background and injects `output_schema`. |
| `path-guard` | 誤操作防線：字串比對擋常見刪除／搬移／截斷，不是安全邊界。受保護清單放 profile 根目錄 `path-guard.json`（本機，不進 repo；格式見 `path-guard.example.json`），沒有設定就只擋清理工具。/ Mistake guard: string-matches common delete/move/truncate on protected paths; not a security boundary. The protected list lives in a local `path-guard.json` (see `path-guard.example.json`). |

## 排程與輔助 / Services & Helpers

本機專屬的輔助腳本（提醒、監控、同步等 launchd 服務）不進 repo，放 `bin/` 由 `.gitignore` 排除。/ Machine-specific helper scripts (reminders, watchdogs, sync jobs) stay local in `bin/` and are git-ignored.

## 驗收與測試 / Verification & Tests

隔離 profile 停用 Telegram。/ Telegram disabled in isolated test profiles.

```bash
for t in tests/test-*.py profiles/mythos/plugins/*/test_*.py; do python3 "$t"; done
bash tests/test-plugin-bin-exec.sh
```

測試涵蓋：
- `tests/test-delegation-fallback.sh`：驗證 fallback 鏈在 429 時正確跳轉
- `tests/test-delegation-background.sh`：驗證 `delegate_task` 背景模式與 `output_schema`
- `tests/test-delegation-latency.sh`：驗證 `bin/delegation-latency` 統計正確
- `profiles/mythos/plugins/*/test_*.py`：三個 plugin 的單元測試
- `tests/test-claude-mem-local-patch.py`：偵測 plist 環境變數被洗掉

## License

MIT