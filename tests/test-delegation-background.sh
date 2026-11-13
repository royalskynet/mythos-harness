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
  # 11-13 Fail loud：派工與結果都不准沉默。聊天室不開 allow_silence；router-guard 把 [SILENT] 換成短句或結果摘要。
  if grep -q -E "^ +allow_silence: true" "$f"; then echo "FAIL: $f 開了 allow_silence，派工回合會沒聲音"; fail=1; fi
  grep -q 'register_hook("transform_llm_output"' "$(dirname "$f")/plugins/router-guard/__init__.py" \
    || { echo "FAIL: router-guard 沒註冊 transform_llm_output（[SILENT] 不會被攔）"; fail=1; }
  if grep -q -F '只回 `[SILENT]`' "$(dirname "$f")/SOUL.md"; then echo "FAIL: SOUL 還叫 Router 只回 [SILENT]"; fail=1; fi
  # 連發訊息預設 interrupt 會打斷前一則回合（那則沒回覆）；要排隊。
  grep -q -E "^  busy_input_mode: queue" "$f" || { echo "FAIL: $f 的 display.busy_input_mode 不是 queue"; fail=1; }
  # 被問進度時照 router-guard 注入的 [任務狀態] 答（做完的不說沒進展）。
  grep -q -F '[任務狀態]' "$(dirname "$f")/SOUL.md" || { echo "FAIL: SOUL 沒有 [任務狀態] 那條"; fail=1; }
done
[ "$n" -gt 0 ] || { echo "FAIL: 沒找到任何 profile 設定"; exit 1; }
[ "$fail" = 0 ] && echo "DELEGATION-BACKGROUND PASS ($n)"
exit "$fail"
