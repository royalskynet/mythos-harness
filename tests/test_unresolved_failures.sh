#!/usr/bin/env bash
# Why: 失敗單要有「收尾」才算完（11-06，baw 登出調研的 deep 補派單失敗後帳本停在 pending、使用者從轉述才知道）。
# 驗：未收尾 FAIL 會被標出（UNRESOLVED 事件）；收尾後不再標；帳本 pending 但單已死會自動對帳。
# 全部用暫存 MYTHOS_DIR／DCQ_HOME／假 TMUX_BIN，不碰真的 state、tmux、Telegram。
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/unresolved-test.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$TMP"' EXIT

export MYTHOS_DIR="$TMP/mythos"
export DCQ_HOME="$TMP/dcq"
export TMUX_BIN="$TMP/tmux"
export TMUX_LOG="$TMP/tmux.log"
export MYTHOS_TRANSCRIPT_DIR="$TMP/router-transcript"
export BRIEF_LINES_DIR="$TMP/brief"
export TG_SEND_BIN="$TMP/tg-stub"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"

mkdir -p "$MYTHOS_DIR/state/deep" "$DCQ_HOME"/{done,failed,running,pending} "$MYTHOS_TRANSCRIPT_DIR"
cat > "$TMUX_BIN" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$TMUX_LOG"
case " $* " in
  " -L mythos send-keys -t mythos -l "*)esc="$(printf '%s' "$8" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$esc" >> "$MYTHOS_TRANSCRIPT_DIR/router.jsonl" ;;
  *" capture-pane "*) printf 'idle screen\n' ;;
esac
exit 0
STUB
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$TG_SEND_BIN"
chmod +x "$TMUX_BIN" "$TG_SEND_BIN"

TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
fail() { echo "FAIL: $*" >&2; exit 1; }
watch() { : > "$TMUX_LOG"; bash "$ROOT/bin/dispatch-watch"; }
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "${6:-/tmp}" "${7:--}" "${8:-dcq}"; }
now="$(date +%s)"

# 1) 未收尾 FAIL：UNRESOLVED_HOURS=0 → 同輪就被標出來，帶 event_id
id='900-1-fail-task'
row "$id" mid /tmp/a.md "$now" pending > "$TSV"
: > "$DCQ_HOME/failed/$id.job"
UNRESOLVED_HOURS=0 watch
grep -q "event_id=$id-UNRESOLVED" "$TMUX_LOG" || fail '未收尾 FAIL 沒被標出（沒有 UNRESOLVED 事件）'

# 2) 預設 6 小時：剛失敗的單不會被標（負向對照）
id='900-2-fresh-fail'
row "$id" mid /tmp/b.md "$now" pending > "$TSV"
: > "$DCQ_HOME/failed/$id.job"
watch
grep -q "event_id=$id-FAIL" "$TMUX_LOG" || fail '新 FAIL 沒送出'
if grep -q "$id-UNRESOLVED" "$TMUX_LOG"; then fail '剛失敗的單不該被標未收尾'; fi

# 3) 收尾後檢查消失：dispatch-close --quiet 之後再跑，不再有 UNRESOLVED，帳本改 superseded，closeouts 有記錄
id='900-1-fail-task'
row "$id" mid /tmp/a.md "$now" pending > "$TSV"
bash "$ROOT/bin/dispatch-close" --quiet "$id" superseded "測試作廢" >/dev/null
[ "$(cut -f5 "$TSV")" = superseded ] || fail "superseded 沒寫進帳本：$(cut -f5 "$TSV")"
cut -f1,3 "$MYTHOS_DIR/state/closeouts.tsv" | grep -q "^$id.superseded$" || fail 'closeouts 沒記錄'
UNRESOLVED_HOURS=0 watch
if grep -q "$id-UNRESOLVED" "$TMUX_LOG"; then fail '收尾後仍被標未收尾'; fi

# 4) 同 thread 後面有別張單（重派）＝舊票視為收尾
: > "$MYTHOS_DIR/state/events.jsonl"
{ row 900-4-old mid /tmp/c.md $((now - 100)) pending /tmp th-retry dcq
  row 900-4-new mid /tmp/c-r1.md "$now" pending /tmp th-retry dcq; } > "$TSV"
: > "$DCQ_HOME/failed/900-4-old.job"; : > "$DCQ_HOME/running/900-4-new.job"
UNRESOLVED_HOURS=0 watch
if grep -q "900-4-old-UNRESOLVED" "$TMUX_LOG"; then fail '已重派的舊票不該被標未收尾'; fi

# 5) 對帳：dcq 單不在任何佇列 → FAIL
: > "$MYTHOS_DIR/state/events.jsonl"
row 900-5-vanished mid /tmp/d.md $((now - 3600)) pending > "$TSV"
watch
grep -q "event_id=900-5-vanished-FAIL" "$TMUX_LOG" || fail 'dcq 單消失沒對帳成 FAIL'

# 6) 對帳：deep runner pid 已不在、沒 rc → 補 rc=137
: > "$MYTHOS_DIR/state/events.jsonl"
dead="$(sh -c 'echo $$')"
did='deep-900-6-dead'
row "$did" hard /tmp/e.md $((now - 3600)) pending /tmp - deep > "$TSV"
printf '%s\n' "$dead" > "$MYTHOS_DIR/state/deep/$did.pid"; printf 'pid=%s\n' "$dead" > "$MYTHOS_DIR/state/deep/$did.handle"
touch -t 202001010000 "$MYTHOS_DIR/state/deep/$did.pid"
DEEP_HANDOFF_SEC=99999 watch
DEEP_HANDOFF_SEC=99999 watch  # 補 rc 那輪不出事件，下一輪才出
[ "$(tr -d '[:space:]' < "$MYTHOS_DIR/state/deep/$did.rc")" = 137 ] || fail 'runner 死掉沒補 rc=137'
grep -q "event_id=$did-FAIL" "$TMUX_LOG" || fail 'runner 死掉沒出 FAIL 事件'

# 7) 直投 dcq 的失敗單（帳本沒有列）：被認養進帳本→標出→收尾後消失；使用者取消的不認養
: > "$MYTHOS_DIR/state/events.jsonl"; : > "$TSV"; rm -f "$DCQ_HOME"/failed/*
oid='1-2-direct-orphan'
printf 'TASK=/tmp/o.md\nCWD=/tmp\nLAST_RC=2\n' > "$DCQ_HOME/failed/$oid.job"
printf 'TASK=/tmp/c.md\nCWD=/tmp\nCANCELLED=1\n' > "$DCQ_HOME/failed/1-3-cancelled.job"
UNRESOLVED_HOURS=0 watch
cut -f1 "$TSV" | grep -qxF "$oid" || fail '直投失敗單沒被認養進帳本'
if cut -f1 "$TSV" | grep -qxF 1-3-cancelled; then fail '使用者取消的單不該認養'; fi
UNRESOLVED_HOURS=0 watch
jq -e --arg j "$oid" 'select(.job_id==$j and .status=="UNRESOLVED")' "$MYTHOS_DIR/state/events.jsonl" >/dev/null || fail '直投失敗單沒被標未收尾'
bash "$ROOT/bin/dispatch-close" --quiet "$oid" superseded "測試作廢" >/dev/null
n0="$(grep -c "\"job_id\":\"$oid\".*UNRESOLVED" "$MYTHOS_DIR/state/events.jsonl")"
UNRESOLVED_HOURS=0 watch
[ "$(grep -c "\"job_id\":\"$oid\".*UNRESOLVED" "$MYTHOS_DIR/state/events.jsonl")" = "$n0" ] || fail '直投失敗單收尾後仍被標'
n0=''; : "$n0"
[ "$(grep -cxF "$oid" <(cut -f1 "$TSV"))" = 1 ] || fail '同一張被重複認養'

# 8) 不帶 --quiet 推給使用者的那則不帶 job id／thread 代號（秘書口吻，11-07：15:21「失敗單已作廢：<代號>」）
id='900-8-close-push'
row "$id" mid /tmp/h.md "$now" pending /tmp t-close-push > "$TSV"
printf 'require("fs").writeFileSync(%s, require("fs").readFileSync(0))\n' "'$TMP/tg-body'" > "$TG_SEND_BIN"   # dispatch-close 用 node 跑它
bash "$ROOT/bin/dispatch-close" "$id" superseded "跟另一張重複，已併過去" >/dev/null 2>&1
grep -q '已作廢' "$TMP/tg-body" || fail "推送內容沒寫結果：$(cat "$TMP/tg-body")"
if grep -qe "$id" -e 't-close-push' "$TMP/tg-body"; then fail "推給使用者的內容帶了代號：$(cat "$TMP/tg-body")"; fi

echo PASS
