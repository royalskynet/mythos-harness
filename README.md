# mythos-harness

[![test](https://github.com/royalskynet/mythos-harness/actions/workflows/test.yml/badge.svg)](https://github.com/royalskynet/mythos-harness/actions/workflows/test.yml)

**一個超級 agent：秒回，同時派工。** 借鏡 [DeepSeek Harness 的 super-agent 概念](https://x.com/deepseekharness/status/2116857257245987236)，跑在 [Hermes](https://github.com/NousResearch/Hermes-Agent) 上的 Telegram 助手外殼。

**One super agent that replies instantly and dispatches the work.** Inspired by the [DeepSeek Harness super-agent idea](https://x.com/deepseekharness/status/2116857257245987236), built as a shell around [Hermes](https://github.com/NousResearch/Hermes-Agent) for a Telegram assistant.

## 目標 / Goal

你只跟一個 Mythos 說話。它永遠有空回你，因為它自己不動手：要做的事交給背景 worker，做完再用同一個口吻把結果講給你聽。對你來說沒有「派工」「工單」「別的 agent」，只有 Mythos。

You talk to one Mythos. It always has time to answer because it never does the work itself. Work goes to background workers, and the result comes back in the same voice. From your side there are no tickets, job ids or other agents, only Mythos.

## 跟 DSH super-agent 的對應 / Mapping to the DSH super agent

| DSH | Mythos |
|---|---|
| 前台 Router：只聊天、路由 | profile `mythos`：免費模型，只有三個工具 |
| 背景 Worker：真的做事 | profile `mythos-worker`：`hermes -z` 單次行程 |
| 控制迴圈：監看、重派、回報 | `bin/dispatch-watch`、`bin/watchdog` |

| DSH | Mythos |
|---|---|
| Front Router: chat and routing only | profile `mythos`: free model, three tools |
| Background Worker: does the work | profile `mythos-worker`: one-shot `hermes -z` |
| Control loop: watch, retry, report | `bin/dispatch-watch`, `bin/watchdog` |

## 架構 / Architecture

```
你 ──Telegram──▶ Hermes gateway，profile mythos（Router）
                   │  只有三個工具：mythos_dispatch、mythos_recall、mythos_full_text
                   ├─ 問以前的事 ─▶ mythos_recall（一輪最多一次）
                   └─ 要做事 ─▶ mythos_dispatch ─▶ bin/dispatch-bg（先判難度）
                                     └─▶ hermes -p mythos-worker -z（背景、獨立行程）
                                           模型鏈：deepseek-v4.1-flash → glm-5.3-flash → beam-free
                                           結果第一行：狀態：完成／已轉交／受阻／失敗
                                           └─▶ bin/dispatch-watch ─▶ 收件匣 ─▶ 同一段對話
                                                 受阻／失敗／空輸出 ─▶ bin/dispatch-retry 轉免費派工鏈
```

- **秒回**：Router 不跑指令、不讀檔。工具白名單由 Hermes 的 `platform_toolsets` 與 `router-guard` 外掛兩層擋。
- **追問、取消、改方向**：`mythos_dispatch` 的 `mode` 有 `queue`（預設）、`cancel`（停掉整個行程樹）、`interrupt`（停掉後帶原需求與新指示重做）。
- **併發**：同時最多 `MYTHOS_HERMES_SLOTS` 個 worker（預設 3），超出的依序排隊。
- **送達**：注入對話後確認真的落地，逾時直接發 Telegram。
- **口吻**：`bin/adhd-lint.mjs` 擋掉「派工、工單、代號」這類斷裂用語。

- **Instant replies**: the Router runs no commands and reads no files. Its tool allowlist is enforced twice, by Hermes `platform_toolsets` and by the `router-guard` plugin.
- **Follow-ups**: `mythos_dispatch` takes `mode` = `queue` (default), `cancel` (kills the whole process tree) or `interrupt` (kills it and redoes the request with the new instruction).
- **Concurrency**: at most `MYTHOS_HERMES_SLOTS` workers (default 3); the rest wait in FIFO order.
- **Status line**: a worker result starts with `狀態：完成|已轉交|受阻|失敗`. Blocked, failed or empty results are retried through the free-model dispatch chain.
- **Delivery**: injected results are checked against the conversation log and sent to Telegram directly if they never land.
- **Voice**: `bin/adhd-lint.mjs` rejects wording that exposes tickets, ids or hand-offs.

## 安裝 / Install

需求：macOS、bash、Python 3、Node ≥ 20、[Hermes](https://github.com/NousResearch/Hermes-Agent)。

```bash
git clone https://github.com/royalskynet/mythos-harness ~/bots/mythos && cd ~/bots/mythos
hermes profile install profiles/mythos
hermes profile install profiles/mythos-worker
# 在兩個 profile 的 .env 填 MYTHOS_TG_CHAT_ID 與 bot token
bin/hermes-contract          # 印 CONTRACT_OK 才算接好
hermes -p mythos gateway start
```

Requirements: macOS, bash, Python 3, Node ≥ 20 and Hermes. Install both profiles, put `MYTHOS_TG_CHAT_ID` and the bot token in each profile's `.env`, run `bin/hermes-contract` until it prints `CONTRACT_OK`, then start the gateway.

## 升級 Hermes / Upgrading Hermes

Mythos 不改 hermes-agent 原始碼，只靠 `profiles/` 的兩個 profile distribution、`bin/` 的外部腳本、`bin/hermes-contract` 契約檢查接上它。

- 改 SOUL 或外掛：改 `profiles/` → `hermes profile update <name> -y` → `bin/hermes-contract`。
- 升 Hermes：`bin/hermes-upgrade`。它先 pull 最新 Hermes，再 pull 兩個 profile，契約檢查通過才重啟 gateway；不過就 `bin/hermes-upgrade --rollback`。
- 契約檢查項從外掛原始碼抓（掛鉤名、`ctx` 方法），不手列。

Mythos never patches hermes-agent. Edit files under `profiles/`, then run `hermes profile update <name> -y` and `bin/hermes-contract`. To upgrade, run `bin/hermes-upgrade`: it pulls the latest Hermes, pulls both profiles, and restarts the gateway only when the contract passes. `bin/hermes-upgrade --rollback` returns to the previous commit.

## 測試 / Tests

全部用假的模型、Telegram 與 worker，不連網、不需要金鑰；CI 每次 push 跑。

All tests stub the models, Telegram and workers. They need no network or keys, and CI runs them on every push.

```bash
bash tests/test-hermes-contract.sh && bash tests/test-hermes-upgrade.sh
bash tests/test-hermes-report-status.sh && bash tests/test-hermes-slots.sh
bash tests/test-hermes-fail-to-of-watch.sh && bash tests/test-small-residuals.sh
bash tests/test_dispatch_watch.sh
```

## 歡迎貢獻 / Contributing

歡迎 issue 與 PR，特別是：

1. 其他聊天平台的前台（Discord、Slack、LINE）。
2. Linux 支援（目前用到 launchd 與 macOS sandbox）。
3. 秒回延遲與派工成功率的量測。

規則很少：

- 每個行為改動附一個會失敗的測試（拿掉實作要變紅）。
- 測試不連網、不打真 Telegram、不需要金鑰。
- 不提交路徑、帳號、chat id、token；`profiles/` 裡用 `${HOME}`、`${MYTHOS_TG_CHAT_ID}` 這類變數。

Issues and PRs are welcome, especially:

1. Front ends for other chat platforms (Discord, Slack, LINE).
2. Linux support (launchd and the macOS sandbox are used today).
3. Measurements of reply latency and dispatch success rate.

Ground rules:

- Every behavior change comes with a test that fails without it.
- Tests stay offline: no real Telegram, no keys.
- Never commit paths, accounts, chat ids or tokens. Use variables such as `${HOME}` and `${MYTHOS_TG_CHAT_ID}` in `profiles/`.

## 更多 / More

- [DEVLOG.md](DEVLOG.md)：開發紀錄。Development log.
- [LEGACY.md](LEGACY.md)：2026-11-08 前的 Claude Code TUI 版本。The earlier Claude Code TUI version.

## License

MIT
