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
- **記憶 / Memory**：`memory.provider: claude-mem`；線上 `plugins/claude-mem` symlink 到 `~/.hermes/plugins/claude-mem`。每輪注入由 gateway plist 的 `CLAUDE_MEM_HERMES_TURN_LIMIT=1`、`TURN_MAX=300` 壓低。/ Turn injection throttled by gateway plist env vars.
- **線上 profile / Live profile**：`~/.hermes/profiles/mythos`，保留本機設定。/ Local settings preserved.

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

## License

MIT
