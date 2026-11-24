#!/usr/bin/env bash
# worker SOUL 結果合約的強制檢查：
# 1) 不准引用已退役的 bin（e05512a 刪的舊派工鏈：dispatch/quick/opus-plan/adhd-lint/system-facts/dispatch-watch/local-llm）
# 2) 必須帶 delegate_task output_schema 的強制欄位（status 三選一＋evidence）
# 3) 線上 ~/.hermes/profiles/mythos-worker/SOUL.md 要跟 repo 正本一致（改了正本忘了同步會靜默用舊版）
# 用法：bash tests/test-worker-soul-contract.sh
set -u
cd "$(dirname "$0")/.."
SOUL="profiles/mythos-worker/SOUL.md"
LIVE="$HOME/.hermes/profiles/mythos-worker/SOUL.md"
fail=0

for dead in dispatch quick opus-plan adhd-lint system-facts dispatch-watch local-llm; do
  if grep -q "bin/$dead" "$SOUL"; then echo "FAIL: SOUL 引用已刪的 bin/$dead"; fail=1; fi
done
for req in 'done.{0,3}needs_human.{0,3}failed' 'evidence' 'output_schema'; do
  if ! grep -qE "$req" "$SOUL"; then echo "FAIL: SOUL 缺 output_schema 合約要素：$req"; fail=1; fi
done
if [ -f "$LIVE" ] && ! cmp -s "$SOUL" "$LIVE"; then echo "FAIL: 線上 $LIVE 與 repo 正本不一致"; fail=1; fi

[ "$fail" = 0 ] && echo "WORKER-SOUL-CONTRACT PASS"
exit "$fail"
