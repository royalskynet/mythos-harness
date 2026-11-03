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
export TMP   # 下面引號 heredoc 產生的假 tmux／judge 會在執行時讀 $TMP
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

cat > "$TMUX_BIN" <<'TMUX'
#!/bin/sh
printf '%s\n' "$*" >> "$TMUX_LOG"
printf '%s\n' "$*" >> "$TMP/all-sent.log"
# FAKE_BUSY 到執行時才判斷（引號 heredoc，11-04 修正：之前建立時就展開，假 busy 從來沒生效）
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

# 背景持 ledger 鎖：<MYTHOS_DIR> <ready 檔>。持鎖者用 exec sleep（沒有殘留子行程，被殺鎖就放），pid 在 $HOLDER
hold_lock() {
  rm -f "$2"
  MYTHOS_DIR="$1" bash -c '. "$0/bin/lib-ledger.sh"; ledger_lock || exit 3; : > "$1"; exec sleep 60' "$ROOT" "$2" &
  HOLDER=$!
  for _ in $(seq 1 50); do [ -f "$2" ] && return 0; sleep 0.1; done
  return 1
}
release_lock() { kill -9 "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true; }
# 試拿一次鎖（不等）：拿得到 exit 0 並立刻放掉
try_lock() { MYTHOS_DIR="$1" LEDGER_LOCK_TRIES="${2:-1}" bash -c '. "$0/bin/lib-ledger.sh"; ledger_lock || exit 1; ledger_unlock' "$ROOT"; }

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
# flock 版：鎖沒放掉＝別人拿不到（舊版斷言是鎖目錄不存在）
try_lock "$MYTHOS_DIR" || fail 'D：ledger 鎖沒放掉'

# ---------- B：gate ----------
printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' > "$TRANSCRIPT"
gate() { printf '%s' "$1" | MYTHOS_DIR="$MYTHOS_DIR" MYTHOS_TRANSCRIPT_DIR="$MYTHOS_TRANSCRIPT_DIR" node "$ROOT/bin/dispatch-gate.mjs" pre; }
out="$(gate '{"tool_name":"SendMessage","tool_input":{"to":"a1","message":"x"},"transcript_path":"'"$TRANSCRIPT"'"}')"
[ -z "$out" ] || fail "B：主 session SendMessage 被擋：$out"
out="$(gate '{"tool_name":"TaskOutput","tool_input":{"task_id":"x"},"transcript_path":"'"$TRANSCRIPT"'"}')"
case "$out" in *'"deny"'*) ;; *) fail "B：TaskOutput 沒擋：$out" ;; esac

# ---------- C：watchdog ----------
WD_STATE="$MYTHOS_DIR/state/watchdog.json"
rm -f "$WD_STATE"   # 從「沒有狀態檔」開始：首次啟動就要能去重
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


# ======================================================================
# 11-04 Codex 二審：每項一條「沒修會 fail」的反例
# ======================================================================

LIB_EVENTS="$ROOT/bin/lib-events.mjs"
event_count() { [ -f "$EVENTS" ] && jq -s 'length' "$EVENTS" || echo 0; }
ev_field() { jq -r --arg e "$1" --arg f "$2" 'select(.event_id==$e) | .[$f]' "$EVENTS"; }

# ---------- 2. watchdog「Router 未回」認成功的 tool_result ----------
W="$TMP/wd"; mkdir -p "$W/router"
wtrans="$W/router/r.jsonl"
stale="$(date -u -v-20M '+%Y-%m-%dT%H:%M:%SZ')"
ch='{"type":"user","isMeta":true,"origin":{"kind":"channel"},"timestamp":"'"$stale"'","message":{"role":"user","content":"hi"}}'
err='{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","is_error":true,"content":"send failed"}]}}'
okres='{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"sent"}]}}'
tu='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"mcp__telegram__reply","input":{"text":"x"}}]}}'
wdbrief="$W/brief/mythos-watchdog.tsv"
wrun() { printf '%s\n' "$@" > "$wtrans"; MYTHOS_BRIEF_DIR="$W/brief" MYTHOS_DIR="$W/mythos" MYTHOS_TRANSCRIPT_DIR="$W/router" bash "$ROOT/bin/watchdog"; }
# 只有 tool_use、沒有結果 → 不算回過
wrun "$ch" "$tu"
[ -s "$wdbrief" ] || fail '2：只有 tool_use 沒結果就被當回過了'
# reply 失敗 → 不算回過（舊版看 tool_use 就會壓掉告警）
rm -rf "$W/mythos" "$W/brief"
wrun "$ch" "$tu" "$err"
[ -s "$wdbrief" ] || fail '2：reply 的 tool_result is_error:true 被當成回過'
# reply 成功 → 不再告警
rm -rf "$W/mythos" "$W/brief"
wrun "$ch" "$tu" "$okres"
[ -e "$wdbrief" ] && fail '2：成功的 reply 仍告警'

# ---------- 1. watchdog 狀態檔初始化：從沒有 watchdog.json 開始連跑兩輪只寫一行 ----------
WD_H="$TMP/wd-init"; mkdir -p "$WD_H/mythos/state"
: > "$WD_H/mythos/state/events.jsonl"
printf '%s\n' '{"event_id":"x-done-1","job_id":"x-done","status":"PASS","tries":5,"acked_at":null}' > "$WD_H/mythos/state/events.jsonl"
WD_BRIEF="$WD_H/brief/mythos-watchdog.tsv"
mkdir -p "$WD_H/router"   # 自己的 transcript 目錄：不然會讀到主 session 的真實 transcript（含 10 分鐘前的訊息）
[ ! -f "$WD_H/mythos/state/watchdog.json" ] || fail '1：測試前提錯了，狀態檔已經存在'
MYTHOS_BRIEF_DIR="$WD_H/brief" MYTHOS_DIR="$WD_H/mythos" MYTHOS_TRANSCRIPT_DIR="$WD_H/router" bash "$ROOT/bin/watchdog" \
  || fail '1：首次啟動（無狀態檔）watchdog 非零退出'
[ -s "$WD_H/mythos/state/watchdog.json" ] || fail '1：首次啟動沒有建立狀態檔'
MYTHOS_BRIEF_DIR="$WD_H/brief" MYTHOS_DIR="$WD_H/mythos" MYTHOS_TRANSCRIPT_DIR="$WD_H/router" bash "$ROOT/bin/watchdog"
[ "$(wc -l < "$WD_BRIEF" | tr -d ' ')" = 1 ] || fail "1：沒有狀態檔時同一條告警寫了多行：$(cat "$WD_BRIEF")"

# ---------- 17. pane 忙：不投遞、tries 不加 ----------
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 'o-busy' mid "$TMP/busy-task.md" "$(now)" pending "$TMP" t-b t-busy dcq >> "$TSV"
: > "$DCQ_HOME/done/o-busy.job"
: > "$TMUX_LOG"
FAKE_BUSY=1 watch
grep -q 'send-keys' "$TMUX_LOG" && fail '17：pane 忙仍投遞'
jq -e 'select(.event_id=="o-busy-PASS") | .tries == 0 and .delivered_at == null' "$EVENTS" >/dev/null \
  || fail "17：pane 忙時 tries 被加了：$(jq -c 'select(.job_id=="o-busy")' "$EVENTS")"
FAKE_BUSY=0 watch
jq -e 'select(.event_id=="o-busy-PASS") | .tries == 1' "$EVENTS" >/dev/null || fail '17：pane 閒置後沒投遞'
printf '%s\n' '{"type":"user","message":{"role":"user","content":"[派工回報] event_id=o-busy-PASS ok"}}' >> "$TRANSCRIPT"
FAKE_BUSY=0 watch
# 忙時重送不改 tries：把已投遞的 PASS 事件推回 11 分鐘前，再在忙的情況下跑一輪
jq -c 'if .event_id=="o-busy-PASS" then .delivered_at = ((now|floor) - 700) | .acked_at = null else . end' "$EVENTS" > "$EVENTS.t" && mv "$EVENTS.t" "$EVENTS"
# ACK 後 ledger 已是 notified-PASS，不會再推導終態事件；改回 pending 模擬「送過但主 session 沒收到」
awk -F'\t' 'BEGIN{OFS="\t"} $1=="o-busy"{$5="pending"} {print}' "$TSV" > "$TSV.t" && mv "$TSV.t" "$TSV"
# 假 tmux 的 -l 文字會被當成 Router 收到而寫進 transcript（ACK）；重送測試要拿掉那筆
grep -v 'event_id=o-busy-PASS' "$TRANSCRIPT" > "$TRANSCRIPT.t" && mv "$TRANSCRIPT.t" "$TRANSCRIPT"
: > "$TMUX_LOG"
FAKE_BUSY=1 watch
grep -q 'event_id=o-busy-PASS' "$TMUX_LOG" && fail '17：忙時重送了'
jq -e 'select(.event_id=="o-busy-PASS") | .tries == 1' "$EVENTS" >/dev/null || fail "17：忙時重送卻加了 tries：$(jq -c 'select(.job_id=="o-busy")' "$EVENTS")"
: > "$TMUX_LOG"
FAKE_BUSY=0 watch
grep -q 'event_id=o-busy-PASS' "$TMUX_LOG" || fail '17：閒置後沒重送'
jq -e 'select(.event_id=="o-busy-PASS") | .tries == 2' "$EVENTS" >/dev/null || fail "17：閒置後重送沒加 tries：$(jq -c 'select(.job_id=="o-busy")' "$EVENTS")"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"[派工回報] event_id=o-busy-PASS ok"}}' >> "$TRANSCRIPT"
FAKE_BUSY=0 watch

# ---------- 3. ACK 精確比對 ----------
A="$TMP/ack"; mkdir -p "$A"
: > "$A/events.jsonl"; : > "$A/tr.jsonl"
for e in job-PASS job-PASS-x job-FAIL-1; do
  printf '{"event_id":"%s","job_id":"job","status":"PASS","tries":0,"acked_at":null}\n' "$e" >> "$A/events.jsonl"
done
scan() { node "$LIB_EVENTS" scan "$A/events.jsonl" "$A/tr.jsonl" | cut -f1 | sort | tr '\n' ' '; }
printf '%s\n' '{"type":"user","message":{"role":"user","content":"[派工回報] event_id=job-PASS-x 收到"}}' > "$A/tr.jsonl"
[ "$(scan)" = "job-PASS-x " ] || fail "3：前綴誤配：$(scan)（job-PASS 不該被 job-PASS-x 配到）"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"[派工回報] event_id=job-PASS 收到；後面還有"}}' > "$A/tr.jsonl"
[ "$(scan)" = "job-PASS " ] || fail "3：後面接空白沒配到：$(scan)"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"[派工回報] event_id=job-PASS；後面還有"}}' > "$A/tr.jsonl"
[ "$(scan)" = "job-PASS " ] || fail "3：後面接全形分號沒配到：$(scan)"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"[派工回報] event_id=job-PASS-x"}}' > "$A/tr.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"[派工回報] event_id=job-PASS"}}' >> "$A/tr.jsonl"
[ "$(scan)" = "job-PASS job-PASS-x " ] || fail "3：字串結尾沒配到：$(scan)"
# tool_result 內容不算
printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"[派工回報] event_id=job-PASS"}]}}' > "$A/tr.jsonl"
[ -z "$(scan)" ] || fail "3：tool_result 被當 ACK：$(scan)"
# assistant 訊息不算
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":"[派工回報] event_id=job-PASS"}}' > "$A/tr.jsonl"
[ -z "$(scan)" ] || fail "3：assistant 紀錄被當 ACK：$(scan)"
# text 區塊照收
printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[派工回報] event_id=job-PASS"}]}}' > "$A/tr.jsonl"
[ "$(scan)" = "job-PASS " ] || fail "3：純 text 區塊沒配到：$(scan)"

# ---------- 4. 取消的票不再投遞 ----------
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 'o-cxl' mid "$TMP/cxl-task.md" "$(now)" pending "$TMP" t-c o-cxl-cxl dcq >> "$TSV"
: > "$DCQ_HOME/done/o-cxl.job"
FAKE_BUSY=0 watch
jq -e 'select(.event_id=="o-cxl-PASS") | .acked_at == null' "$EVENTS" >/dev/null || fail '4：取消測試前提（事件沒建）'
: > "$TMUX_LOG"
bash "$ROOT/bin/dispatch-cancel" o-cxl || fail '4：O 取消非零退出'
jq -e 'select(.event_id=="o-cxl-PASS") | .cancelled == true' "$EVENTS" >/dev/null || fail '4：取消沒把未 ACK 事件標 cancelled'
grep -q send-keys "$TMUX_LOG" && fail '4：取消後還投遞'
# 舊事件沒標 cancelled（模擬取消前建好的），ledger 已 cancelled → 也不投
jq -c 'if .event_id=="o-cxl-PASS" then del(.cancelled) | .delivered_at = 0 else . end' "$EVENTS" > "$EVENTS.t" && mv "$EVENTS.t" "$EVENTS"
: > "$TMUX_LOG"
FAKE_BUSY=0 watch
grep -q 'event_id=o-cxl-PASS' "$TMUX_LOG" && fail '4：ledger 已 cancelled 的 job 仍投遞舊事件'

# ---------- 5. REVIEW／STALL 不暴增 ----------
rid='deep-99-rev-task'
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rid" hard "$TMP/rev-task.md" "$(( $(now) - 1900 ))" pending "$TMP" >> "$TSV"
printf 'rev task\n' > "$TMP/rev-task.md"
mkdir -p "$CLAUDE_PROJECTS_DIR/$TMP"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"FakeTool","input":{"file_path":"/tmp/x"}}]}}\n' > "$CLAUDE_PROJECTS_DIR/$TMP/rev.jsonl"
rm -f "$MYTHOS_DIR/state/deep/$rid.last-review"
FAKE_BUSY=0 watch
FAKE_BUSY=0 watch
FAKE_BUSY=0 watch
[ "$(jq -s --arg r "$rid" '[.[] | select(.job_id==$r and .status=="REVIEW" and .acked_at==null)] | length' "$EVENTS")" = 1 ] \
  || fail "5：同一票未 ACK 的 REVIEW 事件重複：$(jq -c --arg r "$rid" 'select(.job_id==$r)' "$EVENTS")"

# ---------- 6. 抽查不擋投遞：judge 卡死時投遞不被拖過 90 秒 ----------
cat > "$TMP/judge-slow" <<'J'
#!/bin/sh
sleep 300
J
chmod +x "$TMP/judge-slow"
jid='deep-98-slow-task'
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$jid" hard "$TMP/slow-task.md" "$(( $(now) - 1900 ))" pending "$TMP" >> "$TSV"
printf 'slow task\n' > "$TMP/slow-task.md"
rm -f "$MYTHOS_DIR/state/deep/$jid.last-review"
# 另一張票這一輪就有終態，投遞不能被 judge 拖住
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 'o-term' mid "$TMP/term-task.md" "$(now)" pending "$TMP" t-t o-term-t dcq >> "$TSV"
: > "$DCQ_HOME/done/o-term.job"
: > "$TMUX_LOG"
t0="$(now)"
# 真的 judge 在每棒自帶上限（2 棒約 80s）；假 judge 不會。這裡 PATH 沒有 timeout／gtimeout：
# 11-04 起不再用 perl 砍，judge 直接跳過（REVIEW 照投），所以更不能拖住投遞；有 timeout 的硬砍見 21
mkdir -p "$TMP/nobin"; printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v node)" > "$TMP/nobin/node"; chmod +x "$TMP/nobin/node"
FAKE_BUSY=0 REVIEW_JUDGE="$TMP/judge-slow" JUDGE_BUDGET=3 PATH="$TMP/nobin:/usr/bin:/bin:/usr/sbin:/sbin" bash "$ROOT/bin/dispatch-watch" || fail '6：judge 卡死讓 watch 非零退出'
t1="$(now)"
grep -q 'event_id=o-term-PASS' "$TMUX_LOG" || fail '6：judge 卡住時終態沒投遞'
[ $(( t1 - t0 )) -le 15 ] || fail "6：judge 沒有硬砍，投遞晚了 $(( t1 - t0 ))s"

# ---------- 12. 舊列不改寫 ----------
OLD5="$(printf 'o-hist5\tmid\t/tmp/h5.md\t100\tpending')"
printf '%s\n' "$OLD5" >> "$TSV"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 'o-cxl2' mid "$TMP/cxl2-task.md" "$(now)" pending "$TMP" t-h2 o-cxl2-cxl2 dcq >> "$TSV"
: > "$DCQ_HOME/done/o-cxl2.job"
FAKE_BUSY=0 watch
[ "$(grep '^o-hist5' "$TSV")" = "$OLD5" ] || fail "12：watch 改寫了舊列：$(grep '^o-hist5' "$TSV")"
[ "$(grep -c '^o-hist5' "$TSV")" = 1 ] || fail '12：watch 把舊列寫成多行'
grep -q 'event_id=o-cxl2-PASS' "$TMUX_LOG" || fail "12：o-cxl2 的終態沒投遞（取消前提）：$(cat "$TMUX_LOG")"
bash "$ROOT/bin/dispatch-cancel" o-cxl2 || fail '12：取消 o-cxl2 非零'
[ "$(grep '^o-hist5' "$TSV")" = "$OLD5" ] || fail "12：cancel 改寫了舊列：$(grep '^o-hist5' "$TSV")"

# ---------- 9. cancel 寫 ledger 失敗要非零，訊息分開 ----------
CB="$TMP/cxl-bad"; mkdir -p "$CB/mythos/state"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 'o-bad' mid "$TMP/bad.md" 1 pending "$TMP" - dcq > "$CB/mythos/state/dispatch-jobs.tsv"
hold_lock "$CB/mythos" "$CB/ready" || fail '9：測試持鎖者沒拿到鎖'   # 活著的持有者 → 永遠等不到
set +e
out="$(MYTHOS_DIR="$CB/mythos" DCQ_BIN="$TMUX_LOG-dcq" LEDGER_LOCK_TRIES=2 bash "$ROOT/bin/dispatch-cancel" o-bad 2>&1)"; rc=$?
set -e
printf '#!/bin/sh\nexit 0\n' > "$TMUX_LOG-dcq"; chmod +x "$TMUX_LOG-dcq"
set +e
out="$(MYTHOS_DIR="$CB/mythos" DCQ_BIN="$TMUX_LOG-dcq" LEDGER_LOCK_TRIES=2 bash "$ROOT/bin/dispatch-cancel" o-bad 2>&1)"; rc=$?
set -e
release_lock
[ "$rc" != 0 ] || fail '9：ledger 沒寫成功卻 exit 0'
case "$out" in *後端已取消*ledger\ 未更新*) ;; *) fail "9：訊息沒分「後端已取消／ledger 未更新」：$out" ;; esac
[ "$(awk -F'\t' '$1=="o-bad"{print $5}' "$CB/mythos/state/dispatch-jobs.tsv")" = pending ] || fail '9：ledger 竟然寫成功了'

# ---------- 8. dispatch 拿不到鎖：不准先啟動 worker（11-04 裁決：持鎖寫列 → 放鎖 → 才啟動；舊版的無鎖追加已刪） ----------
# 原意「worker 在跑就一定有 ledger 列」改由順序保證：拿不到鎖＝沒有列、也沒有 worker
DB="$TMP/disp-bad"; mkdir -p "$DB/mythos/state" "$DB/mythos/state/deep"
hold_lock "$DB/mythos" "$DB/ready" || fail '8：測試持鎖者沒拿到鎖'
set +e
idbad="$(MYTHOS_DIR="$DB/mythos" LEDGER_LOCK_TRIES=2 bash "$ROOT/bin/dispatch" "$TMP/a1-task.md" "$TMP" hard 2>/dev/null)"; rc=$?
set -e
release_lock
[ "$rc" != 0 ] || fail "8：拿不到鎖卻 exit 0（id=${idbad}）"
[ ! -s "$DB/mythos/state/dispatch-jobs.tsv" ] || fail "8：拿不到鎖卻寫了 ledger：$(cat "$DB/mythos/state/dispatch-jobs.tsv")"
[ -z "$(ls "$DB/mythos/state/deep")" ] || fail "8：拿不到鎖卻啟動了 deep runner：$(ls "$DB/mythos/state/deep")"
[ ! -e "$DB/mythos/logs/dispatch.log" ] || ! grep -q 'unlocked append' "$DB/mythos/logs/dispatch.log" || fail '8：還有無鎖追加'

# ---------- 7. 鎖接手（flock 版）：持有者死了可接手、不放別人的鎖、只解自己的鎖 ----------
# 11-04：mkdir＋pid＋reap 換成 flock；「死行程的鎖可接手」「不刪別人的鎖」兩個意圖照測
LB="$TMP/lock"; mkdir -p "$LB/state"
hold_lock "$LB" "$LB/ready" || fail '7：持鎖者沒拿到鎖'
try_lock "$LB" && fail '7：別人持鎖時還拿得到（不互斥）'
# 沒持鎖的行程呼叫 ledger_unlock 不能放掉別人的鎖
MYTHOS_DIR="$LB" bash -c '. "$0/bin/lib-ledger.sh"; ledger_unlock' "$ROOT" || fail '7：沒持鎖時 unlock 非零'
try_lock "$LB" && fail '7：unlock 放掉了別人的鎖'
# 持有者被 kill -9（沒機會清理）→ 可接手
release_lock
try_lock "$LB" 10 || fail '7：死行程的鎖接不了手'
# 解自己的鎖之後別人拿得到
MYTHOS_DIR="$LB" bash -c '. "$0/bin/lib-ledger.sh"; ledger_lock || exit 3; ledger_unlock' "$ROOT" || fail '7：拿不到空鎖'
try_lock "$LB" || fail '7：unlock 沒把自己的鎖放掉'

# ---------- 10. retry 沿用後端（ledger 第 8 欄） ----------
RB="$TMP/retry-b"; mkdir -p "$RB/mythos/state" "$RB/dcq"
printf '%s\n' '#!/bin/sh' 'case "$1" in add) echo "retry-job-1" ;; esac' 'exit 0' > "$RB/dcq/dcq"; chmod +x "$RB/dcq/dcq"
printf 'body\n' > "$RB/t.md"
printf 'r-dcq\thard\t%s\t%s\tpending\t%s\t-\tdcq\n' "$RB/t.md" 1 "$TMP" > "$RB/mythos/state/dispatch-jobs.tsv"
MYTHOS_DIR="$RB/mythos" DCQ_BIN="$RB/dcq/dcq" bash "$ROOT/bin/dispatch-retry" r-dcq "補" >/dev/null 2>&1 || fail '10：retry dcq 票失敗'
awk -F'\t' '$1=="retry-job-1"{ exit !($8=="dcq" && $2=="mid") }' "$RB/mythos/state/dispatch-jobs.tsv" || fail "10：retry 沒沿用 dcq／沒降成 mid：$(cat "$RB/mythos/state/dispatch-jobs.tsv")"
printf 'r-deep\teasy\t%s\t%s\tpending\t%s\t-\tdeep\n' "$RB/t.md" 1 "$TMP" >> "$RB/mythos/state/dispatch-jobs.tsv"
MYTHOS_DIR="$RB/mythos" bash "$ROOT/bin/dispatch-retry" r-deep "補" >/dev/null 2>&1 || fail '10：retry deep 票失敗'
awk -F'\t' '$1 ~ /^deep-/ && $2=="hard" && $8=="deep"{ found=1 } END { exit !found }' "$RB/mythos/state/dispatch-jobs.tsv" || fail '10：retry 沒沿用 deep（變成別的後端）'

# ---------- 14. 去個人化：slug 由 MYTHOS_DIR 算 ----------
grep -q -- '-Users-' "$ROOT/bin/dispatch-watch" "$ROOT/bin/watchdog" && fail '14：腳本裡還有寫死的個人 transcript slug'
# 公開範圍＝git 追蹤的檔（.gitignore 白名單）；樣式拆開寫，本檔才不會被同一條掃描命中
internal="5""1mini|Car""rie|Coi""nW|L""CT|Be""ss|backlog\\.sql""ite"
if git -C "$ROOT" grep -n -E "$internal" -- bin tests router launchd README.md; then
  fail '14：公開內容還有個人／內部名稱'
fi


# ======================================================================
# 11-04 Codex 三審：裁決後 7 項，每項一條「沒修會 fail」的反例（18 起）
# ======================================================================

# 開一個乾淨的 MYTHOS_DIR 組（跟上面共用的 ledger／events 隔開）：設定 $F 與相關環境變數
fresh() {
  F="$TMP/$1"
  mkdir -p "$F/mythos/state/deep" "$F/dcq"/{done,failed,running,pending} "$F/projects" "$F/router"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' > "$F/router/r.jsonl"
}
# 在 $F 裡登錄一張「該抽查了」的 deep 票（開跑 31 分鐘、transcript 剛更新、沒 rc）
due_review() { # id cwd
  local slug
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" hard "$F/$1.md" "$(( $(now) - 1860 ))" pending "$2" - deep >> "$F/mythos/state/dispatch-jobs.tsv"
  printf 'task %s\n' "$1" > "$F/$1.md"
  slug="$(printf '%s' "$2" | sed 's/[\/.]/-/g')"
  mkdir -p "$F/projects/$slug"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"FakeTool","input":{"file_path":"/tmp/x"}}]}}\n' > "$F/projects/$slug/p.jsonl"
}
fwatch() { MYTHOS_DIR="$F/mythos" DCQ_HOME="$F/dcq" CLAUDE_PROJECTS_DIR="$F/projects" MYTHOS_TRANSCRIPT_DIR="$F/router" FAKE_BUSY=0 bash "$ROOT/bin/dispatch-watch"; }

# ---------- 18. P0 鎖：flock 互斥、kill -9 的持有者 2 秒內可接手 ----------
L18="$TMP/l18"; mkdir -p "$L18/state"; printf '0\n' > "$L18/count"
bump20() {
  MYTHOS_DIR="$L18" bash -c '. "$0/bin/lib-ledger.sh"
    for i in $(seq 1 20); do
      ledger_lock || exit 3
      n="$(cat "$1")"; sleep 0.05; printf "%s\n" "$((n + 1))" > "$1"
      ledger_unlock
    done' "$ROOT" "$L18/count"
}
bump20 & b1=$!
bump20 & b2=$!
wait "$b1" || fail '18：計數行程 1 拿不到鎖'
wait "$b2" || fail '18：計數行程 2 拿不到鎖'
[ "$(cat "$L18/count")" = 40 ] || fail "18：兩行程各 20 次讀→寫+1，結果 $(cat "$L18/count")（應 40，鎖不互斥）"
hold_lock "$L18" "$L18/ready" || fail '18：持鎖者沒拿到鎖'
try_lock "$L18" && fail '18：A 持鎖時 B 還拿得到'
kill -9 "$HOLDER"; wait "$HOLDER" 2>/dev/null || true
t0="$(now)"
try_lock "$L18" 10 || fail '18：持有者 kill -9 後拿不到鎖'
[ $(( $(now) - t0 )) -le 2 ] || fail "18：kill -9 後過了 $(( $(now) - t0 )) 秒才拿到鎖"
# MYTHOS_DIR 沒設也能 source（set -u 不中斷），鎖檔由 lib 位置推導
env -u MYTHOS_DIR LEDGER_LOCK_FILE="$L18/state/.alt.flock" bash -c 'set -u; . "$0/bin/lib-ledger.sh"; ledger_lock && ledger_unlock' "$ROOT" \
  || fail '18：MYTHOS_DIR 未設時 lib-ledger 中斷'
[ "$(env -u MYTHOS_DIR -u LEDGER_LOCK_FILE bash -c 'set -u; . "$0/bin/lib-ledger.sh"; printf %s "$LEDGER_LOCK_FILE"' "$ROOT")" = "$ROOT/state/.ledger.flock" ] \
  || fail '18：MYTHOS_DIR 未設時鎖檔沒由腳本目錄推導'

# ---------- 19. P0 dispatch 拿不到鎖：不呼叫 dcq、不寫列、exit 非 0；放鎖後正常 ----------
fresh d19
printf '%s\n' '#!/bin/sh' "printf '%s\\n' \"\$*\" >> \"$F/dcq.log\"" 'case "$1" in add) echo "job-19" ;; esac' 'exit 0' > "$F/dcq/dcq"
chmod +x "$F/dcq/dcq"; : > "$F/dcq.log"
printf 'd19\n' > "$F/t.md"
hold_lock "$F/mythos" "$F/ready" || fail '19：持鎖者沒拿到鎖'
set +e
out="$(MYTHOS_DIR="$F/mythos" DCQ_BIN="$F/dcq/dcq" LEDGER_LOCK_TRIES=2 bash "$ROOT/bin/dispatch" "$F/t.md" "$TMP" mid 2>&1)"; rc=$?
set -e
[ "$rc" != 0 ] || fail '19：拿不到鎖卻 exit 0'
[ ! -s "$F/dcq.log" ] || fail "19：拿不到鎖還呼叫了 dcq：$(cat "$F/dcq.log")"
[ ! -s "$F/mythos/state/dispatch-jobs.tsv" ] || fail '19：拿不到鎖還寫了 ledger'
case "$out" in *拿不到\ ledger\ 鎖，未派出*) ;; *) fail "19：沒印「拿不到 ledger 鎖，未派出」：$out" ;; esac
release_lock
out="$(MYTHOS_DIR="$F/mythos" DCQ_BIN="$F/dcq/dcq" bash "$ROOT/bin/dispatch" "$F/t.md" "$TMP" mid)" || fail '19：放鎖後 dispatch 失敗'
[ "$out" = job-19 ] || fail "19：放鎖後 id 不對：$out"
awk -F'\t' '$1=="job-19" && $5=="pending" && $8=="dcq" { f=1 } END { exit !f }' "$F/mythos/state/dispatch-jobs.tsv" || fail '19：放鎖後 ledger 沒有列'
grep -q '^add ' "$F/dcq.log" || fail '19：放鎖後沒呼叫 dcq add'

# ---------- 20. P1 deep id：同一秒、同檔名、不同目錄、不同行程 → id 不同 ----------
fresh d20
mkdir -p "$F/fakebin" "$F/a" "$F/b"
printf '%s\n' '#!/bin/sh' 'if [ "$1" = "+%s" ]; then echo 1700000000; else exec /bin/date "$@"; fi' > "$F/fakebin/date"
chmod +x "$F/fakebin/date"
printf 'a\n' > "$F/a/same.md"; printf 'b\n' > "$F/b/same.md"
PATH="$F/fakebin:$PATH" MYTHOS_DIR="$F/mythos" bash "$ROOT/bin/dispatch" "$F/a/same.md" "$TMP" hard > "$F/ida" 2>/dev/null &
pa=$!
PATH="$F/fakebin:$PATH" MYTHOS_DIR="$F/mythos" bash "$ROOT/bin/dispatch" "$F/b/same.md" "$TMP" hard > "$F/idb" 2>/dev/null &
pb=$!
wait "$pa" || fail '20：第一張 deep 派工失敗'
wait "$pb" || fail '20：第二張 deep 派工失敗'
ida="$(cat "$F/ida")"; idb="$(cat "$F/idb")"
case "$ida" in deep-1700000000-*-same) ;; *) fail "20：id 格式不是 deep-<epoch>-<pid>-<name>：$ida" ;; esac
[ -n "$ida" ] && [ "$ida" != "$idb" ] || fail "20：同秒同名兩張 deep 票 id 撞了：$ida／$idb"
[ "$(cut -f1 "$F/mythos/state/dispatch-jobs.tsv" | sort -u | wc -l | tr -d ' ')" = 2 ] || fail '20：ledger 兩張票 id 不唯一'

# ---------- 21. P1 judge 逾時：JUDGE_BUDGET 可覆寫且真的砍；沒 timeout 就跳過 judge、REVIEW 照投 ----------
command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || fail '21：測試機沒有 timeout／gtimeout（brew install coreutils）'
fresh d21
printf '%s\n' '#!/bin/sh' "printf 'start\\n' >> \"$F/judge.marker\"" 'sleep 10' 'echo ON_TRACK' > "$F/judge"
chmod +x "$F/judge"
due_review deep-21-a "$F/cwd-a"
: > "$TMUX_LOG"
t0="$(now)"
REVIEW_JUDGE="$F/judge" JUDGE_BUDGET=1 fwatch || fail '21a：watch 非零退出'
t1="$(now)"
[ -s "$F/judge.marker" ] || fail '21a：judge 沒啟動（JUDGE_BUDGET 被寫死或預算算錯）'
[ $(( t1 - t0 )) -le 5 ] || fail "21a：JUDGE_BUDGET=1 但 watch 跑了 $(( t1 - t0 )) 秒（judge 沒被砍）"
grep -q 'event_id=deep-21-a-REVIEW' "$TMUX_LOG" || fail '21a：judge 逾時後 REVIEW 沒照投'
# (b) PATH 只留沒有 timeout／gtimeout 的目錄：其餘指令 symlink 進去
fresh d21b
mkdir -p "$F/onlybin"
for f in /usr/bin/* /bin/* "$(command -v node)" "$(command -v jq)"; do
  b="$(basename "$f")"
  case "$b" in timeout|gtimeout) continue ;; esac
  [ -e "$F/onlybin/$b" ] || ln -s "$f" "$F/onlybin/$b"
done
[ ! -e "$F/onlybin/timeout" ] && [ ! -e "$F/onlybin/gtimeout" ] || fail '21b：測試前提錯了，PATH 裡還有 timeout'
printf '%s\n' '#!/bin/sh' "printf 'start\\n' >> \"$F/judge.marker\"" 'echo ON_TRACK' > "$F/judge"
chmod +x "$F/judge"
due_review deep-21-b "$F/cwd-b"
: > "$TMUX_LOG"
PATH="$F/onlybin" REVIEW_JUDGE="$F/judge" fwatch || fail '21b：沒 timeout 時 watch 非零退出'
grep -q 'event_id=deep-21-b-REVIEW' "$TMUX_LOG" || fail "21b：沒 timeout 時 REVIEW 被吞了：$(cat "$TMUX_LOG")"
[ ! -e "$F/judge.marker" ] || fail '21b：沒 timeout 還是跑了 judge（沒有硬砍保護）'
grep -q 'WARN no timeout, judge skipped' "$F/mythos/logs/dispatch-watch.log" || fail '21b：log 沒記 WARN no timeout, judge skipped'

# ---------- 22. P1 終態先投遞、抽查後跑：同輪 O 票完成＋慢 judge 的 deep 票 ----------
fresh d22
SEQ="$F/seq.log"; : > "$SEQ"
cat > "$F/tmux" <<'T22'
#!/bin/sh
case " $* " in
  *" send-keys "*" -l "*) printf 'SEND %s\n' "$*" >> "$SEQ" ;;
  *" capture-pane "*) printf 'idle screen\n' ;;
esac
exit 0
T22
chmod +x "$F/tmux"
printf '%s\n' '#!/bin/sh' "printf 'JUDGE-START\\n' >> \"$SEQ\"" 'sleep 5' 'echo OFF_TRACK' > "$F/judge"
chmod +x "$F/judge"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 'o-ord' mid "$F/ord.md" "$(now)" pending "$TMP" t-ord dcq >> "$F/mythos/state/dispatch-jobs.tsv"
: > "$F/dcq/done/o-ord.job"
due_review deep-22-slow "$F/cwd-22"
SEQ="$SEQ" TMUX_BIN="$F/tmux" REVIEW_JUDGE="$F/judge" JUDGE_BUDGET=2 fwatch || fail '22：watch 非零退出'
send_at="$(grep -n 'event_id=o-ord-PASS' "$SEQ" | head -1 | cut -d: -f1)"
judge_at="$(grep -n 'JUDGE-START' "$SEQ" | head -1 | cut -d: -f1)"
[ -n "$send_at" ] || fail "22：終態沒投遞：$(cat "$SEQ")"
[ -n "$judge_at" ] || fail "22：judge 沒啟動：$(cat "$SEQ")"
[ "$send_at" -lt "$judge_at" ] || fail "22：judge 先於終態投遞（judge 第 ${judge_at} 行、終態第 ${send_at} 行）：$(cat "$SEQ")"

# ---------- 23. P1 deep 取消只用 handle：內容相同的兩張票，取消 A 不碰 B；A 無 handle 就拒絕 ----------
fresh d23
mkdir -p "$F/deep-task"
printf '%s\n' '#!/bin/sh' "printf '%s\\n' \"\$*\" >> \"$F/tmux.log\"" 'exit 0' > "$F/tmux"
chmod +x "$F/tmux"; : > "$F/tmux.log"
printf 'same body\n' > "$F/a.md"; printf 'same body\n' > "$F/b.md"; printf 'same body\n' > "$F/a2.md"
# sleep 以外的子程序（含背景 sleep 自己）stdio 都要導掉：$( … ) 會等「所有」握著 stdout 的程序
sleep 600 >/dev/null 2>&1 & pA=$!
sleep 600 >/dev/null 2>&1 & pB=$!
J23="$F/mythos/state/dispatch-jobs.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' deep-1-1-a hard "$F/a.md" 1 pending "$TMP" - deep >> "$J23"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' deep-2-2-b hard "$F/b.md" 2 pending "$TMP" - deep >> "$J23"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' deep-3-3-a2 hard "$F/a2.md" 3 pending "$TMP" - deep >> "$J23"
# handle 照 runner 的格式寫：ps -o lstart= 原樣
printf 'pid=%s\npid_start=%s\nsession=deep-111-1\n' "$pA" "$(ps -o lstart= -p "$pA")" > "$F/mythos/state/deep/deep-1-1-a.handle"
printf 'pid=%s\nsession=deep-222-2\n' "$pB" > "$F/mythos/state/deep/deep-2-2-b.handle"
# 舊版的「猜」：.deep 下內容相同、B 最新 → 會挑中 B
cp "$F/a.md" "$F/deep-task/111-1-task.md"; touch -A -0100 "$F/deep-task/111-1-task.md"
cp "$F/b.md" "$F/deep-task/222-2-task.md"
c23() { MYTHOS_DIR="$F/mythos" TMUX_BIN="$F/tmux" DEEP_TASK_DIR="$F/deep-task" bash "$ROOT/bin/dispatch-cancel" "$1"; }
# 正例：start 相符 → 殺
c23 deep-1-1-a 2>/dev/null || fail '23：start 相符卻取消失敗'
grep -q 'kill-session -t =deep-111-1$' "$F/tmux.log" || fail "23：沒照 handle 殺 A 的 session：$(cat "$F/tmux.log")"
grep -q 'deep-222-2' "$F/tmux.log" && fail "23：取消 A 卻碰了 B 的 session：$(cat "$F/tmux.log")"
for _ in $(seq 1 50); do kill -0 "$pA" 2>/dev/null || break; sleep 0.1; done
kill -0 "$pA" 2>/dev/null && fail '23：A 的 runner 沒被殺'
wait "$pA" 2>/dev/null || true
kill -0 "$pB" 2>/dev/null || fail '23：取消 A 殺了 B 的 runner'
[ "$(awk -F'\t' '$1=="deep-1-1-a"{print $5}' "$J23")" = cancelled ] || fail '23：A 沒標 cancelled'
# 反例前把正例留下的 rc 與 cancelled 清回 pending，才量得到「身分不符沒動 ledger」
rm -f "$F/mythos/state/deep/deep-1-1-a.rc"
awk -F'\t' 'BEGIN{OFS="\t"} $1=="deep-1-1-a"{$5="pending"} 1' "$J23" > "$J23.tmp" && mv "$J23.tmp" "$J23"
# handle 沒記 start（舊格式，分不出 pid 是否被重用）→ pid 視為空、不送訊號、exit 1
sleep 600 >/dev/null 2>&1 & pA=$!
printf 'pid=%s\n' "$pA" > "$F/mythos/state/deep/deep-1-1-a.handle"
set +e; out="$(c23 deep-1-1-a 2>&1)"; rc=$?; set -e
[ "$rc" = 1 ] || fail "23n：handle 沒 pid_start 卻 exit ${rc}"
kill -0 "$pA" 2>/dev/null || fail '23n：handle 沒 pid_start 還是殺了程序'
case "$out" in *"身分不符，不送訊號：$pA"*) ;; *) fail "23n：沒印身分不符：$out" ;; esac
# stale-handle：pid 活著但記的 start 不同（pid 被別的程序重用）→ 不送訊號、不碰 tmux、exit 1
printf 'pid=%s\npid_start=Thu Jan  1 00:00:00 1970\n' "$pA" > "$F/mythos/state/deep/deep-1-1-a.handle"
printf '%s\n' '{"event_id":"deep-1-1-a-PASS","job_id":"deep-1-1-a","acked_at":null}' >> "$F/mythos/state/events.jsonl"
: > "$F/tmux.log"
set +e; out="$(c23 deep-1-1-a 2>&1)"; rc=$?; set -e
[ "$rc" = 1 ] || fail "23s：stale handle 卻 exit ${rc}"
kill -0 "$pA" 2>/dev/null || fail '23s：start 不符還是殺了程序'
case "$out" in *"身分不符，不送訊號：$pA"*) ;; *) fail "23s：沒印身分不符：$out" ;; esac
[ ! -s "$F/tmux.log" ] || fail "23s：start 不符還動了 tmux：$(cat "$F/tmux.log")"
[ "$(awk -F'\t' '$1=="deep-1-1-a"{print $5}' "$J23")" = pending ] || fail '23s：身分不符卻改了 ledger 狀態'
[ "$(cat "$F/mythos/state/deep/deep-1-1-a.rc" 2>/dev/null)" != 130 ] || fail '23s：身分不符卻寫了 rc=130'
jq -e 'select(.event_id=="deep-1-1-a-PASS") | .cancelled == null' "$F/mythos/state/events.jsonl" >/dev/null || fail '23s：身分不符卻撤銷了事件'
# stale-handle＋session（正式 runner 格式）：pid 不符就整張拒絕，不殺 session、不寫 rc、不動 ledger
printf 'pid=%s\npid_start=Thu Jan  1 00:00:00 1970\nsession=deep-111-1\n' "$pA" > "$F/mythos/state/deep/deep-1-1-a.handle"
: > "$F/tmux.log"
set +e; out="$(c23 deep-1-1-a 2>&1)"; rc=$?; set -e
[ "$rc" = 1 ] || fail "23sf：stale handle（有 session）卻 exit ${rc}"
kill -0 "$pA" 2>/dev/null || fail '23sf：start 不符還是殺了程序'
case "$out" in *"身分不符，不送訊號：$pA"*) ;; *) fail "23sf：沒印身分不符：$out" ;; esac
[ ! -s "$F/tmux.log" ] || fail "23sf：start 不符還動了 tmux：$(cat "$F/tmux.log")"
[ ! -e "$F/mythos/state/deep/deep-1-1-a.rc" ] || fail '23sf：身分不符卻寫了 rc'
[ "$(awk -F'\t' '$1=="deep-1-1-a"{print $5}' "$J23")" = pending ] || fail '23sf：身分不符卻改了 ledger 狀態'
jq -e 'select(.event_id=="deep-1-1-a-PASS") | .cancelled == null' "$F/mythos/state/events.jsonl" >/dev/null || fail '23sf：身分不符卻撤銷了事件'
: > "$F/tmux.log"
set +e; out="$(c23 deep-3-3-a2 2>&1)"; rc=$?; set -e
[ "$rc" = 1 ] || fail "23：沒 handle 卻沒 exit 1（rc=${rc}）"
case "$out" in *沒有\ handle，拒絕猜*) ;; *) fail "23：沒 handle 的訊息不對：$out" ;; esac
[ ! -s "$F/tmux.log" ] || fail "23：沒 handle 還去動 tmux：$(cat "$F/tmux.log")"
kill -0 "$pB" 2>/dev/null || fail '23：沒 handle 的取消殺了 B'
[ "$(awk -F'\t' '$1=="deep-3-3-a2"{print $5}' "$J23")" = pending ] || fail '23：沒 handle 卻改了 ledger'
[ "$(awk -F'\t' '$1=="deep-2-2-b"{print $5}' "$J23")" = pending ] || fail '23：B 的 ledger 被改了'
# 正例：start 相符 → 殺（handle 照 runner 格式：一次 ps 取 pid 與 start）
printf 'pid=%s\npid_start=%s\n' "$pA" "$(ps -o lstart= -p "$pA")" > "$F/mythos/state/deep/deep-1-1-a.handle"
c23 deep-1-1-a 2>/dev/null || fail '23g：start 相符卻取消失敗'
for _ in $(seq 1 50); do kill -0 "$pA" 2>/dev/null || break; sleep 0.1; done
kill -0 "$pA" 2>/dev/null && fail '23g：start 相符卻沒殺'
wait "$pA" 2>/dev/null || true
[ "$(awk -F'\t' '$1=="deep-1-1-a"{print $5}' "$J23")" = cancelled ] || fail '23g：start 相符卻沒標 cancelled'
kill "$pB" 2>/dev/null || true; wait "$pB" 2>/dev/null || true
# runner 自己會寫 handle（派完就有，cancel 才有得用）
fresh d23r
printf '%s\n' '#!/bin/sh' 'exec sleep 30' > "$F/deep-run"; chmod +x "$F/deep-run"
printf 'r\n' > "$F/r.md"
rid="$(MYTHOS_DIR="$F/mythos" DEEP_RUN_BIN="$F/deep-run" bash "$ROOT/bin/dispatch" "$F/r.md" "$TMP" hard)"
grep -q '^pid=[0-9][0-9]*$' "$F/mythos/state/deep/$rid.handle" || fail "23：runner 沒寫 handle：$(cat "$F/mythos/state/deep/$rid.handle" 2>&1)"
MYTHOS_DIR="$F/mythos" TMUX_BIN="$F/tmux" bash "$ROOT/bin/dispatch-cancel" "$rid" 2>/dev/null || fail '23：剛派出的 deep 票取消失敗'
[ "$(cat "$F/mythos/state/deep/$rid.rc")" = 130 ] || fail '23：取消後 rc 不是 130'
rpid="$(awk -F= '$1=="pid"{print $2}' "$F/mythos/state/deep/$rid.handle")"
sleep 0.3; kill -0 "$rpid" 2>/dev/null && fail '23：取消後 runner 還活著'

# ---------- 24. P1 events 不互蓋：兩行程各 20 筆並行 upsert（經 ledger_events 持鎖）→ 40 筆都在 ----------
fresh d24
E24="$F/mythos/state/events.jsonl"
up20() {
  MYTHOS_DIR="$F/mythos" bash -c '. "$0/bin/lib-ledger.sh"
    for i in $(seq 1 20); do
      ledger_events upsert "$1" "{\"event_id\":\"$2-$i\",\"job_id\":\"$2\",\"tries\":0,\"acked_at\":null}" >/dev/null || exit 3
    done' "$ROOT" "$E24" "$1"
}
up20 w1 & u1=$!
up20 w2 & u2=$!
wait "$u1" || fail '24：寫者 1 失敗'
wait "$u2" || fail '24：寫者 2 失敗'
[ "$(jq -s 'length' "$E24")" = 40 ] || fail "24：並行寫 events 掉了：$(jq -s 'length' "$E24") 筆（應 40）"
[ "$(jq -r .event_id "$E24" | sort -u | wc -l | tr -d ' ')" = 40 ] || fail '24：events 有重複或缺漏'
# 原子替換：寫入中途讀者不能看到變短的檔（截斷後重寫的半份）
big="$(printf '%04000d' 0)"
( for i in $(seq 1 40); do node "$ROOT/bin/lib-events.mjs" upsert "$E24" "{\"event_id\":\"big-$i\",\"job_id\":\"big\",\"pad\":\"$big\"}" >/dev/null; done; : > "$F/w.done" ) &
wbig=$!
prev=0; shrunk=0
while [ ! -f "$F/w.done" ]; do
  n="$(wc -l < "$E24" | tr -d ' ')"
  [ "$n" -lt "$prev" ] && shrunk=1
  prev="$n"
done
wait "$wbig" || fail '24：大筆寫者失敗'
[ "$shrunk" = 0 ] || fail '24：讀者看到 events.jsonl 變短（寫入不是原子替換）'
[ "$(jq -s 'length' "$E24")" = 80 ] || fail "24：大筆寫入後筆數不對：$(jq -s 'length' "$E24")"
# 上面的讀者靠撞時機；這條是確定性的：原子替換＝rename 換上新檔（inode 變），原地截斷重寫 inode 不變
ino0="$(stat -f %i "$E24")"
node "$ROOT/bin/lib-events.mjs" set "$E24" big-1 '{"acked_at":1}' >/dev/null || fail '24：set 失敗'
[ "$(stat -f %i "$E24")" != "$ino0" ] || fail '24：events.jsonl 是原地改寫（inode 沒變），不是暫存檔＋rename'
ls "$F/mythos/state" | grep -q '\.tmp\.' && fail '24：留下 events 暫存檔'

# ---------- 25. P1 judge 無視 TERM 也要被砍：timeout -k 5，一輪 10 秒內結束、REVIEW 照投 ----------
command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || fail '25：測試機沒有 timeout／gtimeout'
fresh d25
printf '%s\n' '#!/bin/sh' "printf 'start\\n' >> \"$F/judge.marker\"" 'trap "" TERM' 'sleep 30' 'echo ON_TRACK' > "$F/judge"
chmod +x "$F/judge"
due_review deep-25-a "$F/cwd-25"
: > "$TMUX_LOG"
t0="$(now)"
REVIEW_JUDGE="$F/judge" JUDGE_BUDGET=2 fwatch || fail '25：watch 非零退出'
t1="$(now)"
[ -s "$F/judge.marker" ] || fail '25：judge 沒啟動'
[ $(( t1 - t0 )) -le 10 ] || fail "25：judge 忽略 TERM 後 watch 跑了 $(( t1 - t0 )) 秒（沒 -k 5）"
grep -q 'event_id=deep-25-a-REVIEW' "$TMUX_LOG" || fail '25：judge 被砍後 REVIEW 沒照投'

echo PASS
