#!/usr/bin/env bash
# Router 派工必須走背景：Hermes delegation.gateway_mode 預設 auto，Telegram 的 interim_assistant_messages
# 關掉時會改成同回合等待，Router 整回合卡到子代理做完、新訊息排隊（11-11：一回合 119 秒）。
# Router profile 要明寫 gateway_mode: background（mythos-worker 是單次執行人，不派工，不檢查）。
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0 n=0
for f in profiles/mythos/config.yaml; do
  n=$((n+1))
  mode="$(awk '/^delegation:/{d=1;next} /^[^ #]/{d=0} d && $1=="gateway_mode:"{print $2}' "$f")"
  if [ "$mode" != background ]; then echo "FAIL: $f delegation.gateway_mode 是 ${mode:-未設（auto）}，要 background"; fail=1; fi
  # 背景派工後 Router 當回合只回 [SILENT]，聊天室沒開 allow_silence 會被 Hermes 換成警告訊息。
  grep -q -E "^ +allow_silence: true" "$f" || { echo "FAIL: $f 的 telegram channel_overrides 沒開 allow_silence"; fail=1; }
done
[ "$n" -gt 0 ] || { echo "FAIL: 沒找到任何 profile 設定"; exit 1; }
[ "$fail" = 0 ] && echo "DELEGATION-BACKGROUND PASS ($n)"
exit "$fail"
