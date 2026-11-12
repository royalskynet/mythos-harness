#!/usr/bin/env bash
# state.db（Hermes 對話紀錄庫）預設不清，會一直長（11-11：4 天 18MB，七成是子代理的工具輸出）。
# Router profile 要開 sessions.auto_prune、保留期不超過 30 天，並保留內建記憶＋claude-mem 當長期記憶。
set -euo pipefail
cd "$(dirname "$0")/.."
f=profiles/mythos/config.yaml; fail=0
val() { awk -v sec="$1" -v key="$2:" '$0 ~ "^"sec":"{d=1;next} /^[^ #]/{d=0} d && $1==key{print $2}' "$f"; }
[ "$(val sessions auto_prune)" = true ] || { echo "FAIL: sessions.auto_prune 不是 true"; fail=1; }
days="$(val sessions retention_days)"
{ [ -n "$days" ] && [ "$days" -ge 1 ] && [ "$days" -le 30 ]; } || { echo "FAIL: sessions.retention_days=${days:-未設}，要 1–30"; fail=1; }
[ "$(val sessions vacuum_after_prune)" = true ] || { echo "FAIL: sessions.vacuum_after_prune 不是 true"; fail=1; }
[ "$(val memory memory_enabled)" = true ] || { echo "FAIL: memory.memory_enabled 不是 true"; fail=1; }
[ "$(val memory provider)" = claude-mem ] || { echo "FAIL: memory.provider 不是 claude-mem"; fail=1; }
# 省 token（11-12 實測 Router 每次呼叫 8 萬、子代理跑滿 40 輪到 6 萬）：壓縮要有絕對門檻，回流給 Router 的結果要有上限。
num() { v="$(val "$1" "$2")"; { [ -n "$v" ] && [ "$v" -ge "$3" ] && [ "$v" -le "$4" ]; } || { echo "FAIL: $1.$2=${v:-未設}，要 $3–$4"; fail=1; }; }
# 下限 40000：壓完還剩約 24000～25000，門檻貼著這個底會連續壓縮（11-12 實測 9 分鐘 5 次）。
num compression threshold_tokens 40000 64000
num compression proactive_prune_tokens 4000 32000
num delegation max_summary_chars 1000 6000
num delegation compression_threshold_tokens 16000 48000
[ "$fail" = 0 ] && echo "SESSION-RETENTION PASS"
exit "$fail"
