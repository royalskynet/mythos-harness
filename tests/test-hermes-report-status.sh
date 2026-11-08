#!/usr/bin/env bash
# 11-08（G04）：hermes worker 最終回覆第一行固定「狀態：完成／已轉交／受阻／失敗」。dispatch-watch 判：
#   完成／已轉交 → PASS，狀態行不能給使用者看到（直發內容與事件 extra 都去掉）；
#   受阻／失敗 → 當 FAIL（先 dispatch-retry 轉派 of，這裡 stub 成失敗才出 FAIL 事件）；
#   沒有狀態行（舊 worker）→ 照舊 PASS，log 記 report-status-missing。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hermes-status.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export MYTHOS_DIR="$TMP/mythos"
export BRIEF_LINES_DIR="$TMP/brief"
export DCQ_HOME="$TMP/dcq"
export DCQ_BIN="$TMP/dcq-bin"
export TG_LOG="$TMP/tg.log"
export DISPATCH_RETRY_BIN="$TMP/retry"
export CLAUDE_PROJECTS_DIR="$TMP/projects"
export CLAUDE_BIN="$TMP/claude"   # 守門：dispatch-bg 轉派視同真 runner，要在沙箱內
export MYTHOS_TRANSCRIPT_DIR="$TMP/rt"
export BG_AUTOHEAL=0
mkdir -p "$MYTHOS_DIR/state/bg" "$MYTHOS_DIR/logs" "$DCQ_HOME/done" "$DCQ_HOME/failed" "$DCQ_HOME/running" "$DCQ_HOME/pending" \
  "$CLAUDE_PROJECTS_DIR" "$MYTHOS_TRANSCRIPT_DIR"
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$MYTHOS_TRANSCRIPT_DIR/router.jsonl"
printf '#!/bin/sh\nexit 0\n' > "$DCQ_BIN"; chmod +x "$DCQ_BIN"
printf '#!/bin/sh\nexit 0\n' > "$CLAUDE_BIN"; chmod +x "$CLAUDE_BIN"
# 假 dispatch-retry：記呼叫後 exit 1（＝轉派 of 失敗）→ dispatch-watch 要出 FAIL 事件
printf '#!/bin/sh\necho "retry $1" >> "%s/retry.log"\nexit 1\n' "$TMP" > "$DISPATCH_RETRY_BIN"
chmod +x "$DISPATCH_RETRY_BIN"
# 假 tg-send（node 程式）：把實際送出的文字（含 --thread／--job）記進 TG_LOG，這就是使用者會看到的內容
cat > "$TMP/tgsend.mjs" <<STUB
import fs from 'node:fs'
let s = ''
process.stdin.on('data', d => s += d).on('end', () => {
  fs.appendFileSync(process.env.TG_LOG, 'event_id=' + process.argv[process.argv.indexOf('--job') + 1] + '-PASS ' + process.argv.slice(2).join(' ') + '\n' + s + '\n')
})
STUB
export TG_SEND_BIN="$TMP/tgsend.mjs"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/tmux.log"\nexit 0\n' "$TMP" > "$TMP/tmux"; chmod +x "$TMP/tmux"; export TMUX_BIN="$TMP/tmux"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"

TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
EV="$MYTHOS_DIR/state/events.jsonl"
fail() { echo "FAIL: $*" >&2; exit 1; }
P="$MYTHOS_DIR/state/bg/t-demo.md"
printf 'thread=t-demo\n查一下 A 服務\n' > "$P"
n=0
row() { # 短id 結果內容
  n=$((n + 1))
  printf '%s\tmid\t%s\t%s\tpending\t%s\tt-demo\thermes\n' "bg-$1" "$P" "$(date +%s)" "$TMP/w" >> "$TSV"
  printf '%s\n' "$1" > "$MYTHOS_DIR/state/bg/$1.rkey"
  printf "%s" "$2" > "$MYTHOS_DIR/state/bg/r-$1.result"
  printf "0\n" > "$MYTHOS_DIR/state/bg/r-$1.result.rc"
}
watch() {
  DW_DEADLINE_ARMED=1 bash "$ROOT/bin/dispatch-watch" 9>&- >/dev/null 2>>"$TMP/dw.err" || fail 'dispatch-watch 非零退出'; }
ev() { jq -r --arg id "$1" --arg st "$2" 'select(.job_id==$id and .status==$st) | .extra' "$EV" 2>/dev/null | head -1; }
events_of() { jq -s --arg id "$1" '[.[] | select(.job_id==$id)] | length' "$EV" 2>/dev/null || echo 0; }

# 1) 狀態：完成 → PASS；直發內容不含狀態行；事件 extra 也不含
row aaaa0001 '狀態：完成
thread=t-demo
摘要：
A 服務有在跑
---細節---
rc=0
'
watch
[ "$(events_of bg-aaaa0001)" = 1 ] || fail "完成：應恰好一個 PASS 事件：$(cat "$EV" 2>/dev/null)"
grep -q 'event_id=bg-aaaa0001-PASS' "$TG_LOG" 2>/dev/null || fail "完成：沒投遞 PASS：$(cat "$TG_LOG" 2>/dev/null)；events=${EV}；log="
grep -q 'A 服務有在跑' "$TG_LOG" || fail "完成：摘要沒送到：$(cat "$TG_LOG")"
grep -q '狀態：' "$TG_LOG" && fail "完成：使用者看到了狀態行：$(cat "$TG_LOG")"
case "$(ev bg-aaaa0001 PASS)" in *狀態：*) fail '完成：事件 extra 帶了狀態行' ;; esac

# 2) 狀態：已轉交 → 同樣 PASS、同樣去掉狀態行
row bbbb0002 '狀態：已轉交
thread=t-demo
摘要：
已交給另一位接手的人
---細節---
id xyz
'
watch
grep -q 'event_id=bg-bbbb0002-PASS' "$TG_LOG" || fail "已轉交：沒投遞 PASS：$(cat "$TG_LOG")"
grep -q '已交給另一位接手的人' "$TG_LOG" || fail "已轉交：摘要沒送到：$(cat "$TG_LOG")"
grep -q '狀態：' "$TG_LOG" && fail "已轉交：使用者看到了狀態行：$(cat "$TG_LOG")"

# 3) 狀態：受阻 → FAIL（先轉派 of，失敗才出事件），extra 帶第二行起
row cccc0003 '狀態：受阻
需要她的帳號才查得下去
'
watch
grep -qx 'retry bg-cccc0003' "$TMP/retry.log" || fail "受阻：沒先轉派 of：$(cat "$TMP/retry.log" 2>/dev/null)"
[ "$(ev bg-cccc0003 FAIL)" = '需要她的帳號才查得下去' ] || fail "受阻：沒出 FAIL 或 extra 不對：$(ev bg-cccc0003 FAIL)"
grep -q 'bg-cccc0003-PASS' "$TG_LOG" && fail '受阻：不該有 PASS'

# 4) 狀態：失敗：原因（同一行接原因，前綴比）→ FAIL，extra 帶第二行起
row dddd0004 '狀態：失敗：缺帳號
服務重開不起來
'
watch
grep -qx 'retry bg-dddd0004' "$TMP/retry.log" || fail '失敗：沒先轉派 of'
[ "$(ev bg-dddd0004 FAIL)" = '服務重開不起來' ] || fail "失敗：沒出 FAIL 或 extra 不對：$(ev bg-dddd0004 FAIL)"

# 5) 沒有狀態行（舊 worker）→ 照舊 PASS，log 記 report-status-missing
row eeee0005 'thread=t-demo
摘要：
舊格式的結果
---細節---
x
'
watch
grep -q 'event_id=bg-eeee0005-PASS' "$TG_LOG" || fail "舊格式：沒投遞 PASS：$(cat "$TG_LOG")"
grep -q 'report-status-missing bg-eeee0005' "$MYTHOS_DIR/logs/dispatch-watch.log" || fail "舊格式：log 沒記 report-status-missing"
[ "$(events_of bg-eeee0005)" = 1 ] || fail '舊格式：事件數不對'

echo 'REPORT_STATUS_OK'
