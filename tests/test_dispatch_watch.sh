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

mkdir -p "$MYTHOS_DIR/state" "$DCQ_HOME"/{done,failed,running,pending}

cat > "$TMUX_BIN" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TMUX_LOG"
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

# done → PASS，送出並改 notified-PASS
id='100-1-done-task'
register "$id" mid '/tmp/a-task.md'
: > "$DCQ_HOME/done/$id.job"
: > "$TMUX_LOG"
FAKE_BUSY=0 bash "$ROOT/bin/dispatch-watch"
grep -q 'send-keys' "$TMUX_LOG" || fail 'done 沒送出訊息'
grep -q 'PASS' "$TMUX_LOG" || fail 'done 訊息沒有 PASS'
grep -q "$id" "$TMUX_LOG" || fail 'done 訊息沒有 job id'
[ "$(last_field)" = 'notified-PASS' ] || fail "done 狀態沒改成 notified-PASS：$(last_field)"

# pane 忙 → 不送、tsv 不變
id='100-2-busy-task'
register "$id" mid '/tmp/b-task.md'
: > "$DCQ_HOME/done/$id.job"
: > "$TMUX_LOG"
FAKE_BUSY=1 bash "$ROOT/bin/dispatch-watch"
if grep -q 'send-keys' "$TMUX_LOG"; then fail 'pane 忙仍送出訊息'; fi
[ "$(last_field)" = 'pending' ] || fail "pane 忙卻改了狀態：$(last_field)"

# failed → FAIL，送出並改 notified-FAIL
id='100-3-failed-task'
register "$id" hard '/tmp/c-task.md'
: > "$DCQ_HOME/failed/$id.job"
: > "$TMUX_LOG"
FAKE_BUSY=0 bash "$ROOT/bin/dispatch-watch"
grep -q 'FAIL' "$TMUX_LOG" || fail 'failed 訊息沒有 FAIL'
[ "$(last_field)" = 'notified-FAIL' ] || fail "failed 狀態沒改成 notified-FAIL：$(last_field)"

echo PASS
