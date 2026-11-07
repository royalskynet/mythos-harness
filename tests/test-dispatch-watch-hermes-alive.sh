#!/usr/bin/env bash
# 11-08 audit#1：hermes worker 活著（state/bg/<sid>.pid 的 pid 存活）時，dispatch-watch 必須維持 working，
# 不可被 claude 專用的 bg_idle／bg_pid 補救分支覆寫成 stopped → FAIL。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/watch-hermes-alive.XXXXXX")"
trap 'kill "${hpid:-0}" 2>/dev/null || true; pkill -P "${hpid:-0}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
export MYTHOS_DIR="$TMP/mythos" MYTHOS_WORKER_DIR="$TMP/worker"
export DCQ_HOME="$TMP/dcq"; mkdir -p "$DCQ_HOME"
export ROUTER_SLUG="wo-audit1108-alive-$$"
export DISPATCH_BG_HERMES_BIN="$TMP/hermes" CLAUDE_BIN="$TMP/claude"
export FAKE_AGENTS="$TMP/agents.json" FAKE_ID="$TMP/fake-id"
mkdir -p "$MYTHOS_DIR/state" "$MYTHOS_WORKER_DIR"
echo '[]' > "$FAKE_AGENTS"; echo cafe0002-0000-0000-0000-000000000000 > "$FAKE_ID"
printf '#!/bin/sh\n[ "${1:-}" = agents ] && { cat "$FAKE_AGENTS"; exit 0; }\nexit 0\n' > "$CLAUDE_BIN"
printf '#!/bin/sh\nsleep 60\n' > "$DISPATCH_BG_HERMES_BIN"
chmod +x "$CLAUDE_BIN" "$DISPATCH_BG_HERMES_BIN"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"
fail() { echo "FAIL: $*" >&2; exit 1; }
printf 'doing x\n' > "$TMP/p.md"
# 輸出寫檔不用 $()：背景 worker 會握著管道，$() 會等它結束
DISPATCH_BG_WORKER=hermes bash "$ROOT/bin/dispatch-bg" t-alive "$TMP/p.md" >"$TMP/id.out" 2>/dev/null </dev/null
id="$(cat "$TMP/id.out")"
sid="${id#bg-}"
hpid="$(tr -d '[:space:]' < "$MYTHOS_DIR/state/bg/$sid.pid")"
kill -0 "$hpid" || fail "hermes stub 沒活著"
mkdir -p "$TMP/rt"; printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$TMP/rt/router.jsonl"
export MYTHOS_TRANSCRIPT_DIR="$TMP/rt" CLAUDE_PROJECTS_DIR="$TMP/projects" BG_AUTOHEAL=0 TG_LOG="$TMP/tg.log"
echo 'process.stdin.resume(); process.exit(0);' > "$TMP/tgsend.mjs"; export TG_SEND_BIN="$TMP/tgsend.mjs"
printf '#!/bin/sh\nexit 0\n' > "$TMP/tmux"; chmod +x "$TMP/tmux"; export TMUX_BIN="$TMP/tmux"
BG_PERM_MIN=100000 BG_STALL_MIN=100000 RESEND_SEC=100000 bash "$ROOT/bin/dispatch-watch" 9>&- || fail 'watch 非零退出'
ev="$MYTHOS_DIR/state/events.jsonl"
if [ -s "$ev" ] && grep -q "$id" "$ev"; then fail "活著的 hermes worker 被判終態，事件：$(head -1 "$ev" | cut -c1-300)"; fi
[ "$(awk -F'\t' -v i="$id" '$1==i {print $5}' "$MYTHOS_DIR/state/dispatch-jobs.tsv")" = pending ] || fail "ledger 不再是 pending：$(cat "$MYTHOS_DIR/state/dispatch-jobs.tsv")"
echo 'WATCH-HERMES-ALIVE PASS'
