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
# 真的 judge 在每棒自帶上限（2 棒約 80s）；假 judge 不會，這裡讓 path 沒有 timeout，逼它走 perl 砍法
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
grep -q 'event_id=o-cxl2-PASS' "$TMUX_LOG" || true
bash "$ROOT/bin/dispatch-cancel" o-cxl2 || fail '12：取消 o-cxl2 非零'
[ "$(grep '^o-hist5' "$TSV")" = "$OLD5" ] || fail "12：cancel 改寫了舊列：$(grep '^o-hist5' "$TSV")"

# ---------- 9. cancel 寫 ledger 失敗要非零，訊息分開 ----------
CB="$TMP/cxl-bad"; mkdir -p "$CB/mythos/state"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' 'o-bad' mid "$TMP/bad.md" 1 pending "$TMP" - dcq > "$CB/mythos/state/dispatch-jobs.tsv"
LDIR="$CB/mythos/state/.ledger.lock"; mkdir -p "$LDIR"; printf '%s\n' "$$" > "$LDIR/pid"   # 活著的持有者 → 永遠等不到
set +e
out="$(MYTHOS_DIR="$CB/mythos" DCQ_BIN="$TMUX_LOG-dcq" bash "$ROOT/bin/dispatch-cancel" o-bad 2>&1)"; rc=$?
set -e
printf '#!/bin/sh\nexit 0\n' > "$TMUX_LOG-dcq"; chmod +x "$TMUX_LOG-dcq"
set +e
out="$(MYTHOS_DIR="$CB/mythos" DCQ_BIN="$TMUX_LOG-dcq" bash "$ROOT/bin/dispatch-cancel" o-bad 2>&1)"; rc=$?
set -e
[ "$rc" != 0 ] || fail '9：ledger 沒寫成功卻 exit 0'
case "$out" in *後端已取消*ledger\ 未更新*) ;; *) fail "9：訊息沒分「後端已取消／ledger 未更新」：$out" ;; esac
[ "$(awk -F'\t' '$1=="o-bad"{print $5}' "$CB/mythos/state/dispatch-jobs.tsv")" = pending ] || fail '9：ledger 竟然寫成功了'

# ---------- 8. dispatch 拿不到鎖：worker 已啟動也要登錄＋WARN ----------
DB="$TMP/disp-bad"; mkdir -p "$DB/mythos/state" "$DB/mythos/state/deep"
printf '%s\n' "$$" > /dev/null
LDIR="$DB/mythos/state/.ledger.lock"; mkdir -p "$LDIR"; printf '%s\n' "$$" > "$LDIR/pid"
set +e
idbad="$(MYTHOS_DIR="$DB/mythos" DISPATCH_LOCK_WAIT_REG=1 bash "$ROOT/bin/dispatch" "$TMP/a1-task.md" "$TMP" hard 2>/dev/null)"; rc=$?
set -e
[ "$rc" = 0 ] || fail "8：拿不到鎖就退出（rc=${rc}），worker 已在跑卻沒登錄"
[ -n "$idbad" ] && grep -q "^$idbad	" "$DB/mythos/state/dispatch-jobs.tsv" || fail '8：worker 已啟動但 ledger 沒有這一列'
grep -q "WARN unlocked append $idbad" "$DB/mythos/logs/dispatch.log" || fail '8：沒有 logs/dispatch.log 的 WARN unlocked append'

# ---------- 7. 鎖接手：死不刪別人的新鎖、缺 pid 的超時才接手、只解自己的鎖 ----------
LB="$TMP/lock"; mkdir -p "$LB"
(
  . "$ROOT/bin/lib-ledger.sh"
  mkdir -p "$LEDGER_LOCK"; printf '%s\n' 999999 > "$LEDGER_LOCK/pid"   # 死 pid
  ledger_lock || exit 3
  # 另一個等待者剛建立的「新鎖」不能被後來的接手者誤刪
  mkdir "$LEDGER_LOCK.stale.999998" 2>/dev/null || true
  ledger_unlock
) 7>"$LB/.lg" 2>&1
mkdir -p "$LB"
LB_LOCK="$LB/state/.ledger.lock"; mkdir -p "$LB_LOCK"; printf '%s\n' 999999 > "$LB_LOCK/pid"
MYTHOS_DIR="$LB" bash -c '. "$0/bin/lib-ledger.sh"; ledger_lock || exit 3; [ "$(cat "$LEDGER_LOCK/pid")" = "$$" ] || exit 4; ledger_unlock; if [ -d "$LEDGER_LOCK" ]; then exit 5; fi' "$ROOT" || fail '7：死 pid 的鎖接不了手或解不掉'
# 缺 pid 檔：剛建（<10 秒）別人的鎖不接手；mtime 超過 10 秒才接手
mkdir -p "$LB_LOCK"
MYTHOS_DIR="$LB" bash -c '. "$0/bin/lib-ledger.sh"; ledger_lock && exit 9' "$ROOT" && fail '7：搶了別人的活鎖（沒有 pid 但還新的鎖）'
rm -rf "$LB_LOCK"; mkdir -p "$LB_LOCK"; touch -t "$(date -v-30S '+%Y%m%d%H%M')" "$LB_LOCK"
MYTHOS_DIR="$LB" bash -c '. "$0/bin/lib-ledger.sh"; ledger_lock || exit 3; ledger_unlock' "$ROOT" || fail '7：缺 pid 且超過 10 秒的鎖沒接手'
# unlock 只刪自己的：持有者換人就不刪
mkdir -p "$LB_LOCK"; printf '%s\n' 999999 > "$LB_LOCK/pid"
MYTHOS_DIR="$LB" bash -c '. "$0/bin/lib-ledger.sh"; ledger_unlock; [ -d "$LEDGER_LOCK" ] || exit 6' "$ROOT" || fail '7：unlock 刪了別人的鎖'
rm -rf "$LB_LOCK"

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

echo PASS
