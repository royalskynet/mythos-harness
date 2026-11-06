#!/usr/bin/env bash
# bin/dispatch-watch 的 bg／bg-hard 段＋ bin/dispatch-cancel 的 bg（D2）驗收，全用假 claude／假 tmux／假 transcript。
#   watch：done＋有 result → 投遞一次且帶 event_id；缺檔 → 退讀 claude logs 並標「result 缺檔」；
#          working 超過 BG_STALL_MIN → STALL（旋鈕讀 knobs.env，預設 60）
#   cancel：claude stop 成功 → cancelled；stop 失敗 → exit 1、ledger 仍 pending
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-bg-watch.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export MYTHOS_DIR="$TMP/mythos"
export DCQ_HOME="$TMP/dcq"
export TMUX_BIN="$TMP/tmux"
export TMUX_LOG="$TMP/tmux.log"
export MYTHOS_TRANSCRIPT_DIR="$TMP/router-transcript"
export CLAUDE_PROJECTS_DIR="$TMP/projects"
export CLAUDE_BIN="$TMP/claude"
export FAKE_AGENTS="$TMP/agents.json"
export STOP_RC="$TMP/stop.rc"
export CLAUDE_LOG="$TMP/claude.log"
export BG_AUTOHEAL=0  # 本檔驗舊路徑（事件交 Router）；自癒另見 test-bg-autoheal.sh
# stub 只做自己那件事、不 cat 任何會讀 stdin 的東西：watch 的 while-read 迴圈會把還沒讀的行交給子行程
cat > "$CLAUDE_BIN" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$CLAUDE_LOG"
case "$1" in
  agents) tr -d '\n' < "$FAKE_AGENTS"; printf '\n' ;;
  logs) printf 'log tail for %s\nsecond line\n' "$2" ;;
  stop) printf 'stopped %s\n' "$2"; exit "$(cat "$STOP_RC" 2>/dev/null || echo 0)" ;;
esac
exit 0
STUB
chmod +x "$CLAUDE_BIN"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"  # F1：自己的 stub 設好之後才 source

cat > "$TMUX_BIN" <<'TMUX'
#!/bin/sh
printf '%s\n' "$*" >> "$TMUX_LOG"
case " $* " in
  " -L mythos send-keys -t mythos -l "*) esc="$(printf '%s' "$8" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$esc" >> "$MYTHOS_TRANSCRIPT_DIR/router.jsonl" ;;
esac
case " $* " in *" capture-pane "*) echo 'idle screen' ;; esac
exit 0
TMUX
chmod +x "$TMUX_BIN"

mkdir -p "$MYTHOS_DIR/state/bg" "$MYTHOS_TRANSCRIPT_DIR" "$CLAUDE_PROJECTS_DIR"
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$MYTHOS_TRANSCRIPT_DIR/router.jsonl"
TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
fail() { echo "FAIL: $*" >&2; exit 1; }
row() { # id backend epoch [status]
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" mid "$TMP/p.md" "$3" "${4:-pending}" "$TMP/worker" t-x "$2" >> "$TSV"
}
status_of() { awk -F "$(printf '\t')" -v i="$1" '$1==i {print $5; exit}' "$TSV"; }
agents() { # session 前綴 state…
  local out='[' sep='' p s
  while [ $# -gt 1 ]; do
    p="$1"; s="$2"; shift 2
    out="$out$sep{\"sessionId\":\"$p-1111-2222-3333-444455556666\",\"kind\":\"background\",\"state\":\"$s\"}"; sep=','
  done
  printf '%s]' "$out" > "$FAKE_AGENTS"
}
events() { [ -f "$MYTHOS_DIR/state/events.jsonl" ] && cat "$MYTHOS_DIR/state/events.jsonl"; }
: > "$TMUX_LOG"; : > "$CLAUDE_LOG"

# 1) done＋有 result → 投遞一次、帶 event_id
row bg-aaaa0001 bg "$(date +%s)"
printf '[t-x 結論] 做完了\n' > "$MYTHOS_DIR/state/bg/aaaa0001.result"
agents aaaa0001 done
bash "$ROOT/bin/dispatch-watch" 9>&- || fail '1：dispatch-watch 非零退出'
grep -q 'event_id=bg-aaaa0001-PASS' "$TMUX_LOG" || fail "1：沒投遞 PASS：$(cat "$TMUX_LOG")"
grep -q '做完了' "$TMUX_LOG" || fail "1：投遞內容不是 result：$(cat "$TMUX_LOG")"
[ "$(jq -s '[.[] | select(.job_id=="bg-aaaa0001" and .status=="PASS")] | length' "$MYTHOS_DIR/state/events.jsonl")" = 1 ] || fail '1：PASS 事件不是恰好一筆'
# 再跑一輪（未 ACK 已送達）不得重複建事件
bash "$ROOT/bin/dispatch-watch" 9>&-
[ "$(jq -s '[.[] | select(.job_id=="bg-aaaa0001")] | length' "$MYTHOS_DIR/state/events.jsonl")" = 1 ] || fail '1：同一票建了第二筆事件'
echo '(1) ok'

# 2) done 但缺 result → 退讀 claude logs 並標「result 缺檔」
row bg-bbbb0002 bg-hard "$(date +%s)"
agents aaaa0001 done bbbb0002 done
# 2a) 寬限內不發：result 可能只是晚幾十秒才寫（11-05 bg-6cd59e09 的假 PASS）
BG_RESULT_GRACE_SEC=600 bash "$ROOT/bin/dispatch-watch" 9>&- || fail '2a：非零退出'
grep -q 'bg-bbbb0002-PASS' "$TMUX_LOG" && fail '2a：寬限內就發了 PASS'
[ -f "$MYTHOS_DIR/state/bg/bbbb0002.done-seen" ] || fail '2a：沒記 done-seen'
# 2b) 寬限過了仍缺檔才發
printf '%s\n' "$(( $(date +%s) - 700 ))" > "$MYTHOS_DIR/state/bg/bbbb0002.done-seen"
BG_RESULT_GRACE_SEC=600 bash "$ROOT/bin/dispatch-watch" 9>&- || fail '2b：非零退出'
grep -q 'event_id=bg-bbbb0002-PASS' "$TMUX_LOG" || fail "2：沒投遞：$(cat "$TMUX_LOG")"
grep -q 'result 缺檔' "$TMUX_LOG" || fail "2：沒標 result 缺檔：$(cat "$TMUX_LOG")"
grep -q 'log tail for bbbb0002' "$TMUX_LOG" || fail "2：沒退讀 claude logs：$(cat "$TMUX_LOG")"
grep -q '^logs bbbb0002$' "$CLAUDE_LOG" || fail "2：沒呼叫 claude logs <短id>：$(cat "$CLAUDE_LOG")"
echo '(2) ok'

# 3) working 逾 BG_STALL_MIN → STALL；沒逾時不發
now="$(date +%s)"
row bg-cccc0003 bg $((now - 3700))                 # 舊（61 分）→ knobs 設 1 分鐘也算
row bg-dddd0004 bg "$now"                          # 剛開
agents aaaa0001 done bbbb0002 done cccc0003 working dddd0004 working
printf 'BG_STALL_MIN=30\n' > "$MYTHOS_DIR/state/watchdog-knobs.env"
: > "$TMUX_LOG"
bash "$ROOT/bin/dispatch-watch" 9>&- || fail '3：非零退出'
grep -q 'event_id=bg-cccc0003-STALL' "$TMUX_LOG" || fail "3：逾時沒發 STALL：$(cat "$TMUX_LOG")"
grep -q 'bg-dddd0004-STALL' "$TMUX_LOG" && fail '3：剛開的票也被判 STALL'
# 旋鈕：BG_STALL_MIN 進白名單（只讀出口）
out="$(env -u BG_STALL_MIN MYTHOS_DIR="$MYTHOS_DIR" DISPATCH_WATCH_PRINT_KNOBS=1 bash "$ROOT/bin/dispatch-watch")"
case "$out" in *'BG_STALL_MIN=30') ;; *) fail "3：BG_STALL_MIN 沒讀進白名單：$out" ;; esac
printf 'BG_STALL_MIN=abc\n' > "$MYTHOS_DIR/state/watchdog-knobs.env"
out="$(env -u BG_STALL_MIN MYTHOS_DIR="$MYTHOS_DIR" DISPATCH_WATCH_PRINT_KNOBS=1 bash "$ROOT/bin/dispatch-watch")"
case "$out" in *'BG_STALL_MIN=60') ;; *) fail "3：BG_STALL_MIN 預設不是 60：$out" ;; esac
echo '(3) ok'

# 4) cancel：claude stop 成功 → cancelled
echo 0 > "$STOP_RC"
bash "$ROOT/bin/dispatch-cancel" bg-dddd0004 2>"$TMP/e4" || fail "4：cancel 非零：$(cat "$TMP/e4")"
[ "$(status_of bg-dddd0004)" = cancelled ] || fail '4：ledger 沒標 cancelled'
grep -q '^stop dddd0004$' "$CLAUDE_LOG" || fail "4：沒呼叫 claude stop <短id>：$(cat "$CLAUDE_LOG")"
echo '(4) ok'

# 5) cancel：claude stop 失敗 → exit 1、ledger 不動、不撤銷事件
echo 1 > "$STOP_RC"
rc=0
bash "$ROOT/bin/dispatch-cancel" bg-cccc0003 2>"$TMP/e5" || rc=$?
[ "$rc" != 0 ] || fail '5：stop 失敗卻 exit 0'
[ "$(status_of bg-cccc0003)" = pending ] || fail '5：stop 失敗卻改了 ledger'
grep -q 'claude stop 失敗' "$TMP/e5" || fail "5：沒印失敗原因：$(cat "$TMP/e5")"
echo '(5) ok'

# 6) F4a：blocked 併入 STALL 分支（逾時才發、有 .last-stall 不重複）
now="$(date +%s)"
row bg-eeee0006 bg $((now - 3700))
agents aaaa0001 done bbbb0002 done cccc0003 done dddd0004 cancelled eeee0006 blocked
: > "$TMUX_LOG"
bash "$ROOT/bin/dispatch-watch" 9>&- || fail '6：非零退出'
grep -q 'event_id=bg-eeee0006-STALL' "$TMUX_LOG" || fail "6：blocked 逾時沒發 STALL：$(cat "$TMUX_LOG")"
[ -f "$MYTHOS_DIR/state/bg/eeee0006.last-stall" ] || fail '6：blocked 沒寫 .last-stall'
: > "$TMUX_LOG"
bash "$ROOT/bin/dispatch-watch" 9>&- || fail '6：第二輪非零退出'
grep -q 'bg-eeee0006-STALL' "$TMUX_LOG" && fail "6：blocked 同一票重複發 STALL：$(cat "$TMUX_LOG")"
echo '(6) ok'

# 7) F4b：stopped／failed 等 → FAIL 終態（不是永遠 pending），只發一次
for pair in ffff0007:stopped abab0008:failed; do
  row "bg-${pair%%:*}" bg-hard "$(date +%s)"
done
agents aaaa0001 done bbbb0002 done cccc0003 done dddd0004 cancelled eeee0006 blocked ffff0007 stopped abab0008 failed
: > "$TMUX_LOG"
bash "$ROOT/bin/dispatch-watch" 9>&- || fail '7：非零退出'
grep -q 'event_id=bg-ffff0007-FAIL' "$TMUX_LOG" || fail "7：stopped 沒發 FAIL：$(cat "$TMUX_LOG")"
grep -q 'event_id=bg-abab0008-FAIL' "$TMUX_LOG" || fail "7：failed 沒發 FAIL：$(cat "$TMUX_LOG")"
grep -q 'worker 已停止（stopped）' "$TMUX_LOG" || fail "7：guide 沒寫狀態：$(cat "$TMUX_LOG")"
grep -q 'log tail for ffff0007' "$TMUX_LOG" || fail "7：沒取 logs 摘要：$(cat "$TMUX_LOG")"
[ "$(jq -s '[.[] | select(.job_id=="bg-ffff0007" and .status=="FAIL")] | length' "$MYTHOS_DIR/state/events.jsonl")" = 1 ] || fail '7：FAIL 事件不是恰好一筆'
: > "$TMUX_LOG"
bash "$ROOT/bin/dispatch-watch" 9>&-
grep -q 'event_id=bg-ffff0007-FAIL' "$TMUX_LOG" && fail '7：FAIL 重複發'
echo '(7) ok'

# 8) 真進度（11-04）：agents 給 sessionId＋cwd 時看 transcript，不只看開派多久
#   a 舊票但 transcript 剛寫過 → 不判；b 舊票 transcript 停很久 → STALL（附幾分鐘沒動）
#   c 派出 6 分鐘還沒 transcript → STALL（沒開工）；d 派出 2 分鐘沒 transcript → 不判
export BG_PROJECTS_DIR="$TMP/bgproj"
W8="/tmp/w8.x"; P8="$BG_PROJECTS_DIR/-tmp-w8-x"; mkdir -p "$P8"
now="$(date +%s)"
row bg-a8a80001 bg $((now - 7200)); row bg-b8b80002 bg $((now - 7200))
row bg-c8c80003 bg $((now - 360));  row bg-d8d80004 bg $((now - 120))
: > "$P8/a8a80001-1111-2222-3333-444455556666.jsonl"
: > "$P8/b8b80002-1111-2222-3333-444455556666.jsonl"
touch -t "$(date -r $((now - 4000)) +%Y%m%d%H%M.%S)" "$P8/b8b80002-1111-2222-3333-444455556666.jsonl"
o='['; sep=''
for p in a8a80001 b8b80002 c8c80003 d8d80004; do
  o="$o$sep{\"sessionId\":\"$p-1111-2222-3333-444455556666\",\"cwd\":\"$W8\",\"kind\":\"background\",\"state\":\"working\"}"; sep=','
done
printf '%s]' "$o" > "$FAKE_AGENTS"
printf 'BG_STALL_MIN=60\n' > "$MYTHOS_DIR/state/watchdog-knobs.env"
: > "$TMUX_LOG"
bash "$ROOT/bin/dispatch-watch" 9>&- || fail '8：非零退出'
grep -q 'bg-a8a80001-STALL' "$TMUX_LOG" && fail "8a：transcript 還在動卻判 STALL：$(cat "$TMUX_LOG")"
grep -q 'event_id=bg-b8b80002-STALL' "$TMUX_LOG" || fail "8b：transcript 停了沒判 STALL：$(cat "$TMUX_LOG")"
grep -q '分鐘沒動' "$TMUX_LOG" || fail "8b：STALL 沒附停滯分鐘：$(cat "$TMUX_LOG")"
grep -q 'event_id=bg-c8c80003-STALL' "$TMUX_LOG" || fail "8c：沒開工沒判 STALL：$(cat "$TMUX_LOG")"
grep -q '沒開工' "$TMUX_LOG" || fail "8c：STALL 沒寫沒開工：$(cat "$TMUX_LOG")"
grep -q 'bg-d8d80004-STALL' "$TMUX_LOG" && fail "8d：剛派出就判沒開工：$(cat "$TMUX_LOG")"
echo '(8) ok'
# 9) 對帳不得把 bg 單當 dcq 單（11-06 bg-2157532a 誤判）：進行中、worker 在清單、超過 GONE_MIN → 不轉 FAIL
now="$(date +%s)"
row bg-99990009 bg $((now - 7200))
printf '[{"sessionId":"99990009-1111-2222-3333-444455556666","kind":"background","state":"working"}]' > "$FAKE_AGENTS"
printf 'BG_STALL_MIN=600\n' > "$MYTHOS_DIR/state/watchdog-knobs.env"
: > "$TMUX_LOG"
GONE_MIN=1 bash "$ROOT/bin/dispatch-watch" 9>&- || fail '9：非零退出'
jq -e 'select(.job_id=="bg-99990009")' "$MYTHOS_DIR/state/events.jsonl" >/dev/null 2>&1 && fail '9：進行中的 bg 單被建了事件（對帳誤判）'
echo '(9) ok'
echo 'DISPATCH-BG-WATCH PASS'
