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

# F2：壓縮重寫改按身分去重（不靠時間單調）。
#   (a) Codex 短鏈：同一則 user（同 timestamp、同內容）、同一個 reply id，重寫份的 result 灌到 11713 → 重寫份整則跳過，n=1、max_s=2
#       突變：拿掉 seenUser → 重寫份 user@0 重起一輪、檔尾還在等 → pending_tail=1
#   (b) 正常晚到列（實際 transcript 有 73s 倒退）：user@200、reply@205、倒退到 130 的 assistant 雜訊（非 reply）、
#       跑在前面的雜訊@283、再晚到的 result@210（比 283 倒退 73s）→ 照樣結算 10s
#       突變：加回 maxSeen 60s 跳過 → result@210 < 283−60 被跳過 → n=0（只有倒退的雜訊抓不到這個突變：跳掉雜訊不影響結算）
R="$TMP/rewrite"; mkdir -p "$R"
{ user 0; reply 1 t1; result 2 t1;
  user 0; reply 1 t1; result 11713 t1; } > "$R/a.jsonl"
j="$(MYTHOS_TRANSCRIPT_DIR="$R" bash "$ROOT/bin/latency-report" --json)"
[ "$j" = '{"n":1,"p50_s":2,"p90_s":2,"max_s":2,"over60":0,"no_reply":0,"pending_tail":0}' ] || fail "F2(a) 重寫份被算進延遲：${j}"
BS="$TMP/backstep"; mkdir -p "$BS"
{ user 200; reply 205 t1; other_tool 130; other_tool 283; result 210 t1; } > "$BS/b.jsonl"
j="$(MYTHOS_TRANSCRIPT_DIR="$BS" bash "$ROOT/bin/latency-report" --json)"
[ "$j" = '{"n":1,"p50_s":10,"p90_s":10,"max_s":10,"over60":0,"no_reply":0,"pending_tail":0}' ] || fail "F2(b) 晚到列讓結算漏了：${j}"

# F5：跨回合（start !== w.start）——A@0 reply 甲@1、B@1000 才回甲的結果 → 甲屬舊輪，不結算：
#     舊輪算沒回、B 還在等 → n=0 no_reply=1 pending_tail=1
XW="$TMP/xround"; mkdir -p "$XW"
{ user 0; reply 1 a; user 1000; result 1005 a; } > "$XW/x.jsonl"
j="$(MYTHOS_TRANSCRIPT_DIR="$XW" bash "$ROOT/bin/latency-report" --json)"
[ "$j" = '{"n":0,"p50_s":0,"p90_s":0,"max_s":0,"over60":0,"no_reply":1,"pending_tail":1}' ] || fail "F5 跨回合消帳：${j}"

# F6：併筆邊界——恰好 LATENCY_MERGE_SEC（300s）仍併筆；> 才另起一輪（g 是 200s 併筆，bv 是 301s 不併）
BV="$TMP/boundary"; mkdir -p "$BV"
{ user 0; user 300; reply 310 t; result 312 t; } > "$BV/eq.jsonl"
j="$(MYTHOS_TRANSCRIPT_DIR="$BV" bash "$ROOT/bin/latency-report" --json)"
[ "$j" = '{"n":1,"p50_s":312,"p90_s":312,"max_s":312,"over60":1,"no_reply":0,"pending_tail":0}' ] || fail "F6 邊界 300s 沒併筆：${j}"
rm -f "$BV/eq.jsonl"
{ user 0; user 301; reply 310 t; result 312 t; } > "$BV/gt.jsonl"
j="$(MYTHOS_TRANSCRIPT_DIR="$BV" bash "$ROOT/bin/latency-report" --json)"
[ "$j" = '{"n":1,"p50_s":11,"p90_s":11,"max_s":11,"over60":0,"no_reply":1,"pending_tail":0}' ] || fail "F6 邊界 301s 仍併筆：${j}"

# F6：--max-detail 對 g 精確比對整行
# g 的起點＝fixture 基準 B＋0 秒（g 第一則 user）；latency-scan 用 toISOString 印，帶 .000 毫秒
g0="$(ts 0 | sed 's/Z$/.000Z/')"
[ "$(MYTHOS_TRANSCRIPT_DIR="$Q" bash "$ROOT/bin/latency-report" --max-detail)" = "max_s=230 start=$g0 merged=1 file=g.jsonl" ] \
  || fail "F6 --max-detail 不對：$(MYTHOS_TRANSCRIPT_DIR="$Q" bash "$ROOT/bin/latency-report" --max-detail)"


# E1：seenUser 鍵＝channel 標籤的 chat_id＋message_id（兩個都有才用），沒有才退回 timestamp＋內容
TAG() { printf '<channel source="telegram" chat_id="%s"%s>hi' "$1" "${2:+ message_id=\"$2\"}"; }
ch() { jq -cn --arg t "$1" --arg c "$2" '{type:"user",timestamp:$t,message:{content:$c}}'; }
# (1) 同 chat、同 message_id、timestamp 不同的重播（回完之後、超出 300s 合併窗）→ 跳過；舊鍵含 timestamp，會另開一輪 pending_tail=1
M="$TMP/mid"; mkdir -p "$M"
{ ch "$(ts 0)" "$(TAG 1 111)"; reply 40 t1; result 40 t1; ch "$(ts 400)" "$(TAG 1 111)"; } > "$M/a.jsonl"
j="$(MYTHOS_TRANSCRIPT_DIR="$M" bash "$ROOT/bin/latency-report" --json)"
[ "$j" = '{"n":1,"p50_s":40,"p90_s":40,"max_s":40,"over60":0,"no_reply":0,"pending_tail":0}' ] || fail "E1(1) 同 message_id 的重播沒去重：${j}"
# (2) 不同 message_id、同毫秒同內容 → n=2
rm -f "$M/a.jsonl"
{ ch "$(ts 0)" "$(TAG 1 111)"; reply 10 t1; result 10 t1; ch "$(ts 100)" "$(TAG 1 222)"; reply 110 t2; result 110 t2; } > "$M/b.jsonl"
j="$(MYTHOS_TRANSCRIPT_DIR="$M" bash "$ROOT/bin/latency-report" --json)"
[ "$j" = '{"n":2,"p50_s":10,"p90_s":10,"max_s":10,"over60":0,"no_reply":0,"pending_tail":0}' ] || fail "E1(2) 不同 message_id 被併掉：${j}"
# (3) 不同 chat、同 message_id → n=2
rm -f "$M/b.jsonl"
{ ch "$(ts 0)" "$(TAG 1 111)"; reply 10 t1; result 10 t1; ch "$(ts 100)" "$(TAG 2 111)"; reply 110 t2; result 110 t2; } > "$M/c.jsonl"
j="$(MYTHOS_TRANSCRIPT_DIR="$M" bash "$ROOT/bin/latency-report" --json)"
[ "$j" = '{"n":2,"p50_s":10,"p90_s":10,"max_s":10,"over60":0,"no_reply":0,"pending_tail":0}' ] || fail "E1(3) 不同 chat 同 message_id 被併掉：${j}"
# 沒有 message_id 的舊格式：同 timestamp 同內容的重播仍按舊鍵去重（n=1）
rm -f "$M/c.jsonl"
{ ch "$(ts 0)" "$(TAG 1)"; ch "$(ts 0)" "$(TAG 1)"; reply 10 t1; result 10 t1; } > "$M/d.jsonl"
j="$(MYTHOS_TRANSCRIPT_DIR="$M" bash "$ROOT/bin/latency-report" --json)"
[ "$j" = '{"n":1,"p50_s":10,"p90_s":10,"max_s":10,"over60":0,"no_reply":0,"pending_tail":0}' ] || fail "E1 無 message_id 的舊鍵去重壞了：${j}"

# E1：seenUse 交錯——user@0 → reply a → user@1000（>300s，上一輪算沒回）→ 重播 user@0／reply a → result a@1005
# 重播的 user 會被 seenUser 擋掉，但 reply a 若再登記，會把 result 記到新一輪 → 多一筆 5s。
# 期望：n=0 no_reply=1 pending_tail=1。突變：刪 seenUse 必 FAIL。
IW="$TMP/interleave"; mkdir -p "$IW"
{ user 0; reply 1 a; user 1000; reply 1 a; result 1005 a; } > "$IW/x.jsonl"
j="$(MYTHOS_TRANSCRIPT_DIR="$IW" bash "$ROOT/bin/latency-report" --json)"
[ "$j" = '{"n":0,"p50_s":0,"p90_s":0,"max_s":0,"over60":0,"no_reply":1,"pending_tail":1}' ] || fail "E1 seenUse 交錯消帳：${j}"

# E1 --stages：固定 fixture，精確比對整段輸出（kind、毫秒 epoch、秒數；不印內文）。
# 慢樣本 121s（起點 0）、60s（起點 5000，61s 算慢）；快樣本 10s（起點 1000）。
# 配對：慢 121s 離快 10s 最近 → 先印它；慢 60s 的半徑內（±600s）沒有沒被配走的快樣本 → 不硬配、只印 slow。
# 順序：slow 依起點，配到的 fast 緊接其後。
ST="$TMP/stages"; mkdir -p "$ST"
{ user 0; other_tool 2; reply 120 t1; result 121 t1
  user 1000; other_tool 1001; reply 1010 t2; result 1010 t2
  user 5000; reply 5061 t3; result 5061 t3; } > "$ST/s.jsonl"
ms() { echo $(( (B + $1) * 1000 )); }
want="$(printf 'slow\t%s\t%s\t%s\t%s\t121\nfast\t%s\t%s\t%s\t%s\t10\nslow\t%s\t%s\t%s\t%s\t61' \
  "$(ms 0)" "$(ms 2)" "$(ms 121)" "$(ms 121)" \
  "$(ms 1000)" "$(ms 1001)" "$(ms 1010)" "$(ms 1010)" \
  "$(ms 5000)" "$(ms 5061)" "$(ms 5061)" "$(ms 5061)")"
got="$(MYTHOS_TRANSCRIPT_DIR="$ST" bash "$ROOT/bin/latency-report" --stages)"
[ "$got" = "$want" ] || fail "E1 --stages 輸出不對：
--- got
${got}
--- want
${want}"
printf '%s' "$got" | grep -q 'hi' && fail 'E1 --stages 印了訊息內文'
# --stages 與 --json 一樣不吃掉一般輸出：不加旗標時 TSV 照舊
[ "$(MYTHOS_TRANSCRIPT_DIR="$ST" bash "$ROOT/bin/latency-report" --json)" = '{"n":3,"p50_s":61,"p90_s":121,"max_s":121,"over60":2,"no_reply":0,"pending_tail":0}' ] \
  || fail "E1 fixture 的 --json 不對：$(MYTHOS_TRANSCRIPT_DIR="$ST" bash "$ROOT/bin/latency-report" --json)"


