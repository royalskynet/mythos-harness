#!/usr/bin/env bash
# 11-08（G11）：hermes 同時開工上限 MYTHOS_HERMES_SLOTS。滿了 dispatch-bg 不起 worker、不登錄，排進 state/hermes-queue/；
#   dispatch-bg --cancel <thread> 丟掉該 thread 的排隊項；dispatch-watch 有空位時照檔名 FIFO 叫 DISPATCH_BG_BIN。
# 全程在 mktemp 沙箱：不碰真的 ~/.hermes、不打 TG。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hermes-slots.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export MYTHOS_DIR="$TMP/mythos"
export BRIEF_LINES_DIR="$TMP/brief"
export DCQ_HOME="$TMP/dcq"
export MYTHOS_WORKER_DIR="$TMP/worker"
export MYTHOS_WORKER_DB="$TMP/no-such-state.db"   # worker-latency 不讀真的 ~/.hermes 庫
export MYTHOS_TRANSCRIPT_DIR="$TMP/rt"
export CLAUDE_PROJECTS_DIR="$TMP/projects"
export CLAUDE_BIN="$TMP/claude"
export DISPATCH_BG_HERMES_BIN="$TMP/hermes"
export DISPATCH_BG_BIN="$TMP/bg-stub"
export TG_SEND_BIN="$TMP/tg-stub"
export TG_LOG="$TMP/tg.log"
export BG_AUTOHEAL=0
export CTX_GUARD_OFF=1
export MYTHOS_HERMES_SLOTS=1
mkdir -p "$MYTHOS_DIR/state/bg" "$MYTHOS_DIR/logs" "$DCQ_HOME" "$MYTHOS_WORKER_DIR" "$MYTHOS_TRANSCRIPT_DIR" "$CLAUDE_PROJECTS_DIR"
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$MYTHOS_TRANSCRIPT_DIR/router.jsonl"
printf '#!/bin/sh\nexit 0\n' > "$CLAUDE_BIN"; chmod +x "$CLAUDE_BIN"
printf '#!/bin/sh\nexit 0\n' > "$DISPATCH_BG_HERMES_BIN"; chmod +x "$DISPATCH_BG_HERMES_BIN"
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$TMP/bg-calls.log" > "$DISPATCH_BG_BIN"; chmod +x "$DISPATCH_BG_BIN"
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$TG_LOG" > "$TG_SEND_BIN"; chmod +x "$TG_SEND_BIN"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"

TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
QD="$MYTHOS_DIR/state/hermes-queue"
BG_CALLS="$TMP/bg-calls.log"
fail() { echo "FAIL: $*" >&2; exit 1; }
rows() { wc -l < "$TSV" | tr -d ' '; }
qcount() { ls -1 "$QD" 2>/dev/null | wc -l | tr -d ' '; }
watch() { DW_DEADLINE_ARMED=1 bash "$ROOT/bin/dispatch-watch" 9>&- >/dev/null 2>>"$TMP/dw.err" || fail 'dispatch-watch 非零退出'; }

# 已占滿一個 slot 的 hermes 列（pending）
P="$MYTHOS_DIR/state/bg/t-demo.md"
printf 'thread=t-demo\n查一下 A 服務\n' > "$P"
printf 'bg-slot0001\tmid\t%s\t%s\tpending\t%s\tt-demo\thermes\n' "$P" "$(date +%s)" "$TMP/w" >> "$TSV"

# 1) 滿了 → 排隊：stdout 含 queued-、佇列多一檔、ledger 列數不變
Q1="$MYTHOS_DIR/state/bg/t-q.md"
printf 'thread=t-q\n排隊測試\n' > "$Q1"
r0="$(rows)"; q0="$(qcount)"
out="$(DISPATCH_BG_WORKER=hermes bash "$ROOT/bin/dispatch-bg" t-q "$Q1" 2>"$TMP/bg1.err")" || fail "排隊那次 dispatch-bg 非零：$(cat "$TMP/bg1.err")"
printf '%s' "$out" | grep -q 'queued-' || fail "stdout 不含 queued-：$out"
[ "$(qcount)" = "$((q0 + 1))" ] || fail "hermes-queue 沒多一個檔（$(qcount)）"
[ "$(rows)" = "$r0" ] || fail "ledger 列數變了（$r0 → $(rows)）：排隊不該登錄"
QF="$QD/$(ls -1 "$QD" | head -1)"
awk -F'\t' '$1=="t-q"{f=1} END{exit !f}' "$QF" || fail "排隊檔內容不含 thread t-q"

# 2) --cancel <thread> → 該 thread 的排隊檔消失，ledger 不動
DISPATCH_BG_WORKER=hermes bash "$ROOT/bin/dispatch-bg" --cancel t-q >"$TMP/cancel1.out" 2>&1 || fail "cancel 非零：$(cat "$TMP/cancel1.out")"
[ "$(qcount)" = "$q0" ] || fail "cancel 後排隊檔沒消失（$(qcount)）"
grep -q '已丟掉排隊項' "$TMP/cancel1.out" || fail "cancel 沒回報丟掉排隊項：$(cat "$TMP/cancel1.out")"
[ "$(rows)" = "$r0" ] || fail "cancel 動到 ledger"

# 3) 再排一項；原 pending 列改成非 pending（worker 收尾，有空位）→ dispatch-watch 照 FIFO 叫 DISPATCH_BG_BIN，排隊檔被刪
Q2="$MYTHOS_DIR/state/bg/t-r.md"
printf 'thread=t-r\n第二項\n' > "$Q2"
out2="$(DISPATCH_BG_WORKER=hermes bash "$ROOT/bin/dispatch-bg" t-r "$Q2" 2>/dev/null)" || fail "第二項排隊時 dispatch-bg 非零"
printf '%s' "$out2" | grep -q 'queued-' || fail "第二項 stdout 不含 queued-：$out2"
[ "$(qcount)" = 1 ] || fail "第二項沒排進佇列（$(qcount)）"
awk -F'\t' 'BEGIN{OFS="\t"} $1=="bg-slot0001"{$5="done"} {print}' "$TSV" > "$TMP/tsv.new" && mv "$TMP/tsv.new" "$TSV"
watch
grep -q -- '--thread t-r' "$BG_CALLS" 2>/dev/null || fail "DISPATCH_BG_BIN 沒被叫（stub 呼叫紀錄：$(cat "$BG_CALLS" 2>/dev/null)）"
[ "$(qcount)" = 0 ] || fail "派出後排隊檔沒刪（$(qcount)）"

echo 'SLOTS_OK'
