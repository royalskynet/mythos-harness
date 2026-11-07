#!/usr/bin/env bash
# 11-08b dsh 差距 #3：延遲。
# (a) hermes worker 結束（rc 落地）後 dispatch-bg 的 subshell 自己觸發一次 dispatch-watch（不用等 launchd 的 120 秒）
# (b) 觸發的 watch 真的能把 PASS 送出去（不用手動跑 watch）
# (c) deliver-mode=hermes（inbox 路徑）：不經 brief-answer 改寫，tg-send 收到原摘要；直送 TG（deliver=tg）仍走 brief 改寫
# (d) 外掛 inbox 輪詢間隔常數 1 秒
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-latency.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export MYTHOS_DIR="$TMP/mythos" MYTHOS_WORKER_DIR="$TMP/worker" DCQ_HOME="$TMP/dcq"
export ROUTER_SLUG="dshgap-latency-$$"
export DISPATCH_BG_HERMES_BIN="$TMP/hermes" CLAUDE_BIN="$TMP/claude"
export FAKE_AGENTS="$TMP/agents.json" FAKE_ID="$TMP/fake-id"
mkdir -p "$MYTHOS_DIR/state/bg" "$MYTHOS_DIR/logs" "$MYTHOS_WORKER_DIR" "$DCQ_HOME"
echo '[]' > "$FAKE_AGENTS"; echo cafe0005-0000-0000-0000-000000000000 > "$FAKE_ID"
printf '#!/bin/sh\n[ "${1:-}" = agents ] && { cat "$FAKE_AGENTS"; exit 0; }\nexit 0\n' > "$CLAUDE_BIN"
# 假 hermes：立刻印摘要、exit 0
cat > "$DISPATCH_BG_HERMES_BIN" <<'STUB'
#!/bin/sh
printf '摘要：SUMMARY-RAW 做完了\n---細節---\nx\n'
STUB
chmod +x "$CLAUDE_BIN" "$DISPATCH_BG_HERMES_BIN"
export TG_LOG="$TMP/tg.log" TG_STDIN="$TMP/tg.stdin" TG_RC="$TMP/tg.rc"
cat > "$TMP/tg-send.cjs" <<'JS'
const fs = require('fs')
fs.appendFileSync(process.env.TG_LOG, process.argv.slice(2).join(' ') + '\n')
let s = ''
process.stdin.on('data', d => s += d).on('end', () => { fs.appendFileSync(process.env.TG_STDIN, s); process.exit(0) })
JS
export TG_SEND_BIN="$TMP/tg-send.cjs"
printf '#!/bin/sh\nexit 0\n' > "$TMP/tmux"; chmod +x "$TMP/tmux"; export TMUX_BIN="$TMP/tmux"
export BRIEF_LOG="$TMP/brief.log"
printf '#!/bin/sh\ncat >/dev/null\necho called >> "$BRIEF_LOG"\necho BRIEFED-OUTPUT\n' > "$TMP/brief"; chmod +x "$TMP/brief"; export BRIEF_BIN="$TMP/brief"
mkdir -p "$TMP/rt"; printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$TMP/rt/router.jsonl"
export MYTHOS_TRANSCRIPT_DIR="$TMP/rt" CLAUDE_PROJECTS_DIR="$TMP/projects" BG_AUTOHEAL=0
export BG_PERM_MIN=100000 BG_STALL_MIN=100000 RESEND_SEC=100000
# 觸發用的 watch：記下「被叫時 rc 檔是否已落地」，再 exec 真的 dispatch-watch
export TRIG_LOG="$TMP/trig.log" REAL_WATCH="$ROOT/bin/dispatch-watch"
cat > "$TMP/watch-wrapper" <<'W'
#!/bin/bash
rcf="$(ls "$MYTHOS_DIR"/state/bg/r-*.result.rc 2>/dev/null | head -1)"
echo "called rc_present=$([ -n "$rcf" ] && echo yes || echo no)" >> "$TRIG_LOG"
exec bash "$REAL_WATCH"
W
chmod +x "$TMP/watch-wrapper"
export DISPATCH_WATCH_BIN="$TMP/watch-wrapper"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"
fail() { echo "FAIL: $*" >&2; exit 1; }
EV="$MYTHOS_DIR/state/events.jsonl"
wait_for() { local n=0; while ! eval "$1" && [ "$n" -lt 150 ]; do sleep 0.1; n=$((n + 1)); done; eval "$1"; }

# (a)(b)(c-hermes)：deliver-mode=hermes
export MYTHOS_DELIVER=hermes
printf 'doing x\n' > "$TMP/p.md"
DISPATCH_BG_WORKER=hermes bash "$ROOT/bin/dispatch-bg" t-lat1 "$TMP/p.md" >"$TMP/id.out" 2>/dev/null </dev/null
id="$(cat "$TMP/id.out")"
wait_for '[ -s "$TRIG_LOG" ]' || fail "(a) worker 結束後沒觸發 dispatch-watch（沒人手動跑 watch）"
grep -q 'rc_present=yes' "$TRIG_LOG" || fail "(a) 觸發時 rc 檔還沒落地：$(cat "$TRIG_LOG")"
echo '(a) ok'
wait_for 'grep -q "\"direct\":\"sent\"" "$EV" 2>/dev/null' || fail "(b) 觸發的 watch 沒把 PASS 送出：$(cat "$EV" 2>/dev/null | cut -c1-300)"
jq -rs --arg i "$id" '.[] | select(.job_id==$i) | .status' "$EV" | grep -q PASS || fail "(b) 事件不是 PASS"
echo '(b) ok'
grep -q 'SUMMARY-RAW' "$TG_STDIN" || fail "(c) inbox 路徑 tg-send 應收到原摘要：$(cat "$TG_STDIN")"
[ ! -s "$BRIEF_LOG" ] || fail "(c) deliver-mode=hermes 不該呼叫 brief-answer：$(cat "$BRIEF_LOG")"

# (c-tg)：直送 TG 仍改寫
: > "$TG_STDIN"; : > "$TRIG_LOG"
export MYTHOS_DELIVER=tg
printf 'doing y\n' > "$TMP/p2.md"
DISPATCH_BG_WORKER=hermes bash "$ROOT/bin/dispatch-bg" t-lat2 "$TMP/p2.md" >"$TMP/id2.out" 2>/dev/null </dev/null
wait_for 'grep -q BRIEFED-OUTPUT "$TG_STDIN"' || fail "(c) 直送 TG 應走 brief 改寫：stdin=$(cat "$TG_STDIN") brief=$(cat "$BRIEF_LOG" 2>/dev/null)"
[ -s "$BRIEF_LOG" ] || fail "(c) 直送 TG 沒呼叫 brief-answer"
echo '(c) ok'

# (d) 外掛輪詢常數
PLUG="${MYTHOS_PLUGIN_INIT:-$HOME/.hermes/profiles/mythos/plugins/mythos-tools/__init__.py}"
[ -f "$PLUG" ] || fail "(d) 找不到外掛 $PLUG"
grep -q 'time.sleep(1)' "$PLUG" && ! grep -q 'time.sleep(5)' "$PLUG" || fail "(d) inbox 輪詢不是 1 秒"
echo '(d) ok'
echo 'DISPATCH-LATENCY PASS'
