# mythos-harness

[![test](https://github.com/royalskynet/mythos-harness/actions/workflows/test.yml/badge.svg)](https://github.com/royalskynet/mythos-harness/actions/workflows/test.yml)

用 Claude Code 實作 [DeepSeek Harness super-agent](https://x.com/DeepSeekHarness/article/2116857257245987236) 的**雙層架構**：
你跟 **Sonnet** 聊天（Router），它在對的時機叫 **Opus advisor** 想清楚，該動手的事寫成工單**派到背景 Worker**（免費模型層或 `deep-run`），做完由零 token 腳本把結果打回對話。

A Claude Code implementation of the two-layer (Router / Worker) super-agent pattern:
chat with Sonnet, let it consult an Opus advisor at decision points, and delegate real work to background workers.

```
你 ──Telegram──▶ Router：Sonnet（聊天、寫工單）──叫──▶ advisor：Opus（定方向／卡住／宣告完成前）
                    │  PreToolUse 派工閘：mid／hard 不准親手改檔
                    ├─ easy ─▶ 自己做
                    ├─ mid  ─▶ bin/dispatch ─▶ dcq（免費模型層）
                    └─ hard ─▶ bin/dispatch ─▶ deep-run（背景多步自主）
                                      ▲
        dispatch-watch（每 2 分、零 token）── PASS／FAIL／停滯／抽查 ──▶ 打回 Router 對話
                       └─ 抽查先過 review-judge（免費模型）：ON_TRACK 不打擾 Router
```

## 對照文章 / Mapping

| 文章模組 | 這裡的實作 |
|---|---|
| 兩層架構（Router 不執行） | `router/settings.json`：`model`＝Sonnet、`advisorModel`＝Opus；`bin/dispatch-gate.mjs` 用 PreToolUse 硬擋，不靠 prompt 自律（文章 7.1：只靠 prompt 叫自己派工，5 跑 0 次） |
| 何時叫 advisor | `router/ROUTER.md`：定方向、同錯兩次、宣告完成前 |
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

背景監看用 launchd（`launchd/` 兩份範本，路徑改成你的 clone 位置後放進 `~/Library/LaunchAgents/`）。

## 元件 / Components

| 檔案 | 作用 |
|---|---|
| `router/settings.json`、`ROUTER.md`、`start.sh` | Router 層：模型分層、派工閘 hook、Router 規則、tmux 啟動 |
| `bin/dispatch-gate.mjs` | 依 `triage` 判的 easy／mid／hard 決定能不能親手做；mid／hard 只放行唯讀 Bash 白名單 |
| `bin/dispatch`、`dispatch-retry`、`dispatch-cancel`、`dispatch-deep-run` | 派工、重派、取消、deep 背景執行 |
| `bin/dispatch-watch` | 回報＋停滯／抽查，pane 閒置才打進去 |
| `bin/review-judge`、`oc-free-ask`、`local-llm` | 免費模型判 Worker 有沒有跑歪；判不出來或格式不對一律 UNKNOWN＝照舊喚醒 Router |
| `bin/idle-reset` | 04／05／06 點試，pane 不忙且 30 分沒動才 `/clear`，一天一次 |

## 測試 / Tests

全部用假的 tmux／模型／triage／dcq，不連網、不需要金鑰；CI（macos-latest）每次 push 跑。

```bash
bash tests/test_router_template.sh     # Sonnet＋Opus advisor＋派工閘真的接起來
node --test tests/test_dispatch_gate.mjs   # 36 項，含 Codex 審計的 10 個繞過反例
bash tests/test-review-judge.sh && bash tests/test-dispatch-route.sh && bash tests/test_idle_reset.sh
bash tests/test_dispatch_deep.sh && bash tests/test_dispatch_watch.sh
```

## 限制 / Limits

- 派工閘是紀律閘不是沙箱：字串切段判斷，不是完整 shell 解析。要擋寫入用 OS 層沙箱（Claude Code sandbox／Seatbelt）。
- `oc-free-ask` 送出前會打本機 `:4102/scrub` 去識別，`local-llm` 走本機 `:4000` LiteLLM；沒有這兩個服務，review-judge 會判 UNKNOWN（照舊喚醒 Router），不影響派工。

## License

MIT
