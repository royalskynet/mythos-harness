#!/usr/bin/env bash
# 11-07「haiku 只做勝任的事」驗收：
#   1. bin/plan-ticket：用法錯 exit 2；規劃單第一行 then-run 標記、要求寫工單、驗收查執行單；轉交 bin/dispatch 帶同 tier／cwd
#   2. dispatch-watch：規劃單（dcq）PASS → 零 token 自動派執行單（同 thread／cwd／tier），事件寫「自動派出執行單」；
#      沒標記的單不派；派不出去寫原因
#   3. dispatch-bg：本機 triage 判的 tier 寫在 thread 行之後；triage 不在當 mid
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/plan-ticket-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export MYTHOS_DIR="$TMP/mythos" DCQ_HOME="$TMP/dcq" TMUX_BIN="$TMP/tmux" MYTHOS_TRANSCRIPT_DIR="$TMP/rt"
export DISPATCH_BIN="$TMP/dispatch-stub" CLAUDE_BIN="$TMP/claude" MYTHOS_WORKER_DIR="$TMP/worker"
mkdir -p "$MYTHOS_DIR/state" "$DCQ_HOME"/{done,failed,running,pending} "$MYTHOS_TRANSCRIPT_DIR" "$TMP/repo" "$MYTHOS_WORKER_DIR"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/tmux.log"\nexit 0\n' "$TMP" > "$TMUX_BIN"
cat > "$DISPATCH_BIN" <<STUB
#!/bin/sh
printf '%s|%s|%s|%s\n' "\${DISPATCH_THREAD:-}" "\$1" "\$2" "\$3" >> "$TMP/dispatch.log"
[ -f "$TMP/dispatch-fail" ] && { echo "lint 爆了" >&2; exit 1; }
echo job-run-1
STUB
chmod +x "$TMUX_BIN" "$DISPATCH_BIN"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"

# 1) plan-ticket
set +e
echo x | bash "$ROOT/bin/plan-ticket" easy "$TMP/repo" >/dev/null 2>&1; [ $? = 2 ] || fail "easy 應 exit 2"
echo x | bash "$ROOT/bin/plan-ticket" mid rel/path >/dev/null 2>&1; [ $? = 2 ] || fail "相對 cwd 應 exit 2"
printf '' | bash "$ROOT/bin/plan-ticket" mid "$TMP/repo" >/dev/null 2>&1; [ $? = 2 ] || fail "空目標應 exit 2"
set -e
out="$(echo '修好 foo 的登入 bug' | DISPATCH_THREAD=t-p PLAN_TICKET_DISPATCH="$DISPATCH_BIN" bash "$ROOT/bin/plan-ticket" hard "$TMP/repo")"
[ "$out" = job-run-1 ] || fail "應印 dispatch 回的 id：$out"
plan="$(ls "$MYTHOS_DIR"/state/workorders/plan-*.md)"
run="$(sed -n '1s/^<!-- mythos:then-run \(.*\) -->$/\1/p' "$plan")"
case "$run" in "$MYTHOS_DIR"/state/workorders/run-*.md) ;; *) fail "第一行要是 then-run 標記：$(head -1 "$plan")" ;; esac
grep -q '修好 foo 的登入 bug' "$plan" || fail "目標沒寫進規劃單"
grep -q "test -s '$run'" "$plan" || fail "驗收要查執行單存在"
[ "$(cat "$TMP/dispatch.log")" = "t-p|$plan|$TMP/repo|hard" ] || fail "轉交 dispatch 參數不對：$(cat "$TMP/dispatch.log")"
if command -v deep-lint >/dev/null; then deep-lint "$plan" >/dev/null 2>&1 || fail "規劃單過不了 deep-lint"; fi
echo '(1) ok'

# 2) dispatch-watch 規劃單 PASS → 自動派執行單
: > "$TMP/dispatch.log"
TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
printf 'job-plan-1\thard\t%s\t%s\tpending\t%s\tt-p\tdcq\n' "$plan" "$(date +%s)" "$TMP/repo" > "$TSV"
: > "$DCQ_HOME/done/job-plan-1.job"
bash "$ROOT/bin/dispatch-watch" >/dev/null 2>&1 || true
[ "$(cat "$TMP/dispatch.log")" = "t-p|$run|$TMP/repo|hard" ] || fail "應自動派執行單：$(cat "$TMP/dispatch.log")"
grep -q '自動派出執行單 job-run-1' "$MYTHOS_DIR/state/events.jsonl" || fail "事件沒寫自動派出：$(cat "$MYTHOS_DIR/state/events.jsonl")"
# 沒標記的一般 dcq PASS 不派
: > "$TMP/dispatch.log"; printf '# 一般工單\n' > "$TMP/plain.md"
printf 'job-plain-1\tmid\t%s\t%s\tpending\t%s\tt-q\tdcq\n' "$TMP/plain.md" "$(date +%s)" "$TMP/repo" >> "$TSV"
: > "$DCQ_HOME/done/job-plain-1.job"
bash "$ROOT/bin/dispatch-watch" >/dev/null 2>&1 || true
[ ! -s "$TMP/dispatch.log" ] || fail "沒標記的單不該派：$(cat "$TMP/dispatch.log")"
# 派不出去 → 事件寫原因
: > "$TMP/dispatch-fail"; cp "$plan" "$TMP/plan2.md"
printf 'job-plan-2\tmid\t%s\t%s\tpending\t%s\tt-r\tdcq\n' "$TMP/plan2.md" "$(date +%s)" "$TMP/repo" >> "$TSV"
: > "$DCQ_HOME/done/job-plan-2.job"
bash "$ROOT/bin/dispatch-watch" >/dev/null 2>&1 || true
grep -q '執行單派不出去：lint 爆了' "$MYTHOS_DIR/state/events.jsonl" || fail "派不出去要寫原因"
rm -f "$TMP/dispatch-fail"
echo '(2) ok'

# 3) dispatch-bg 寫 tier 行（thread 行之後）
cat > "$CLAUDE_BIN" <<STUB
#!/bin/sh
[ "\$1" = agents ] && { echo '[]'; exit 0; }
for a; do last="\$a"; done; printf '%s' "\$last" > "$TMP/body.txt"
echo 'backgrounded · abcd1234 · x'
STUB
printf '#!/bin/sh\necho hard\n' > "$TMP/triage"; chmod +x "$CLAUDE_BIN" "$TMP/triage"
printf 'thread=t-b\n幫我重構 X\n' > "$TMP/p.md"
DISPATCH_GATE_TRIAGE="$TMP/triage" DISPATCH_BG_NODEDUP=1 bash "$ROOT/bin/dispatch-bg" t-b "$TMP/p.md" >/dev/null
[ "$(sed -n 1p "$TMP/body.txt")" = thread=t-b ] || fail "第一行要留 thread=：$(head -2 "$TMP/body.txt")"
sed -n 2p "$TMP/body.txt" | grep -q '^tier=hard' || fail "第二行要是 tier=hard：$(head -2 "$TMP/body.txt")"
DISPATCH_GATE_TRIAGE="$TMP/nope" DISPATCH_BG_NODEDUP=1 bash "$ROOT/bin/dispatch-bg" t-c "$TMP/p.md" >/dev/null
sed -n 2p "$TMP/body.txt" | grep -q '^tier=mid' || fail "triage 不在要當 mid：$(head -2 "$TMP/body.txt")"
echo '(3) ok'
echo "PLAN-TICKET PASS"
