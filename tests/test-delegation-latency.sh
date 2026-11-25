#!/usr/bin/env bash
# bin/delegation-latency：--selftest 內建樣本驗解析；再餵一個 mktemp 的 agent.log
# 驗端到端輸出（不讀 $HOME，乾淨環境可跑）。
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0

python3 bin/delegation-latency --selftest || fail=1

T=$(mktemp -d)
T2=$(mktemp -d)
trap 'rm -rf "$T" "$T2"' EXIT
cat > "$T/agent.log" <<'LOG'
2026-11-25 00:00:01,000 INFO [s1] agent.conversation_loop: API call #1: model=beam-free provider=opencode-go in=10 out=5 total=15 latency=3.0s id=a
2026-11-25 00:00:02,000 WARNING [s1] agent.conversation_loop: API call failed (attempt 1/1) error_type=RateLimitError thread=t provider=opencode-go base_url=https://x model=beam-free summary=HTTP 429: quota
LOG
out="$(python3 bin/delegation-latency --logdir "$T")" || fail=1
echo "$out" | grep -q 'opencode-go/beam-free' || { echo "FAIL: 缺 leg 列"; echo "$out"; fail=1; }
echo "$out" | grep -qE 'opencode-go/beam-free[[:space:]]+1[[:space:]]+3\.0' || { echo "FAIL: calls/p50 不對"; echo "$out"; fail=1; }
echo "$out" | grep -qE '[[:space:]]1[[:space:]]+0$' || { echo "FAIL: 429 計數不對"; echo "$out"; fail=1; }

cat > "$T2/agent.log" <<'LOG'
2026-11-25 00:00:01,000 INFO [t1] agent.turn_context: conversation turn: session=s1 model=m provider=p platform=telegram history=0 msg=hi
2026-11-25 00:00:02,000 INFO [t1] agent.conversation_loop: API call #1: model=rt-x provider=opencode-go in=1 out=1 total=2 latency=1.0s id=a
2026-11-25 00:00:03,000 INFO [w1] agent.turn_context: conversation turn: session=s2 model=m provider=p platform=subagent history=0 msg=go
2026-11-25 00:00:04,000 INFO [w1] agent.conversation_loop: API call #1: model=sub-x provider=omniroute in=1 out=1 total=2 latency=2.0s id=b
LOG
out="$(python3 bin/delegation-latency --logdir "$T2" --platform subagent)" || fail=1
echo "$out" | grep -q 'filter: platform=subagent since=-' || { echo "FAIL: 缺 filter 行"; echo "$out"; fail=1; }
echo "$out" | grep -qE 'omniroute/sub-x[[:space:]]+1[[:space:]]+2\.0' || { echo "FAIL: subagent 腿缺或數字不對"; echo "$out"; fail=1; }
echo "$out" | grep -q 'rt-x' && { echo "FAIL: telegram 腿不該出現"; echo "$out"; fail=1; }

[ "$fail" = 0 ] && echo "DELEGATION-LATENCY PASS"
exit "$fail"
