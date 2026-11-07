#!/usr/bin/env bash
# bin/dispatch-bg（WO3-v3）Hermes 後端驗收：DISPATCH_BG_WORKER=hermes 起假 hermes（-p mythos-worker -z、stdin 不是 pipe、
# 輸出落地到 result 檔、backend=hermes、pid 檔），未設時不碰 hermes；dispatch-watch 讀 pid 判 hermes 單 PASS。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-bg-hermes.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export MYTHOS_DIR="$TMP/mythos"
export MYTHOS_WORKER_DIR="$TMP/worker"
export ROUTER_SLUG="wo3v3-test-hermes-$$"  # 別跟真的 Router transcript 撞
export DISPATCH_BG_HERMES_BIN="$TMP/hermes"
export HERMES_LOG="$TMP/hermes.log"
export FAKE_AGENTS="$TMP/agents.json"
export FAKE_ID="$TMP/fake-id"
export CLAUDE_BIN="$TMP/claude"
mkdir -p "$MYTHOS_DIR/state" "$MYTHOS_WORKER_DIR"
echo '[]' > "$FAKE_AGENTS"
echo cafe0001-0000-0000-0000-000000000000 > "$FAKE_ID"
cat > "$CLAUDE_BIN" <<'STUB'
#!/bin/sh
[ "${1:-}" = agents ] && { cat "$FAKE_AGENTS"; exit 0; }
printf 'Session started in background.\nid: %s\n' "$(cat "$FAKE_ID")"
STUB
chmod +x "$CLAUDE_BIN"
# 假 hermes：記 argv 與 stdin 型態；等 stdin flag 檔出現才寫輸出（讓呼叫端有時間檢查 stdin）
cat > "$DISPATCH_BG_HERMES_BIN" <<'STUB'
#!/bin/sh
if [ -p /dev/stdin ]; then s=pipe; else s=notpipe; fi
printf 'STDIN=%s\t%s\n' "$s" "$*" >> "$HERMES_LOG"
n=0; while [ ! -f "$HERMES_FLAG" ] && [ "$n" -lt 100 ]; do sleep 0.05; n=$((n + 1)); done
printf '摘要：ok\n---細節---\nx\n'
STUB
chmod +x "$DISPATCH_BG_HERMES_BIN"
export HERMES_FLAG="$TMP/go"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"  # 假 claude／假 triage；hermes stub 已在 sandbox 內，不會被換掉
TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
fail() { echo "FAIL: $*" >&2; exit 1; }
printf 'doing x\n' > "$TMP/p.md"

# (a) hermes 後端
: > "$HERMES_LOG"
id="$(DISPATCH_BG_WORKER=hermes bash "$ROOT/bin/dispatch-bg" t-h "$TMP/p.md")"
case "$id" in bg-*) ;; *) fail "沒印 ledger id：$id" ;; esac
sid="${id#bg-}"
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$HERMES_LOG" ] && break; sleep 0.1; done
call="$(cat "$HERMES_LOG")"
case "$call" in *"STDIN=notpipe"$'\t'"-p mythos-worker -z "*) ;; *) fail "argv 不是 -p mythos-worker -z 或 stdin 是 pipe：$call" ;; esac
[ "$(awk -F'\t' -v i="$id" '$1==i {print $8}' "$TSV")" = hermes ] || fail "backend 不是 hermes：$(cat "$TSV")"
[ -s "$MYTHOS_DIR/state/bg/$sid.pid" ] || fail '沒寫 pid 檔'
rk="$(tr -d '[:space:]' < "$MYTHOS_DIR/state/bg/$sid.rkey")"
rf="$MYTHOS_DIR/state/bg/r-$rk.result"
[ -f "$rf" ] || fail "result 檔不存在：$rf"
touch "$HERMES_FLAG"
for i in 1 2 3 4 5 6 7 8 9 10; do grep -q '^x$' "$rf" 2>/dev/null && break; sleep 0.1; done
grep -q '^摘要：ok$' "$rf" && grep -q '^---細節---$' "$rf" || fail "result 檔沒有假 hermes 輸出：$(cat "$rf")"
pid="$(cat "$MYTHOS_DIR/state/bg/$sid.pid")"
for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
# (watch) pid 已不在、result 有內容 → PASS 投遞（複製既有 watch 測試的 stub 環境）
mkdir -p "$TMP/router-transcript"; printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$TMP/router-transcript/router.jsonl"
export MYTHOS_TRANSCRIPT_DIR="$TMP/router-transcript"
export CLAUDE_PROJECTS_DIR="$TMP/projects"
export BG_AUTOHEAL=0
export TG_LOG="$TMP/tg.log"
cat > "$TMP/tgsend.mjs" <<'TG'
process.stdin.resume(); process.exit(0);
TG
export TG_SEND_BIN="$TMP/tgsend.mjs"
export TMUX_BIN="$TMP/tmux"
cat > "$TMUX_BIN" <<'TMUX'
#!/bin/sh
printf "%s\n" "$*" >> "$TG_LOG"; exit 0
TMUX
chmod +x "$TMUX_BIN"
BG_PERM_MIN=100000 BG_STALL_MIN=100000 RESEND_SEC=100000 bash "$ROOT/bin/dispatch-watch" 9>&- || fail 'watch 非零退出'
[ "$(jq -s --arg i "$id" '[.[] | select(.job_id==$i and .status=="PASS")] | length' "$MYTHOS_DIR/state/events.jsonl")" = 1 ] || fail 'watch 沒給 hermes 單 PASS 事件'
grep -q "direct sent $id-PASS" "$MYTHOS_DIR/logs/dispatch-watch.log" || fail "PASS 沒直發：$(tail -3 "$MYTHOS_DIR/logs/dispatch-watch.log")"
echo '(a) ok'

# (b) 未設定 → 不起 hermes（照舊 claude）
awk -F'\t' 'BEGIN{OFS="\t"} {$5="notified-PASS";print}' "$TSV" > "$TSV.t" && mv "$TSV.t" "$TSV"
: > "$HERMES_LOG"
env -u DISPATCH_BG_WORKER bash "$ROOT/bin/dispatch-bg" t-c "$TMP/p.md" >/dev/null
sleep 0.3
[ ! -s "$HERMES_LOG" ] || fail "未設 DISPATCH_BG_WORKER 也叫了 hermes：$(cat "$HERMES_LOG")"
[ "$(tail -1 "$TSV" | cut -f8)" = bg ] || fail "未設時 backend 應是 bg：$(tail -1 "$TSV")"
echo '(b) ok'
echo 'DISPATCH-BG-HERMES PASS'
