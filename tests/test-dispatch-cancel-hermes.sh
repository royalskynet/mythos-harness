#!/usr/bin/env bash
# 11-08b dsh 差距 #2：取消／打斷。
# (a) --cancel：停整個行程樹（hermes 本體＋孫行程）、ledger 記 cancelled、信箱清掉；沒進行中的事也 exit 0
# (b) dispatch-watch 不 deliver cancelled 列（即使 rc=0 且 result 有內容）
# (c) --interrupt：舊列 cancelled、新增 pending 列，新 prompt 同時含原需求與新指示，新 hermes 呼叫的 body 也含兩者
# (d) --cancel／--interrupt 沒帶真 thread → exit 2
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-cancel-hermes.XXXXXX")"
cleanup() {
  for f in "$TMP"/gc-*.pid "$TMP"/mythos/state/bg/*.pid; do
    [ -f "$f" ] || continue
    p="$(tr -d '[:space:]' < "$f" 2>/dev/null || true)"
    [ -n "$p" ] && { pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; }
  done
  rm -rf "$TMP"
}
trap cleanup EXIT
export MYTHOS_DIR="$TMP/mythos" MYTHOS_WORKER_DIR="$TMP/worker" DCQ_HOME="$TMP/dcq"
export ROUTER_SLUG="dshgap-cancel-$$"
export DISPATCH_BG_HERMES_BIN="$TMP/hermes" CLAUDE_BIN="$TMP/claude" HERMES_LOG="$TMP/hermes.log" GC_DIR="$TMP"
export FAKE_AGENTS="$TMP/agents.json" FAKE_ID="$TMP/fake-id"
mkdir -p "$MYTHOS_DIR/state/bg" "$MYTHOS_WORKER_DIR" "$DCQ_HOME"
echo '[]' > "$FAKE_AGENTS"; echo cafe0004-0000-0000-0000-000000000000 > "$FAKE_ID"
printf '#!/bin/sh\n[ "${1:-}" = agents ] && { cat "$FAKE_AGENTS"; exit 0; }\nexit 0\n' > "$CLAUDE_BIN"
# 假 hermes：記 argv；起一個孫行程 sleep 300（記 pid）；自己也睡著（模擬長任務）
cat > "$DISPATCH_BG_HERMES_BIN" <<'STUB'
#!/bin/sh
printf 'CALL\t%s\n' "$*" >> "$HERMES_LOG"
sleep 300 &
echo $! >> "$GC_DIR/gc-$$.pid"
echo $$ > "$GC_DIR/hermes-$$.self"
wait
STUB
chmod +x "$CLAUDE_BIN" "$DISPATCH_BG_HERMES_BIN"
echo 'process.stdin.resume(); process.exit(0);' > "$TMP/tgsend.mjs"; export TG_SEND_BIN="$TMP/tgsend.mjs"
printf '#!/bin/sh\nexit 0\n' > "$TMP/tmux"; chmod +x "$TMP/tmux"; export TMUX_BIN="$TMP/tmux"
mkdir -p "$TMP/rt"; printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$TMP/rt/router.jsonl"
export MYTHOS_TRANSCRIPT_DIR="$TMP/rt" CLAUDE_PROJECTS_DIR="$TMP/projects" BG_AUTOHEAL=0 DISPATCH_BG_NO_TRIGGER=1
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"
fail() { echo "FAIL: $*" >&2; exit 1; }
TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
st_row() { awk -F'\t' -v i="$1" '$1==i {print $5}' "$TSV"; }
alive() { kill -0 "$1" 2>/dev/null; }

# (d) 沒帶 thread
rc=0; bash "$ROOT/bin/dispatch-bg" --cancel >/dev/null 2>&1 </dev/null || rc=$?
[ "$rc" = 2 ] || fail "(d) --cancel 沒 thread 應 exit 2，實際 $rc"
printf 'x\n' > "$TMP/n.md"
rc=0; bash "$ROOT/bin/dispatch-bg" --interrupt "$TMP/n.md" >/dev/null 2>&1 </dev/null || rc=$?
[ "$rc" = 2 ] || fail "(d) --interrupt 沒 thread 應 exit 2，實際 $rc"
echo '(d) ok'

# (e) 清理必須等待 ledger 鎖；cancel stub 的標記證明已到停 worker 之後。
. "$ROOT/bin/lib-ledger.sh"
mkdir -p "$MYTHOS_DIR/state/mailbox/t-lock" "$MYTHOS_DIR/state/hermes-queue" "$MYTHOS_DIR/state/followup"
printf 'queued\n' > "$MYTHOS_DIR/state/mailbox/t-lock/fu-old.md"
printf '7\n' > "$MYTHOS_DIR/state/followup/gen-t-lock"
printf 't-lock\tqueued\n' > "$MYTHOS_DIR/state/hermes-queue/lock-item"
printf 'bg-lock\tmid\t%s\t1\tpending\t-\tt-lock\thermes\n' "$TMP/n.md" > "$TSV"
printf '#!/bin/sh\ntouch "$MYTHOS_TEST_SANDBOX/cancel-entered"\n' > "$TMP/cancel-stub"
(
  ledger_lock || exit 1
  touch "$TMP/lock-held"
  for i in $(seq 1 100); do
    [ -f "$TMP/lock-release" ] && break
    sleep 0.1
  done
  ledger_unlock
) 9>&- &
lpid=$!
for i in $(seq 1 50); do [ -f "$TMP/lock-held" ] && break; sleep 0.1; done
[ -f "$TMP/lock-held" ] || fail '(e) 背景程序拿不到 ledger 鎖'
DISPATCH_CANCEL_BIN="$TMP/cancel-stub" bash "$ROOT/bin/dispatch-bg" --cancel t-lock 9>&- >"$TMP/lock.out" 2>"$TMP/lock.err" </dev/null &
cpid=$!
for i in $(seq 1 50); do [ -f "$TMP/cancel-entered" ] && break; sleep 0.1; done
sleep 0.6
violations=''
[ -f "$TMP/cancel-entered" ] || violations="$violations 未到 cancel helper"
[ "$(cat "$MYTHOS_DIR/state/followup/gen-t-lock")" = 7 ] || violations="$violations generation 在持鎖期間改變"
[ -f "$MYTHOS_DIR/state/mailbox/t-lock/fu-old.md" ] || violations="$violations 信箱在持鎖期間被刪"
[ -f "$MYTHOS_DIR/state/hermes-queue/lock-item" ] || violations="$violations 佇列在持鎖期間被刪"
touch "$TMP/lock-release"
wait "$lpid" || fail '(e) 持鎖程序失敗'
rc=0; wait "$cpid" || rc=$?
[ -z "$violations" ] || fail "(e)$violations"
[ "$rc" = 0 ] || fail "(e) 放鎖後取消失敗 rc=$rc：$(cat "$TMP/lock.err")"
[ "$(cat "$MYTHOS_DIR/state/followup/gen-t-lock")" = 8 ] || fail '(e) 放鎖後 generation 未增加'
[ ! -e "$MYTHOS_DIR/state/mailbox/t-lock" ] || fail '(e) 放鎖後信箱未刪'
[ ! -e "$MYTHOS_DIR/state/hermes-queue/lock-item" ] || fail '(e) 放鎖後佇列未刪'
: > "$TSV"
echo '(e) ok'

# (a) cancel
printf '把 ORIGINAL-REQ 做完\n' > "$TMP/p.md"
DISPATCH_BG_WORKER=hermes bash "$ROOT/bin/dispatch-bg" t-cx "$TMP/p.md" >"$TMP/id.out" 2>/dev/null </dev/null
id="$(cat "$TMP/id.out")"; sid="${id#bg-}"
hpid="$(tr -d '[:space:]' < "$MYTHOS_DIR/state/bg/$sid.pid")"
for i in $(seq 1 50); do ls "$TMP"/gc-*.pid >/dev/null 2>&1 && break; sleep 0.1; done
gpid="$(head -1 "$(ls "$TMP"/gc-*.pid | head -1)")"
alive "$hpid" || fail "(a) 起手 hermes 子殼沒活著"
alive "$gpid" || fail "(a) 起手孫行程沒活著"
[ "$(st_row "$id")" = pending ] || fail "(a) 起手應 pending：$(st_row "$id")"
mkdir -p "$MYTHOS_DIR/state/mailbox/t-cx"; echo 'queued' > "$MYTHOS_DIR/state/mailbox/t-cx/1.md"
out="$(bash "$ROOT/bin/dispatch-bg" --cancel t-cx 2>&1 </dev/null)" || fail "(a) --cancel 非零退出：$out"
case "$out" in *"已停"*) ;; *) fail "(a) --cancel 輸出沒有已停：$out" ;; esac
[ "$(st_row "$id")" = cancelled ] || fail "(a) ledger 應 cancelled：$(st_row "$id")"
sleep 1.5
alive "$hpid" && fail "(a) 子殼 pid $hpid 沒被殺"
alive "$gpid" && fail "(a) 孫行程 pid $gpid 沒被殺（只殺了 pid 檔那支）"
[ ! -e "$MYTHOS_DIR/state/mailbox/t-cx" ] || fail "(a) 信箱沒清"
out2="$(bash "$ROOT/bin/dispatch-bg" --cancel t-cx 2>&1 </dev/null)" || fail "(a) 沒進行中的事也該 exit 0：$out2"
case "$out2" in *"沒有進行中"*) ;; *) fail "(a) 沒進行中應說明：$out2" ;; esac
echo '(a) ok'

# (b) watch 不送 cancelled：補 rc=0＋有內容，跑 watch，不能有事件、不能呼叫 tg-send
rk="$(tr -d '[:space:]' < "$MYTHOS_DIR/state/bg/$sid.rkey")"
printf '摘要：不該被送出\n---細節---\ny\n' > "$MYTHOS_DIR/state/bg/r-$rk.result"
echo 0 > "$MYTHOS_DIR/state/bg/r-$rk.result.rc"
printf '#!/bin/sh\necho "$@" >> "%s/tg.calls"; cat >/dev/null\n' "$TMP" > "$TMP/tgsend.sh"; chmod +x "$TMP/tgsend.sh"
BG_PERM_MIN=100000 BG_STALL_MIN=100000 RESEND_SEC=100000 bash "$ROOT/bin/dispatch-watch" 9>&- >/dev/null 2>&1 || fail "(b) watch 非零退出"
ev="$MYTHOS_DIR/state/events.jsonl"
if [ -s "$ev" ] && grep -q "$id" "$ev"; then fail "(b) cancelled 列被 deliver：$(grep "$id" "$ev" | head -1 | cut -c1-200)"; fi
[ "$(st_row "$id")" = cancelled ] || fail "(b) watch 把 cancelled 改掉了：$(st_row "$id")"
if ls "$MYTHOS_DIR/state/inbox"* >/dev/null 2>&1 && grep -rq '不該被送出' "$MYTHOS_DIR/state/inbox"* 2>/dev/null; then fail "(b) 信箱出現 cancelled 結果"; fi
echo '(b) ok'

# (c) interrupt
: > "$HERMES_LOG"
rm -f "$TMP"/gc-*.pid "$TMP"/hermes-*.self
printf '把 ORIGINAL-REQ2 做完\n' > "$TMP/q.md"
DISPATCH_BG_WORKER=hermes bash "$ROOT/bin/dispatch-bg" t-ix "$TMP/q.md" >"$TMP/id2.out" 2>/dev/null </dev/null
id2="$(cat "$TMP/id2.out")"; sid2="${id2#bg-}"
hp2="$(tr -d '[:space:]' < "$MYTHOS_DIR/state/bg/$sid2.pid")"
for i in $(seq 1 50); do ls "$TMP"/gc-*.pid >/dev/null 2>&1 && break; sleep 0.1; done
gp2="$(head -1 "$(ls "$TMP"/gc-*.pid | head -1)")"
printf '改成 NEW-INSTRUCTION\n' > "$TMP/new.md"
DISPATCH_BG_WORKER=hermes bash "$ROOT/bin/dispatch-bg" --interrupt t-ix "$TMP/new.md" >"$TMP/id3.out" 2>"$TMP/id3.err" </dev/null || fail "(c) --interrupt 非零退出：$(cat "$TMP/id3.err")"
id3="$(tail -1 "$TMP/id3.out")"
[ -n "$id3" ] && [ "$id3" != "$id2" ] || fail "(c) 沒有新單：$(cat "$TMP/id3.out")"
[ "$(st_row "$id2")" = cancelled ] || fail "(c) 舊列應 cancelled：$(st_row "$id2")"
[ "$(st_row "$id3")" = pending ] || fail "(c) 新列應 pending：$(st_row "$id3")"
sleep 1
alive "$hp2" && fail "(c) 舊子殼沒被殺"
alive "$gp2" && fail "(c) 舊孫行程沒被殺"
np="$(awk -F'\t' -v i="$id3" '$1==i {print $3}' "$TSV")"
grep -q 'ORIGINAL-REQ2' "$np" && grep -q 'NEW-INSTRUCTION' "$np" || fail "(c) 新 prompt 沒同時含原需求與新指示：$(cat "$np")"
for i in $(seq 1 50); do grep -q 'NEW-INSTRUCTION' "$HERMES_LOG" && break; sleep 0.1; done
tail -n +1 "$HERMES_LOG" | grep -q 'ORIGINAL-REQ2' && grep -q 'NEW-INSTRUCTION' "$HERMES_LOG" || fail "(c) 新 hermes 呼叫 body 沒含兩者"
echo '(c) ok'
echo 'DISPATCH-CANCEL-HERMES PASS'
