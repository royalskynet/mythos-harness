#!/usr/bin/env bash
# Why: 派工結果要靠零 token 腳本喚醒 Mythos；pane 忙時不能硬打，狀態也不能提早改。
# 全部用暫存 MYTHOS_DIR／DCQ_HOME／假 TMUX_BIN，不碰真的 state、~/.dcq、tmux。
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-watch-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export MYTHOS_DIR="$TMP/mythos"
export DCQ_HOME="$TMP/dcq"
export TMUX_BIN="$TMP/tmux"
export TMUX_LOG="$TMP/tmux.log"
# A（11-03）：送進 tmux 不算數，主 session transcript 出現 event_id=… 的 user 紀錄才 ACK。
# 假 tmux 模擬 Router 收到：send-keys -l 的文字追加一筆 user 紀錄進暫存 transcript。
export MYTHOS_TRANSCRIPT_DIR="$TMP/router-transcript"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"  # F1：自己的 stub 設好之後才 source；沒設的 runner／tmux 換 guard stub

mkdir -p "$MYTHOS_DIR/state" "$DCQ_HOME"/{done,failed,running,pending} "$MYTHOS_TRANSCRIPT_DIR"

cat > "$TMUX_BIN" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TMUX_LOG"
case " $* " in
  " -L mythos send-keys -t mythos -l "*)esc="$(printf '%s' "$8" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$esc" >> "$MYTHOS_TRANSCRIPT_DIR/router.jsonl" ;;
esac
case " $* " in
  *" capture-pane "*)
    if [ "${FAKE_BUSY:-0}" = 1 ]; then
      printf 'working... esc to interrupt\n'
    else
      printf 'idle screen\n'
    fi
    ;;
esac
exit 0
EOF
chmod +x "$TMUX_BIN"

TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
fail() { echo "FAIL: $*" >&2; exit 1; }

register() { # id tier task [status]
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(date +%s)" "${4:-pending}" > "$TSV"
}

last_field() { cut -f5 "$TSV"; }

# done → PASS：第一輪只送出、狀態仍 pending（未 ACK）；第二輪掃到 ACK 才改 notified-PASS
id='100-1-done-task'
register "$id" mid '/tmp/a-task.md'
: > "$DCQ_HOME/done/$id.job"
: > "$TMUX_LOG"
FAKE_BUSY=0 bash "$ROOT/bin/dispatch-watch"
grep -q 'send-keys' "$TMUX_LOG" || fail 'done 沒送出訊息'
grep -q 'PASS' "$TMUX_LOG" || fail 'done 訊息沒有 PASS'
grep -q "$id" "$TMUX_LOG" || fail 'done 訊息沒有 job id'
grep -q "event_id=$id-PASS" "$TMUX_LOG" || fail 'done 訊息沒有 event_id'
[ "$(last_field)" = 'pending' ] || fail "送出但未 ACK 就改了狀態：$(last_field)"
FAKE_BUSY=0 bash "$ROOT/bin/dispatch-watch"
[ "$(last_field)" = 'notified-PASS' ] || fail "ACK 後狀態沒改成 notified-PASS：$(last_field)"

# pane 忙 → 不送、tsv 不變
id='100-2-busy-task'
register "$id" mid '/tmp/b-task.md'
: > "$DCQ_HOME/done/$id.job"
: > "$TMUX_LOG"
FAKE_BUSY=1 bash "$ROOT/bin/dispatch-watch"
if grep -q 'send-keys' "$TMUX_LOG"; then fail 'pane 忙仍送出訊息'; fi
[ "$(last_field)" = 'pending' ] || fail "pane 忙卻改了狀態：$(last_field)"

# failed → FAIL：同樣送兩輪（送達 → ACK → notified-FAIL）
id='100-3-failed-task'
register "$id" hard '/tmp/c-task.md'
: > "$DCQ_HOME/failed/$id.job"
: > "$TMUX_LOG"
FAKE_BUSY=0 bash "$ROOT/bin/dispatch-watch"
grep -q 'FAIL' "$TMUX_LOG" || fail 'failed 訊息沒有 FAIL'
grep -q "event_id=$id-FAIL" "$TMUX_LOG" || fail 'failed 訊息沒有 event_id'
[ "$(last_field)" = 'pending' ] || fail "拒絕送出但未 ACK 就改了狀態：$(last_field)"
FAKE_BUSY=0 bash "$ROOT/bin/dispatch-watch"
[ "$(last_field)" = 'notified-FAIL' ] || fail "ACK 後狀態沒改成 notified-FAIL：$(last_field)"

echo PASS
