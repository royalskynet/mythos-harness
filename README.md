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

## 追問影子模式 / Follow-up shadow mode

`MYTHOS_FOLLOWUP_DIRECT` 支援 `off`（預設）、`observe`（背景影子觀察）與 `auto`（舊值 `1` 同義）。auto 已接 Hermes 的 async 入站 hook：在 allowlist 內帶 reply 的 Telegram 訊息，用 `chat_id + message_id` 在入站即定唯一擁有者，不綁 session。入列成功（`queued`／`dup`）即回 `skip`，Router 看不到這則訊息。其他結果以 `followup-direct --claim-router <chat> <message>` 在同一把 ledger 鎖下裁決：已入列回 `seen <thread>`、exit 0，仍歸 worker；否則寫 `routed` 收據、exit 1，交 Router，晚到入列以 exit 8 拒絕。入列上限 2 秒、claim 上限 1 秒，逾時會 kill 並回收子行程群組；claim 也失敗就交 Router，安全側最多重複、不漏訊息。停止請求（含 `/stop`）不直通，交 Router 取消。`--seen` 保留給 Telegram proxy 查詢已入列收據；Hermes 外掛不再於派工時查 session 對照。

建議先開 `observe`，看過 Decisions 再人工切 `auto`；本版不改任何 profile 設定。observe 立即回 `None`、永不 skip，不入列、不把原文寫入觀察檔。`bin/followup-report` 統計候選與接受數；`bin/followup-report --routed <tsv>` 比對 Router 的 thread 提案，TSV 每列為 `event_key<TAB>thread`，事件鍵為 `chat_id:message_id`。

repo 與唯讀旗標由派工工具寫入 `<prompt>.meta.json`（`repo`、`readonly`），續派沿用同 thread 前一張 job 的宣告。meta 存在即唯一權威，repo 空＝沒宣告，不讀正文標頭；只有無 meta 的舊檔才讀開頭 5 行 `repo=`／`readonly=1`。一般舊 prompt 的正式標頭先遷入 meta；interrupt 與信箱批次可繼承舊 job 標頭，新指示與信箱正文不會變成宣告。Hermes 佇列保留 prompt 路徑，沿用同一份 meta；正文中段的同名文字不影響排程。詳見 [DEVLOG.md](DEVLOG.md)。

`MYTHOS_FOLLOWUP_DIRECT` supports `off` (default), background shadow `observe`, and `auto` (legacy `1` is equivalent). Auto is wired into the async Hermes inbound hook. Allowlisted Telegram replies get one owner at ingress by `chat_id + message_id`, without session binding. A `queued` / `dup` receipt returns `skip`, hiding worker-owned input from the Router. Otherwise `followup-direct --claim-router <chat> <message>` arbitrates under the same ledger lock: queued input returns `seen <thread>` with exit 0 and stays with the worker; other input gets a `routed` receipt with exit 1 and goes to the Router. Late queueing is rejected with exit 8. Queueing is bounded to 2 seconds and claiming to 1 second; timeout kills and reaps the subprocess group. A failed claim falls through to the Router, allowing duplication rather than loss. Stop requests, including `/stop`, go to the Router for cancellation. `--seen` remains for the Telegram proxy; the Hermes plugin no longer checks session mappings when dispatching.

Start with `observe`, review Decisions, then switch manually to `auto`; this release changes no profile settings. Observe returns `None` immediately, never skips or queues, and omits the original text from observations. `bin/followup-report` reports candidates and acceptance counts; `bin/followup-report --routed <tsv>` compares Router thread proposals. Each row is `event_key<TAB>thread`, with `chat_id:message_id` as the event key.

The dispatch tool writes repo and read-only declarations to `<prompt>.meta.json` (`repo`, `readonly`); follow-ups inherit declarations from the previous job in the same thread. Existing metadata is the sole authority: an empty repo means undeclared and body headers are ignored. Only legacy files without metadata read the first 5 lines for `repo=` / `readonly=1`. Normal legacy prompts migrate formal headers into metadata; interrupts and mailbox batches can inherit legacy job headers without treating new instructions or mailbox bodies as declarations. The Hermes queue retains the prompt path and uses the same metadata. Matching text in the middle of the body does not affect scheduling. See [DEVLOG.md](DEVLOG.md).

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
