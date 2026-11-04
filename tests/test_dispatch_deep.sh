#!/usr/bin/env bash
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-deep-test.XXXXXX")"
# F2：只殺自己記下的 pid；retry 工單帶著本輪唯一前綴，結束時只刪自己那幾個檔
PIDS=()
cleanup() {
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
  rm -f "${RETRY_FILES[@]+"${RETRY_FILES[@]}"}"
  [ -n "${KEEP:-}" ] || rm -rf "$TMP"
}
trap cleanup EXIT
RETRY_FILES=()
RETRY_PREFIX="dd-$(basename "$TMP")"   # 本輪唯一的工單名前綴，retry 產生的 /tmp/dc-worker/<前綴>-rN.md 只可能是自己的

export MYTHOS_DIR="$TMP/mythos"
export DCQ_HOME="$TMP/dcq"
export TMUX_BIN="$TMP/tmux"
export TMUX_LOG="$TMP/tmux.log"
export CLAUDE_PROJECTS_DIR="$TMP/claude-projects"
export DEEP_TASK_DIR="$TMP/deep-task"
export DEEP_RUN_BIN="$TMP/deep-run"
export DCQ_BIN="$TMP/dcq-fail"
# A（11-03）：送進 tmux 不算數，Mythos transcript 出現 event_id=… 的 user 紀錄才 ACK；
# 假 tmux 在 send-keys -l 時追加一筆 user 紀錄，模擬 Router 收到。
export MYTHOS_TRANSCRIPT_DIR="$TMP/router-transcript"
# 這支只驗單票路由／生命週期；同一 cwd 連派多張 hard 的佇列行為由 tests/test-repo-queue.sh 驗，這裡關掉
export DISPATCH_REPO_QUEUE=0
# F1：bin/dispatch 在測試模式只肯跑 sandbox 內的 runner；這層 shim 轉給 repo 的 dispatch-deep-run，
# 它再驗下一層 DEEP_RUN_BIN 也在 sandbox 內
mkdir -p "$TMP/shim"
printf '#!/bin/sh\nexec "%s/bin/dispatch-deep-run" "$@"\n' "$ROOT" > "$TMP/shim/dispatch-deep-run"
chmod +x "$TMP/shim/dispatch-deep-run"
export DISPATCH_DEEP_RUN_BIN="$TMP/shim/dispatch-deep-run"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"  # F1：自己的 stub 設好之後才 source；沒設的 runner／tmux 換 guard stub

mkdir -p "$MYTHOS_DIR/state" "$DCQ_HOME" "$CLAUDE_PROJECTS_DIR" "$DEEP_TASK_DIR" "$MYTHOS_TRANSCRIPT_DIR"
: > "$TMUX_LOG"

cat > "$TMUX_BIN" <<'TMUX'
#!/bin/sh
printf '%s\n' "$*" >> "$TMUX_LOG"
case " $* " in
  " -L mythos send-keys -t mythos -l "*) esc="$(printf '%s' "$8" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$esc" >> "$MYTHOS_TRANSCRIPT_DIR/router.jsonl" ;;
esac
case " $* " in
  *" capture-pane "*)
    if [ "${FAKE_BUSY:-0}" = 1 ]; then printf 'working... esc to interrupt\n'; else printf 'idle screen\n'; fi
    ;;
esac
exit 0
TMUX
chmod +x "$TMUX_BIN"

cat > "$DCQ_BIN" <<'DCQ'
#!/bin/sh
echo "DCQ CALLED" >> "${TMPDIR:-/tmp}/dcq-called"
exit 1
DCQ
chmod +x "$DCQ_BIN"

cat > "$DEEP_RUN_BIN" <<'DEEP'
#!/bin/sh
task="$1"
case "$(basename "$task")" in
  *fail*) printf 'CLAIM_MISMATCH\n'; exit 1 ;;
esac
if [ "${FAKE_DEEP_SLEEP:-0}" = 1 ]; then exec sleep 300; fi
exit 0
DEEP
chmod +x "$DEEP_RUN_BIN"

TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
fail() { echo "FAIL: $*" >&2; exit 1; }
wait_rc() {
  local id="$1"
  for i in $(seq 1 50); do
    [ -f "$MYTHOS_DIR/state/deep/$id.rc" ] && return 0
    sleep 0.1
  done
  return 1
}

# 1. hard 不走 dcq，登記 deep 列，背景跑完 .rc
task="$TMP/task.md"; printf 'task body\n' > "$task"
cwd="$TMP/cwd"; mkdir -p "$cwd"
rm -f "${TMPDIR:-/tmp}/dcq-called"
id="$(bash "$ROOT/bin/dispatch" "$task" "$cwd" hard)"
case "$id" in deep-*) ;; *) fail "id not deep: $id";; esac
[ ! -f "${TMPDIR:-/tmp}/dcq-called" ] || fail 'dcq was called for hard'
grep -q "^$id	hard" "$TSV" || fail 'tsv deep row missing'
wait_rc "$id" || fail 'rc not produced'
[ "$(cat "$MYTHOS_DIR/state/deep/$id.rc")" = 0 ] || fail 'rc not 0'

# 2. rc=0 → watch 送 PASS（狀態仍 pending，未 ACK）；下一輪掃到 ACK 才 notified-PASS
: > "$TMUX_LOG"
FAKE_BUSY=0 bash "$ROOT/bin/dispatch-watch"
grep -q 'send-keys' "$TMUX_LOG" || fail 'no send-keys'
grep -q 'PASS' "$TMUX_LOG" || fail 'no PASS'
grep -q "$id" "$TMUX_LOG" || fail 'no id'
[ "$(cut -f5 "$TSV")" = 'pending' ] || fail "sent but not acked already notified: $(cut -f5 "$TSV")"
FAKE_BUSY=0 bash "$ROOT/bin/dispatch-watch"
[ "$(cut -f5 "$TSV")" = 'notified-PASS' ] || fail "status not notified-PASS: $(cut -f5 "$TSV")"

# 3. rc=1 + CLAIM_MISMATCH → 訊息含 FAIL 與 CLAIM_MISMATCH
task2="$TMP/fail-task.md"; printf 'fail task\n' > "$task2"
id2="$(bash "$ROOT/bin/dispatch" "$task2" "$cwd" hard)"
wait_rc "$id2" || fail 'rc2 not produced'
[ "$(cat "$MYTHOS_DIR/state/deep/$id2.rc")" = 1 ] || fail 'rc2 not 1'
: > "$TMUX_LOG"
FAKE_BUSY=0 bash "$ROOT/bin/dispatch-watch"
grep -q 'FAIL' "$TMUX_LOG" || fail 'no FAIL'
grep -q 'CLAIM_MISMATCH' "$TMUX_LOG" || fail 'no CLAIM_MISMATCH'

# 4. stall：mtime 20 分前 → STALL；立刻再跑不重報
task3="$TMP/sleep-task.md"; printf 'sleep task\n' > "$task3"
export FAKE_DEEP_SLEEP=1
id3="$(bash "$ROOT/bin/dispatch" "$task3" "$cwd" hard)"
unset FAKE_DEEP_SLEEP
# sleeper 的 pid 等 runner 寫進 handle 才記（runner 寫好 deep_pid 就在執行 deep-run 了）
for i in $(seq 1 50); do grep -q '^deep_pid=' "$MYTHOS_DIR/state/deep/$id3.handle" 2>/dev/null && break; sleep 0.1; done
dp3="$(awk -F= '$1=="deep_pid"{print $2}' "$MYTHOS_DIR/state/deep/$id3.handle" 2>/dev/null)"
[ -n "$dp3" ] && PIDS+=("$dp3")
# touch .out and jsonl 20 min ago
python3 - "$MYTHOS_DIR/state/deep/$id3.out" "$CLAUDE_PROJECTS_DIR" "$cwd" <<'PY'
import os,sys,time
out=sys.argv[1]; root=sys.argv[2]; cwd=sys.argv[3]
slug=cwd.replace('/','-').replace('.','-')
d=os.path.join(root,slug); os.makedirs(d,exist_ok=True)
jsonl=os.path.join(d,'x.jsonl'); open(jsonl,'w').write('{}\n')
t=time.time()-1200
for p in (out,jsonl):
    os.utime(p,(t,t))
PY
: > "$TMUX_LOG"
FAKE_BUSY=0 bash "$ROOT/bin/dispatch-watch"
grep -q 'STALL' "$TMUX_LOG" || fail 'no STALL'
: > "$TMUX_LOG"
FAKE_BUSY=0 bash "$ROOT/bin/dispatch-watch"
if grep -q 'send-keys' "$TMUX_LOG"; then fail 'stall re-reported'; fi

# 5. review：jsonl 剛更新、開跑 31 分鐘 → REVIEW 含工具名
old_epoch=$(( $(date +%s) - 1860 ))
id4="deep-${old_epoch}-review-task"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id4" hard "$TMP/review-task.md" "$old_epoch" pending "$cwd" >> "$TSV"
# 在跑的 deep 票有 runner 寫的 handle；沒有會被 F3 的 handoff 逾時收成 failed
printf 'fixture=1\n' > "$MYTHOS_DIR/state/deep/$id4.handle"
printf 'review task\n' > "$TMP/review-task.md"
slug="$(printf '%s' "$cwd" | sed 's/[\/.]/-/g')"
mkdir -p "$CLAUDE_PROJECTS_DIR/$slug"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"FakeTool","input":{"file_path":"/tmp/x"}}]}}\n' > "$CLAUDE_PROJECTS_DIR/$slug/r.jsonl"
: > "$TMUX_LOG"
FAKE_BUSY=0 bash "$ROOT/bin/dispatch-watch"
grep -q 'REVIEW' "$TMUX_LOG" || fail 'no REVIEW'
grep -q 'FakeTool' "$TMUX_LOG" || fail 'no tool name in review'

# 6. pane 忙 → 不送、last-* 不產生
task5="$TMP/busy-task.md"; printf 'busy task\n' > "$task5"
id5="$(bash "$ROOT/bin/dispatch" "$task5" "$cwd" hard)"
wait_rc "$id5" >/dev/null 2>&1 || true
# make stall condition
python3 - "$MYTHOS_DIR/state/deep/$id5.out" "$CLAUDE_PROJECTS_DIR" "$cwd" <<'PY'
import os,sys,time
out=sys.argv[1]; root=sys.argv[2]; cwd=sys.argv[3]
slug=cwd.replace('/','-').replace('.','-')
d=os.path.join(root,slug); os.makedirs(d,exist_ok=True)
jsonl=os.path.join(d,'b.jsonl'); open(jsonl,'w').write('{}\n')
t=time.time()-1200
for p in (out,jsonl):
    os.utime(p,(t,t))
PY
rm -f "$MYTHOS_DIR/state/deep/$id5.last-stall" "$MYTHOS_DIR/state/deep/$id5.last-review"
: > "$TMUX_LOG"
FAKE_BUSY=1 bash "$ROOT/bin/dispatch-watch"
if grep -q 'send-keys' "$TMUX_LOG"; then fail 'busy sent message'; fi
[ ! -f "$MYTHOS_DIR/state/deep/$id5.last-stall" ] || fail 'last-stall created while busy'
[ ! -f "$MYTHOS_DIR/state/deep/$id5.last-review" ] || fail 'last-review created while busy'

# 7. dispatch-retry 產生新工單含追加指示；第 4 次 exit 1
rtask="$TMP/$RETRY_PREFIX.md"; printf 'retry body\n' > "$rtask"
rid="$(bash "$ROOT/bin/dispatch" "$rtask" "$cwd" hard)"
wait_rc "$rid" || fail 'retry rc not produced'
# first retry
newid="$(bash "$ROOT/bin/dispatch-retry" "$rid" "補充指示文字")"
RETRY_FILE="/tmp/dc-worker/${RETRY_PREFIX}-r1.md"
RETRY_FILES+=("$RETRY_FILE")
grep -q '## 追加指示（第 1 次重派' "$RETRY_FILE" || fail 'retry file missing header'
grep -q '補充指示文字' "$RETRY_FILE" || fail 'retry file missing extra'
# trigger 4th rejection
set +e
bash "$ROOT/bin/dispatch-retry" "$rid" "a" >/dev/null 2>&1
bash "$ROOT/bin/dispatch-retry" "$rid" "b" >/dev/null 2>&1
bash "$ROOT/bin/dispatch-retry" "$rid" "c" >/dev/null 2>&1
bash "$ROOT/bin/dispatch-retry" "$rid" "d" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "4th retry expected exit 1 got $rc"

# 8. dispatch-cancel 寫 rc=130、tsv cancelled；非 deep 拒絕
ctask="$TMP/cancel-task.md"; printf 'cancel body\n' > "$ctask"
export FAKE_DEEP_SLEEP=1
cid="$(bash "$ROOT/bin/dispatch" "$ctask" "$cwd" hard)"
unset FAKE_DEEP_SLEEP
for i in $(seq 1 50); do grep -q '^deep_pid=' "$MYTHOS_DIR/state/deep/$cid.handle" 2>/dev/null && break; sleep 0.1; done
dpc="$(awk -F= '$1=="deep_pid"{print $2}' "$MYTHOS_DIR/state/deep/$cid.handle" 2>/dev/null)"
[ -n "$dpc" ] && PIDS+=("$dpc")
bash "$ROOT/bin/dispatch-cancel" "$cid"
[ "$(cat "$MYTHOS_DIR/state/deep/$cid.rc")" = 130 ] || fail 'cancel rc not 130'
# find row status
cstatus="$(awk -F'\t' -v id="$cid" '$1==id{print $5}' "$TSV")"
[ "$cstatus" = 'cancelled' ] || fail "cancel status not cancelled: $cstatus"
set +e
bash "$ROOT/bin/dispatch-cancel" "mid-1-x" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "non-deep cancel expected exit 1 got $rc"


echo PASS

# 預設 transcript 目錄＝deepclaude 自己的 config（不是 ~/.claude/projects）
grep -q 'CLAUDE_PROJECTS_DIR:-$HOME/.deepclaude/config/projects' "$(dirname "$0")/../bin/dispatch-watch" || { echo "FAIL default projects dir"; exit 1; }
echo PASS-default-dir
