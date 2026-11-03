#!/usr/bin/env bash
# P1 驗收（11-03）：事件 ACK 佇列、thread 續派、watchdog、統一 job schema＋共同鎖。
# 全部用暫存 MYTHOS_DIR／假 tmux／假 dcq／假 transcript，不碰真的 state、tmux、launchd、brief-lines。
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/p1-harness.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$TMP"' EXIT

export MYTHOS_DIR="$TMP/mythos"
export DCQ_HOME="$TMP/dcq"
export TMUX_BIN="$TMP/tmux"
export TMUX_LOG="$TMP/tmux.log"
export CLAUDE_PROJECTS_DIR="$TMP/claude-projects"
export DEEP_TASK_DIR="$TMP/deep-task"
export DEEP_RUN_BIN="$TMP/deep-run"
export MYTHOS_TRANSCRIPT_DIR="$TMP/router"
export MYTHOS_BRIEF_DIR="$TMP/brief"
export HOME="$TMP/home"
mkdir -p "$MYTHOS_DIR/state" "$DCQ_HOME"/{done,failed,running,pending} "$CLAUDE_PROJECTS_DIR" "$DEEP_TASK_DIR" "$MYTHOS_TRANSCRIPT_DIR" "$HOME"
: > "$TMUX_LOG"
: > "$TMP/all-sent.log"
: > "$TMP/dcq.log"
TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
EVENTS="$MYTHOS_DIR/state/events.jsonl"
TRANSCRIPT="$MYTHOS_TRANSCRIPT_DIR/router.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' > "$TRANSCRIPT"

fail() { echo "FAIL: $*" >&2; exit 1; }
now() { date +%s; }

cat > "$TMUX_BIN" <<TMUX
#!/bin/sh
printf '%s\n' "\$*" >> "$TMUX_LOG"
printf '%s\n' "\$*" >> "$TMP/all-sent.log"
case " $* " in
  *" capture-pane "*) if [ "${FAKE_BUSY:-0}" = 1 ]; then printf 'working... esc to interrupt\n'; else printf 'idle screen\n'; fi ;;
esac
exit 0
TMUX
chmod +x "$TMUX_BIN"

cat > "$DCQ_HOME/bin-dcq" <<DCQ
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP/dcq.log"
case "\$1" in
  add) echo "job-1" ;;
esac
exit 0
DCQ
chmod +x "$DCQ_HOME/bin-dcq"
export DCQ_BIN="$DCQ_HOME/bin-dcq"

cat > "$DEEP_RUN_BIN" <<'DEEP'
#!/bin/sh
exit 0
DEEP
chmod +x "$DEEP_RUN_BIN"

watch() { bash "$ROOT/bin/dispatch-watch"; }
status_of() { awk -F'\t' -v id="$1" '$1 == id { print $5 }' "$TSV"; }

# ---------- A：終態只寫事件，ACK 才改 notified ----------
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 'o-a1' mid '/tmp/a1-task.md' "$(now)" pending "$TMP" t-x dcq > "$TSV"
: > "$DCQ_HOME/done/o-a1.job"
: > "$TMUX_LOG"
FAKE_BUSY=0 watch
grep -q 'event_id=o-a1-PASS' "$TMUX_LOG" || fail "A：投遞訊息沒帶 event_id：$(cat "$TMUX_LOG")"
jq -e 'select(.event_id=="o-a1-PASS") | .tries == 1 and .delivered_at != null' "$EVENTS" >/dev/null || fail 'A：事件沒記 delivered_at／tries=1'
[ "$(status_of o-a1)" = pending ] || fail "A：送鍵就算 notified（$(status_of o-a1)）"

: > "$TMUX_LOG"
FAKE_BUSY=0 watch
grep -q 'send-keys' "$TMUX_LOG" && fail 'A：未 ACK 十分鐘內又重送'
[ "$(jq -s 'length' "$EVENTS")" = 1 ] || fail "A：同一終態建了多筆事件：$(jq -s 'length' "$EVENTS")"

printf '%s\n' '{"type":"user","message":{"role":"user","content":"[派工回報] event_id=o-a1-PASS 收到"}}' >> "$TRANSCRIPT"
watch
[ "$(status_of o-a1)" = notified-PASS ] || fail "A：ACK 後沒改 notified-PASS：$(status_of o-a1)"
jq -e 'select(.event_id=="o-a1-PASS") | .acked_at != null' "$EVENTS" >/dev/null || fail 'A：ACK 沒寫 acked_at'
[ "$(jq -s 'length' "$EVENTS")" = 1 ] || fail 'A：ACK 後事件筆數變了'

# 未 ACK 超時重送、tries 增加
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 'o-a2' mid '/tmp/a2-task.md' "$(now)" pending "$TMP" t-a2 dcq >> "$TSV"
: > "$DCQ_HOME/done/o-a2.job"
watch
old=$(( $(now) - 700 ))
# 直接寫回「10 分鐘前投遞過」（固定格式才有得比，不靠 jq 重排）
grep -v '"event_id":"o-a2-PASS"' "$EVENTS" > "$EVENTS.keep" || true
printf '%s\n' '{"event_id":"o-a2-PASS","job_id":"o-a2","task":"/tmp/a2-task.md","status":"PASS","summary":"a2-task.md","thread":"t-a2","extra":"","guide":"","created":'"$old"',"delivered_at":'"$old"',"acked_at":null,"tries":1}' >> "$EVENTS.keep"
mv "$EVENTS.keep" "$EVENTS"
: > "$TMUX_LOG"
watch
grep -q 'event_id=o-a2-PASS' "$TMUX_LOG" || fail 'A：超過 10 分鐘沒重送'
jq -e 'select(.event_id=="o-a2-PASS") | .tries == 2' "$EVENTS" >/dev/null || fail "A：重送後 tries 沒加：$(jq -c 'select(.event_id=="o-a2-PASS")' "$EVENTS")"
[ "$(jq -s 'length' "$EVENTS")" = 2 ] || fail 'A：重送建了重複事件'

# ---------- B：thread ----------
grep -q 'thread=t-x' "$TMP/all-sent.log" || fail 'B：回報文字沒帶 thread'

# ---------- D：O 取消、舊列 retry、並行寫 ledger ----------
bash "$ROOT/bin/dispatch-cancel" o-a2
grep -q '^cancel o-a2$' "$TMP/dcq.log" || fail "D：O 取消沒叫 dcq cancel：$(cat "$TMP/dcq.log")"
[ "$(status_of o-a2)" = cancelled ] || fail "D：O 取消後狀態不是 cancelled：$(status_of o-a2)"

printf '%s\t%s\t%s\t%s\t%s\n' 'o-old5' mid "$TMP/old5-task.md" "$(now)" pending >> "$TSV"
printf 'old5\n' > "$TMP/old5-task.md"
bash "$ROOT/bin/dispatch-retry" o-old5 "補一下" >/dev/null 2>&1 || fail 'D：舊 5 欄列 retry 崩了'
: > "$DCQ_HOME/bin-dcq.log" 2>/dev/null; true
[ "$(awk -F'\t' '$1=="job-1" && $7=="o-old5"' "$TSV" | wc -l | tr -d ' ')" = 1 ] || fail 'D：retry 沒派新票或沒沿用 thread'
n0="$(grep -c '^job-1	' "$TSV" || true)"
for i in 1 2 3 4 5 6 7 8; do bash "$ROOT/bin/dispatch" "$TMP/old5-task.md" "$TMP" mid >/dev/null 2>&1 & done
wait
[ "$(wc -l < "$TSV" | tr -d ' ')" -eq 12 ] || fail "D：並行寫 ledger 掉列：$(wc -l < "$TSV") 行（應 12）"
[ -z "$(awk -F'\t' '$1 != "o-old5" && NF != 8 { print NR }' "$TSV")" ] || fail "D：ledger 有不是 8 欄的列：$(awk -F'\t' 'NF != 8' "$TSV")"
[ ! -d "$MYTHOS_DIR/state/.ledger.lock" ] || fail 'D：ledger 鎖沒放掉'

# ---------- B：gate ----------
printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' > "$TRANSCRIPT"
gate() { printf '%s' "$1" | MYTHOS_DIR="$MYTHOS_DIR" MYTHOS_TRANSCRIPT_DIR="$MYTHOS_TRANSCRIPT_DIR" node "$ROOT/bin/dispatch-gate.mjs" pre; }
out="$(gate '{"tool_name":"SendMessage","tool_input":{"to":"a1","message":"x"},"transcript_path":"'"$TRANSCRIPT"'"}')"
[ -z "$out" ] || fail "B：主 session SendMessage 被擋：$out"
out="$(gate '{"tool_name":"TaskOutput","tool_input":{"task_id":"x"},"transcript_path":"'"$TRANSCRIPT"'"}')"
case "$out" in *'"deny"'*) ;; *) fail "B：TaskOutput 沒擋：$out" ;; esac

# ---------- C：watchdog ----------
WD_STATE="$MYTHOS_DIR/state/watchdog.json"
echo '{"alerted":{}}' > "$WD_STATE"
# 死 pid 舊鎖
LOCK="$MYTHOS_DIR/state/.dispatch-watch.lock"
mkdir -p "$LOCK"; printf '999999\n' > "$LOCK/pid"
touch -t "$(date -v-15M '+%Y%m%d%H%M')" "$LOCK"
: > "$TMUX_LOG"
bash "$ROOT/bin/watchdog"
[ ! -d "$LOCK" ] || fail 'C：死 pid 的舊鎖沒清'
[ ! -f "$TMP/brief/mythos-watchdog.tsv" ] || fail "C：正常情況寫了告警檔：$(cat "$TMP/brief/mythos-watchdog.tsv")"

# Router 未回：最後一則 channel 訊息 20 分鐘前、之後沒有 reply
stale="$(date -u -v-20M '+%Y-%m-%dT%H:%M:%SZ')"
printf '%s\n' '{"type":"user","isMeta":true,"origin":{"kind":"channel"},"timestamp":"'"$stale"'","message":{"role":"user","content":"hi"}}' > "$TRANSCRIPT"
bash "$ROOT/bin/watchdog"
[ -f "$TMP/brief/mythos-watchdog.tsv" ] || fail 'C：未回訊息沒寫告警'
[ "$(wc -l < "$TMP/brief/mythos-watchdog.tsv" | tr -d ' ')" = 1 ] || fail 'C：一則訊息寫了多行告警'
grep -q "$(printf '\t')Mythos watchdog：⚠ " "$TMP/brief/mythos-watchdog.tsv" || fail 'C：告警格式不對（日期 TAB 內容）'
bash "$ROOT/bin/watchdog"
[ "$(wc -l < "$TMP/brief/mythos-watchdog.tsv" | tr -d ' ')" = 1 ] || fail 'C：第二輪重複告警'

echo PASS
