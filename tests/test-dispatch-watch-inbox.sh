#!/usr/bin/env bash
# WO4c：bin/dispatch-watch 的 deliver() 在 Hermes 模式（state/deliver-mode=hermes）不碰 tmux，
#   待投遞事件改交假 tg-send（收件匣）→ 成功 ack；失敗 bump 下輪重試；沒設模式走原 tmux 路徑。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-watch-inbox.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export MYTHOS_DIR="$TMP/mythos"
export DCQ_HOME="$TMP/dcq"
export TMUX_BIN="$TMP/tmux"
export TMUX_LOG="$TMP/tmux.log"
export MYTHOS_TRANSCRIPT_DIR="$TMP/router-transcript"
export CLAUDE_PROJECTS_DIR="$TMP/projects"
export CLAUDE_BIN="$TMP/claude"
export FAKE_AGENTS="$TMP/agents.json"
export TG_SEND_BIN="$TMP/tg-send"
export TG_LOG="$TMP/tg.log"
export TG_STDIN="$TMP/tg.stdin"
export TG_RC="$TMP/tg.rc"
export BG_AUTOHEAL=0
cat > "$CLAUDE_BIN" <<'STUB'
#!/bin/sh
case "$1" in agents) cat "$FAKE_AGENTS" ;; logs) printf 'log tail\n' ;; esac
exit 0
STUB
chmod +x "$CLAUDE_BIN"
# dispatch-watch 用 node 跑 TG_SEND_BIN → 假 tg-send 也寫成 node（記參數、收 stdin、照 TG_RC 退出）
cat > "$TG_SEND_BIN" <<'JS'
const fs = require('fs')
fs.appendFileSync(process.env.TG_LOG, process.argv.slice(2).join(' ') + '\n')
let s = ''
process.stdin.on('data', d => s += d).on('end', () => {
  fs.appendFileSync(process.env.TG_STDIN, s)
  process.exit(Number((fs.existsSync(process.env.TG_RC) ? fs.readFileSync(process.env.TG_RC, 'utf8') : '0').trim() || 0))
})
JS
chmod +x "$TG_SEND_BIN"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"
cat > "$TMUX_BIN" <<'TMUX'
#!/bin/sh
printf '%s\n' "$*" >> "$TMUX_LOG"
case " $* " in *" capture-pane "*) echo 'idle screen' ;; esac
exit 0
TMUX
chmod +x "$TMUX_BIN"
_guard_var BRIEF_BIN

mkdir -p "$MYTHOS_DIR/state/bg" "$MYTHOS_DIR/logs" "$MYTHOS_TRANSCRIPT_DIR" "$CLAUDE_PROJECTS_DIR"
echo '[]' > "$FAKE_AGENTS"
TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
EV="$MYTHOS_DIR/state/events.jsonl"
fail() { echo "FAIL: $*" >&2; exit 1; }
reset() { : > "$TSV"; : > "$EV"; : > "$TMUX_LOG"; : > "$TG_LOG"; : > "$TG_STDIN"; echo 0 > "$TG_RC"; }
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" mid "$TMP/p.md" "$2" pending "$TMP/worker" t-x "$3" >> "$TSV"; }
# 一筆直送失敗的待投遞事件（acked_at 空、tries 0）
seed_event() {
  printf '%s\n' "{\"event_id\":\"$1-FAIL\",\"job_id\":\"$1\",\"task\":\"/x/t.md\",\"status\":\"FAIL\",\"summary\":\"t.md\",\"thread\":\"t-x\",\"extra\":\"worker 已停止（stopped）\",\"guide\":\"要重做用 bin/dispatch-retry $1\",\"created\":$(( $(date +%s) - 60 )),\"delivered_at\":null,\"acked_at\":null,\"tries\":0,\"direct\":\"failed\"}" > "$EV"
}
field() { jq -r --arg e "$1-FAIL" "select(.event_id==\$e) | .$2" "$EV"; }

# (a) hermes 模式：假 tg-send 一次、內容不含機讀欄位、事件已 ack、tmux 沒被呼叫
reset; row '100-1-task' 100 'bg'
printf 'hermes' > "$MYTHOS_DIR/state/deliver-mode"
seed_event '100-1-task'
bash "$ROOT/bin/dispatch-watch" 9>&- || fail "(a)：非零退出"
[ "$(grep -c '^--' "$TG_LOG" || true)" = 1 ] || fail "(a)：tg-send 呼叫次數不是 1：$(cat "$TG_LOG")"
for bad in event_id= thread=; do
  ! grep -q -- "$bad" "$TG_STDIN" || fail "(a)：stdin 含 $bad: $(cat "$TG_STDIN")"
done
grep -q 'FAIL' "$TG_STDIN" || fail "(a)：stdin 沒有狀態：$(cat "$TG_STDIN")"
grep -q 'worker 已停止' "$TG_STDIN" || fail "(a)：stdin 沒有 extra：$(cat "$TG_STDIN")"
[ "$(field '100-1-task' acked_at)" != null ] || fail '(a)：事件沒 ack'
! [ -s "$TMUX_LOG" ] || fail "(a)：hermes 模式碰了 tmux：$(cat "$TMUX_LOG")"

# (b) tg-send 失敗：不 ack、tries+1、下輪重試
reset; row '100-2-task' 100 'bg'
echo 1 > "$TG_RC"
seed_event '100-2-task'
bash "$ROOT/bin/dispatch-watch" 9>&- || fail "(b)：非零退出"
[ "$(field '100-2-task' acked_at)" = null ] || fail '(b)：失敗卻 ack 了'
[ "$(field '100-2-task' tries)" = 1 ] || fail "(b)：tries 沒 +1：$(field '100-2-task' tries)"
! grep -q 'event_id=' "$TG_STDIN" || fail '(b)：stdin 含 event_id='
! [ -s "$TMUX_LOG" ] || fail '(b)：hermes 模式碰了 tmux'
echo 0 > "$TG_RC"
jq -c 'del(.delivered_at)' "$EV" > "$EV.t" && mv "$EV.t" "$EV"  # 模擬 RESEND_SEC 已過（同一輪只送一次）
: > "$TG_LOG"; : > "$TG_STDIN"
bash "$ROOT/bin/dispatch-watch" 9>&- || fail "(b2)：非零退出：$(cat "$MYTHOS_DIR/logs/dispatch-watch.log")"
[ -s "$TG_LOG" ] || fail '(b2)：失敗後下輪沒重送'
[ "$(field '100-2-task' acked_at)" != null ] || fail '(b2)：重試成功後沒 ack'

# (c) 沒 deliver-mode → 原 tmux 路徑
reset; row '100-3-task' 100 'bg'
rm -f "$MYTHOS_DIR/state/deliver-mode"
seed_event '100-3-task'
bash "$ROOT/bin/dispatch-watch" 9>&- || fail "(c)：非零退出"
grep -q 'send-keys' "$TMUX_LOG" || fail "(c)：沒走 tmux：$(cat "$TMUX_LOG")"
grep -q 'event_id=100-3-task-FAIL' "$TMUX_LOG" || fail "(c)：tmux 訊息沒 event_id"
! [ -s "$TG_LOG" ] || fail "(c)：非 hermes 卻呼叫了 tg-send"

echo 'DISPATCH-WATCH-INBOX PASS'
