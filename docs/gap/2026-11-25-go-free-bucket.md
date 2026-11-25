# 429 毒池分帳粒度（go-free 分桶結論）

來源：`~/.hermes/hermes-agent/`（線上 gateway 行程 sys.path 指向的 checkout，11-25 讀）。

## 結論

429 標記**按憑證（credential entry）分帳，不按 model、不按 base_url**：
一張 key 429 → 同一 pool 裡共用該 key 的 entry 全標 `exhausted` →
該 provider 名下所有 model 的 fallback 候選全被跳過。

細節：

- Pool 以 provider 名分桶：`load_pool(provider)`（agent/credential_pool.py:2977）
  讀 `auth.json` 的 `credential_pool[provider]`；pool key 由
  `resolve_runtime_pool_key(provider, base_url)`（agent/credential_pool.py:685）決定，
  一般 provider 用正規化的 provider 名，custom provider 用 `providers.<slug>`／
  `custom:<name>`——**base_url 只用來對邊界（同名不同 endpoint 不借池），不是分帳軸**。
- 標記寫在 credential entry：`mark_exhausted_and_rotate`（agent/credential_pool.py:2255）
  對失敗 entry 做 `_mark_exhausted` → `last_status=exhausted`（agent/credential_pool.py:1209），
  並把**同 `runtime_api_key` 的兄弟 entry 一併標**（agent/credential_pool.py:2284-2297，
  log「credential pool: marking api-key-1 exhausted (status=429), rotating」:2313）。
- Fallback 檢查：`_candidate_pool_exhausted`（agent/chat_completion_helpers.py:1925）
  `load_pool(fb_provider)` 後 `has_available(model=fb_model)`（:1936）——
  entry 是 credential 級 exhausted 時任何 model 都不可用 → 印
  「Fallback skip: P/M credential pool is exhausted」（:1955）。
- **唯一的 model 粒度例外**：`_is_model_scoped_failure`
  （agent/credential_pool_model_cooldowns.py:76）只對三種情況把冷卻記在
  (credential, model) pair 上（`_cool_down_model` :92）：
  1. `provider == "anthropic"` 的一般 429（Anthropic 限流按 model 計）；
  2. `model_entitlement`（Codex plan 不含該 model，bench 一年）；
  3. `usage_window`（用量窗口，同 key 其他 model 仍可用）。
  opencode-go 等其他 provider 的 429 一律走 credential 級 exhausted。

## 對 go-free 鏈的含義

opencode-go 池只有一把 key → 任一 model（例 deepseek-v4.1-flash）429，
`beam-free`／`hy4-flash-free`／`iceman-contributor-free` 等兄弟腿同死
（11-25 00:58 實測三腿全「credential pool is exhausted」被 skip，只剩 omniroute 活）。
要分帳只有兩條路：拆 provider（不同 provider 名／custom_providers 不同 name 才分池），
或同一 provider 掛多把 key（多 entry 輪替）。同 provider 同 key 換 model 名沒用。

本輪只寫結論，不改設定。
