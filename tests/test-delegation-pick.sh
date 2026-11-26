#!/usr/bin/env bash
# bin/delegation-pick：--selftest 內建樣本驗判定；再餵 mktemp 的 agent.log
# 驗三種結局（可翻回／維持 429／樣本不足）與 exit code（不讀 $HOME，乾淨環境可跑）。
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0

python3 bin/delegation-pick --selftest || fail=1

T=$(mktemp -d)
T2=$(mktemp -d)
T3=$(mktemp -d)
trap 'rm -rf "$T" "$T2" "$T3"' EXIT

gen() { # $1=檔案 $2=每腿 calls $3=paid latency $4=paid 429 數
  : > "$1"
  for ((i = 1; i <= $2; i++)); do
    echo "2026-11-26 11:00:0$i,000 INFO [s1] agent.conversation_loop: API call #$i: model=hy4-flash-free provider=opencode-go in=1 out=1 total=2 latency=4.0s id=f$i" >> "$1"
    echo "2026-11-26 11:01:0$i,000 INFO [s1] agent.conversation_loop: API call #$i: model=deepseek-v4.1-flash provider=opencode-go in=1 out=1 total=2 latency=$3s id=p$i" >> "$1"
  done
  for ((i = 1; i <= $4; i++)); do
    echo "2026-11-26 11:02:0$i,000 WARNING [s1] agent.conversation_loop: API call failed (attempt 1/1) error_type=RateLimitError thread=t provider=opencode-go base_url=https://x model=deepseek-v4.1-flash summary=HTTP 429: quota" >> "$1"
  done
}

# 品質腿乾淨且夠快 → 建議翻回，exit 0。
gen "$T/agent.log" 6 2.0 0
out="$(python3 bin/delegation-pick --logdir "$T" --platform all)" || fail=1
echo "$out" | grep -q '可翻回 deepseek-v4.1-flash' || { echo "FAIL: 快腿應建議翻回"; echo "$out"; fail=1; }

# 品質腿仍見 429 → 維持免費棒，exit 0。
gen "$T2/agent.log" 6 2.0 3
out="$(python3 bin/delegation-pick --logdir "$T2" --platform all)" || fail=1
echo "$out" | grep -qE '維持 hy4-flash-free.*429' || { echo "FAIL: 有 429 應維持"; echo "$out"; fail=1; }

# 兩腿樣本都不足 → exit 1。
gen "$T3/agent.log" 2 2.0 0
out="$(python3 bin/delegation-pick --logdir "$T3" --platform all)" && { echo "FAIL: 樣本不足應 exit 1"; echo "$out"; fail=1; } || true
echo "$out" | grep -q '樣本不足' || { echo "FAIL: 應印樣本不足"; echo "$out"; fail=1; }

[ "$fail" = 0 ] && echo "DELEGATION-PICK PASS"
exit "$fail"
