#!/usr/bin/env bash
# 11-08 audit#2：Router 預設 DISPATCH_BG_WORKER=hermes，ledger 第 8 欄寫 hermes。
# 同 thread 已有 pending 的 hermes 單時：第二次派同 thread 必須排信箱、不起第二個 worker；帶 eid 重送同 prompt 也不重起。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-bg-hermes-dedupe.XXXXXX")"
trap 'for p in $(cat "$MYTHOS_DIR"/state/bg/*.pid 2>/dev/null); do kill "$p" 2>/dev/null || true; done; pkill -f "$TMP/hermes" 2>/dev/null || true; rm -rf "$TMP"' EXIT
export MYTHOS_DIR="$TMP/mythos" MYTHOS_WORKER_DIR="$TMP/worker" DCQ_HOME="$TMP/dcq"
export ROUTER_SLUG="wo-audit1108-dedupe-$$"
export DISPATCH_BG_HERMES_BIN="$TMP/hermes" CLAUDE_BIN="$TMP/claude" HERMES_LOG="$TMP/hermes.log"
export FAKE_AGENTS="$TMP/agents.json" FAKE_ID="$TMP/fake-id"
mkdir -p "$MYTHOS_DIR/state" "$MYTHOS_WORKER_DIR" "$DCQ_HOME"
echo '[]' > "$FAKE_AGENTS"; echo cafe0003-0000-0000-0000-000000000000 > "$FAKE_ID"
printf '#!/bin/sh\n[ "${1:-}" = agents ] && { cat "$FAKE_AGENTS"; exit 0; }\nexit 0\n' > "$CLAUDE_BIN"
printf '#!/bin/sh\nprintf "call\\n" >> "$HERMES_LOG"\nsleep 30\n' > "$DISPATCH_BG_HERMES_BIN"
chmod +x "$CLAUDE_BIN" "$DISPATCH_BG_HERMES_BIN"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"
fail() { echo "FAIL: $*" >&2; exit 1; }
cnt() { wc -l < "$1" | tr -d " "; }
TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
export DISPATCH_BG_WORKER=hermes
printf 'job one\n' > "$TMP/p1.md"; printf 'job two\n' > "$TMP/p2.md"
# 輸出寫檔不用 $()：背景 worker 會握著管道
bash "$ROOT/bin/dispatch-bg" t-dd "$TMP/p1.md" >"$TMP/o1" 2>/dev/null </dev/null
id1="$(cat "$TMP/o1")"
[ "$(cut -f8 "$TSV" | tail -1)" = hermes ] || fail "第 8 欄不是 hermes：$(cat "$TSV")"
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$HERMES_LOG" ] && break; sleep 0.1; done
[ "$(cnt "$HERMES_LOG")" = 1 ] || fail "第一次應起 1 個 worker"
# 第二次同 thread：排信箱
bash "$ROOT/bin/dispatch-bg" t-dd "$TMP/p2.md" >"$TMP/o2" 2>"$TMP/e2" </dev/null || fail "第二次非零退出：$(cat "$TMP/e2")"
sleep 0.5
[ "$(cat "$TMP/o2")" = "$id1" ] || fail "第二次應回原 job id ${id1}，實得：$(cat "$TMP/o2")"
[ "$(cnt "$HERMES_LOG")" = 1 ] || fail "第二次又起了 worker（hermes 呼叫 $(cnt "$HERMES_LOG") 次）"
[ "$(cnt "$TSV")" = 1 ] || fail "ledger 多了一列：$(cat "$TSV")"
ls "$MYTHOS_DIR/state/mailbox/t-dd/"*.md >/dev/null 2>&1 || fail "信箱沒有訊息"
# eid 重送同 prompt：回原 id、不重起
DISPATCH_BG_EID=e-dd1 bash "$ROOT/bin/dispatch-bg" t-dd "$TMP/p1.md" >"$TMP/o3" 2>/dev/null </dev/null
[ "$(cat "$TMP/o3")" = "$id1" ] || fail "eid 重送應回原 id，實得：$(cat "$TMP/o3")"
[ "$(cnt "$HERMES_LOG")" = 1 ] || fail "eid 重送又起了 worker"
echo 'DISPATCH-BG-HERMES-DEDUPE PASS'
