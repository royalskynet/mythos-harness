#!/usr/bin/env bash
# 回覆延遲量測（C2）驗收：假 transcript，延遲 5s／30s／120s 各一筆＋1 筆檔尾還在等。
# （第 4 則 user 之後沒有成功的 tool_result＝還在等，算 pending_tail；n=3 是已完成的 3 筆）
# 百分位取最近秩，只在完成的樣本上排（pending_tail 不進排序）：p50 = 第 ceil(0.5k) 名、p90 = 第 ceil(0.9k) 名
# （k=3 → 第 2、3 名＝30、120）。F6／F7：終點是 reply 的 tool_use 對到的成功 tool_result。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/latency-report-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
D="$TMP/projects"; mkdir -p "$D"
fail() { echo "FAIL: $*" >&2; exit 1; }

# 一行 user／一行 assistant；timestamp 用 ISO8601。基準取「現在 − 1 小時」：
# latency-report 只收 --days 內的行，寫死日期的話過幾天測試就自己壞掉
# 用 jq -c 產 JSON：手寫跳脫太容易錯
B=$(( $(date +%s) - 3600 ))
ts() { date -u -r $(( B + $1 )) +%Y-%m-%dT%H:%M:%SZ; }
CH='<channel source="telegram" chat_id="1">hi'
doc() { jq -cn --arg t "$1" --argjson c "$2" '{type:"user",timestamp:$t,message:{content:$c}}'; }
user() { doc "$(ts "$1")" "$(jq -cn --arg c "$CH" '$c')"; }
reply() { jq -cn --arg t "$(ts "$1")" --arg id "${2:-t}" '{type:"assistant",timestamp:$t,message:{content:[{type:"tool_use",id:$id,name:"mcp__telegram__reply",input:{}}]}}'; }
result() { jq -cn --arg t "$(ts "$1")" --arg id "${2:-t}" --argjson err "${3:-false}" \
  '{type:"user",timestamp:$t,message:{content:[{type:"tool_result",tool_use_id:$id,is_error:$err,content:"ok"}]}}'; }
other_tool() { jq -cn --arg t "$(ts "$1")" '{type:"assistant",timestamp:$t,message:{content:[{type:"tool_use",id:"t2",name:"Bash",input:{}}]}}'; }

{
  user 0;    other_tool 2; reply 5 t1;  result 5 t1      # 5s
  user 60;   reply 90 t2;   result 90 t2                 # 30s
  user 120;  reply 240 t3;  result 240 t3                # 120s
  user 300                                               # 檔尾還在等
} > "$D/session.jsonl"

out="$(MYTHOS_TRANSCRIPT_DIR="$D" bash "$ROOT/bin/latency-report" --days 7)"
[ "$out" = "$(printf '3\t30\t120\t120\t1\t0\t1')" ] || fail "TSV 不對：${out}（預期 n=3 p50=30 p90=120 max=120 over60=1 no_reply=0 pending_tail=1）"

j="$(MYTHOS_TRANSCRIPT_DIR="$D" bash "$ROOT/bin/latency-report" --json)"
[ "$j" = '{"n":3,"p50_s":30,"p90_s":120,"max_s":120,"over60":1,"no_reply":0,"pending_tail":1}' ] || fail "JSON 不對：${j}"

# F6／F7 口徑（獨立目錄，n 全為 0/1 才抓得到單筆錯放）：
#   a：連發兩則、一回覆 → 1 筆，起點取第一則（20s）
#   b：先失敗的 reply（is_error）再成功 → 取成功的時間（10s）；只有 tool_use 沒有 result → 還在等
#   c：檔中間一般訊息（非 Telegram）之後的 Telegram 訊息到成功回覆＝10s；與 a／b 交錯，不互相消帳
E="$TMP/edge"; mkdir -p "$E"
{ user 0; user 10; reply 20 t1; result 20 t1; } > "$E/a.jsonl"
{ user 0; reply 0 t1; result 5 t1 true; reply 10 t2; result 10 t2; user 100; reply 110 t3; } > "$E/b.jsonl"
{ user 0; reply 10 t1; result 10 t1; doc "$(ts 50)" '"what"';
  user 70; reply 80 t2; result 80 t2; } > "$E/c.jsonl"
j="$(MYTHOS_TRANSCRIPT_DIR="$E" bash "$ROOT/bin/latency-report" --json)"
[ "$j" = '{"n":4,"p50_s":10,"p90_s":20,"max_s":20,"over60":0,"no_reply":0,"pending_tail":1}' ] \
  || fail "F6／F7 口徑不對：${j}（預期 4 筆：10 20 10 10、pending_tail=1）"
# 只有 tool_use 沒 result 不消帳：b 的 t3 沒回結果，c 的 user 不該補它的帳（否則 b＋c 會被併成 1 筆 0s）

# 兩檔交錯不互相消帳：p 只有使用者訊息、q 只有成功的 reply（時間落在 p 的等待期間）→ p 算 pending_tail、n=0
X="$TMP/cross"; mkdir -p "$X"
{ user 0; } > "$X/p.jsonl"
{ reply 5 t1; result 5 t1; } > "$X/q.jsonl"
j="$(MYTHOS_TRANSCRIPT_DIR="$X" bash "$ROOT/bin/latency-report" --json)"
[ "$j" = '{"n":0,"p50_s":0,"p90_s":0,"max_s":0,"over60":0,"no_reply":0,"pending_tail":1}' ] \
  || fail "別檔的 reply 替這檔消帳了：${j}"

# F9：--days 缺值要 exit 2，不能無限迴圈
rc=0
timeout 5 bash "$ROOT/bin/latency-report" --days >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "--days 缺值應 exit 2，得到 $rc"

# --days 0 不合法
MYTHOS_TRANSCRIPT_DIR="$D" bash "$ROOT/bin/latency-report" --days 0 >/dev/null 2>&1 && fail '--days 0 沒被擋'

echo 'LATENCY-REPORT PASS'
