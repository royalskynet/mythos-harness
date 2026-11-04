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

# F8：挑得到 timeout／gtimeout 才跑 F9（跟 dispatch-watch 的挑法一樣：先 timeout 再 gtimeout）
if command -v timeout >/dev/null 2>&1; then TO=timeout
elif command -v gtimeout >/dev/null 2>&1; then TO=gtimeout
else fail '缺 timeout/gtimeout'; fi

# F9：--days 缺值要 exit 2，不能無限迴圈
rc=0
"$TO" -k 5 5 bash "$ROOT/bin/latency-report" --days >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "--days 缺值應 exit 2，得到 $rc"

# --days 0 不合法
MYTHOS_TRANSCRIPT_DIR="$D" bash "$ROOT/bin/latency-report" --days 0 >/dev/null 2>&1 && fail '--days 0 沒被擋'

# F6／F7 回合綁定與併筆門檻（LATENCY_MERGE_SEC＝300s）：
#   d：A@0、reply 甲@1、result 甲@2（A 結清）、沒有等待時發的 reply 乙@50、B@100、該 reply 的 result@105 → 不消帳（pending_tail=1）
#   e：A@0、reply 甲@1、result 甲@2、B@100、reply 乙@103、result 乙@105 → 兩筆 2 與 5
#   f：A@0 未回、B@1000（距最後一則 > 300s）→ 舊輪 no_reply、以 B 重起；result@1030 → n=1 latency=30、no_reply=1
#   g：A@0、B@200（< 300s）併筆 → result@230 → n=1 latency=230（起點取第一則）
#   h：--max-detail 只印一行摘要，含 merged=，不含 fixture 訊息文字
Q="$TMP/rules"; mkdir -p "$Q"
{ user 0; reply 1 t1; result 2 t1; reply 50 t0; user 100; result 105 t0; } > "$Q/d.jsonl"
{ user 0; reply 1 t1; result 2 t1; user 100; reply 103 t2; result 105 t2; } > "$Q/e.jsonl"
{ user 0; user 1000; reply 1025 t1; result 1030 t1; } > "$Q/f.jsonl"
{ user 0; user 200; reply 225 t1; result 230 t1; } > "$Q/g.jsonl"
json_of() { rm -rf "$Q/o"; mkdir -p "$Q/o"; cp "$Q/$1" "$Q/o/"; MYTHOS_TRANSCRIPT_DIR="$Q/o" bash "$ROOT/bin/latency-report" --json; }
j="$(json_of d.jsonl)"
[ "$j" = '{"n":1,"p50_s":2,"p90_s":2,"max_s":2,"over60":0,"no_reply":0,"pending_tail":1}' ] || fail "d 不對：${j}"
j="$(json_of e.jsonl)"
[ "$j" = '{"n":2,"p50_s":2,"p90_s":5,"max_s":5,"over60":0,"no_reply":0,"pending_tail":0}' ] || fail "e 不對：${j}"
j="$(json_of f.jsonl)"
[ "$j" = '{"n":1,"p50_s":30,"p90_s":30,"max_s":30,"over60":0,"no_reply":1,"pending_tail":0}' ] || fail "f 不對：${j}"
j="$(json_of g.jsonl)"
[ "$j" = '{"n":1,"p50_s":230,"p90_s":230,"max_s":230,"over60":1,"no_reply":0,"pending_tail":0}' ] || fail "g 不對：${j}"
det="$(MYTHOS_TRANSCRIPT_DIR="$Q" bash "$ROOT/bin/latency-report" --max-detail)"
[ "$(printf '%s\n' "$det" | wc -l | tr -d ' ')" = 1 ] || fail "h：--max-detail 不只一行：${det}"
case "$det" in max_s=*" start="*" merged="*" file="*) ;; *) fail "h：--max-detail 格式不對：${det}" ;; esac
printf '%s' "$det" | grep -q 'hi' && fail "h：--max-detail 印了訊息內文：${det}"
[ "$(MYTHOS_TRANSCRIPT_DIR="$Q" bash "$ROOT/bin/latency-report" --json | grep -c merged)" = 0 ] || fail 'h：--json 多了欄位'

# 壓縮重寫：整條鏈追加到檔尾，user 保留原 timestamp、tool_result 改成壓縮當下。
#   原份：A@0 → 33s、B@20000 → 12s；重寫份：user@0、reply t2@30（皆 < maxSeen−60s 跳過）、result t2@19990（在 60s 內不跳，但 t2 沒登記不結算）
#   拿掉 maxSeen 跳過時：重寫份 user@0 重起一輪、t2 結算 → n=3、max_s=19990，這段必 FAIL
R="$TMP/rewrite"; mkdir -p "$R"
{ user 0; reply 30 t1; result 33 t1; user 20000; reply 20010 t3; result 20012 t3;
  user 0; reply 30 t2; result 19990 t2; } > "$R/r.jsonl"
j="$(MYTHOS_TRANSCRIPT_DIR="$R" bash "$ROOT/bin/latency-report" --json)"
[ "$j" = '{"n":2,"p50_s":12,"p90_s":33,"max_s":33,"over60":0,"no_reply":0,"pending_tail":0}' ] || fail "壓縮重寫份被算進延遲：${j}"

echo 'LATENCY-REPORT PASS'
