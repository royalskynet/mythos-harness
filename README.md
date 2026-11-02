# mythos-harness

[![test](https://github.com/royalskynet/mythos-harness/actions/workflows/test.yml/badge.svg)](https://github.com/royalskynet/mythos-harness/actions/workflows/test.yml)

讓一個 Claude Code 主 session（Telegram bot「Mythos」，跑在 tmux）只當 Router、不自己動手做事的周邊 harness。
架構對照 DeepSeek Harness 的 super-agent 文章（兩層 Router／Worker、事件驅動、Watchdog）。
這個目錄就是線上 bot 的工作目錄，`.gitignore` 是白名單，只追蹤下列檔案。

A harness that keeps a Claude Code "router" session (a Telegram bot running in tmux) from doing work itself:
a PreToolUse gate forces delegation, workers run out-of-process, and a free-model judge filters progress checks.

## 元件 / Components

| 檔案 | 作用 |
|---|---|
| `bin/dispatch-gate.mjs` | PreToolUse hook。依本輪難度（easy／mid／hard）決定能不能親手做；mid／hard 只放行唯讀 Bash 白名單（引號、命令替換、`&`、`-e"…"`、awk `system()` 都有處理） |
| `bin/dispatch` | 派工入口：easy／mid → `dcq`（只走免費模型層），hard → `deep-run` |
| `bin/dispatch-watch` | 派工回報＋停滯／抽查；抽查先交 `review-judge`，只有 OFF_TRACK／STUCK／判不出來才喚醒主 session |
| `bin/review-judge` | 免費模型判 worker 有沒有跑歪；輸出不合格式或模型失敗一律 UNKNOWN（fail-open＝照舊喚醒） |
| `bin/oc-free-ask` | 一問一答走 `opencode run`（CLI），送出前先過本機 PII scrub，scrub 不通就不送 |
| `bin/local-llm` | 走本機 LiteLLM（:4000，含 PII 閘道）的備援棒 |
| `bin/idle-reset` | launchd 04／05／06 點跑：pane 不忙、30 分沒動才送 `/clear`，一天一次；抓不到 pane 就不動 |
| `bin/dispatch-deep-run`、`dispatch-retry`、`dispatch-cancel` | deep 背景執行與重派／取消 |
| `launchd/ai.mythos.idle-reset.plist` | idle-reset 的排程 |

## 重現 / Reproduce

需求：macOS（測試用到 BSD `date -v`／`stat -f`）、bash、Node ≥ 20。測試全部用假的 tmux／模型／dcq，不連網、不需要任何金鑰。

```bash
git clone https://github.com/royalskynet/mythos-harness && cd mythos-harness
node --test tests/test_dispatch_gate.mjs     # 36 項，含 Codex 審計的 10 個繞過反例
bash tests/test-review-judge.sh              # REVIEW-JUDGE PASS
bash tests/test-dispatch-route.sh            # DISPATCH-ROUTE PASS
bash tests/test_idle_reset.sh                # IDLE-RESET PASS
bash tests/test_dispatch_deep.sh
bash tests/test_dispatch_watch.sh
```

CI（GitHub Actions，macos-latest）每次 push 跑同一組。

實際上線還要：`dcq`（派工佇列）、`deep-run`、`opencode` CLI、本機 :4000 LiteLLM 與 :4102 PII scrub、Laya triage（gate 判難度）。
這些是作者本機的元件，不在本 repo；路徑都可用環境變數覆蓋（`DCQ_BIN`、`DEEP_RUN_BIN`、`DISPATCH_GATE_TRIAGE`、`MYTHOS_DIR`、`LOCAL_LLM_URL`、`OC_FREE_ASK_SCRUB`）。

## 限制 / Limits

`dispatch-gate` 是派工紀律閘，不是沙箱：它用字串切段判斷，不是完整 shell 解析。要擋寫入請用作業系統層級的沙箱（如 Claude Code sandbox／Seatbelt）。

## License

MIT
