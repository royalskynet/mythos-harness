#!/usr/bin/env bash
# 秒回（11-07）：tg-commands.mjs 收到使用者訊息 → 每 TG_TYPING_MS 補送 typing，Router reply 後停；
# Router 忙（TG_BUSY_FILE 在）→ 先回「收到，等等處理」；閒 → 不回；斜線指令不觸發 typing。
# Bot API 全走 TG_API_STUB（不連網），忙碌狀態走 TG_BUSY_FILE（不讀真 pane）。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tg-snappy.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export MYTHOS_DIR="$TMP/m"
mkdir -p "$MYTHOS_DIR/state" "$TMP/bots/mythos/logs"
n() { printf '{"jsonrpc":"2.0","method":"notifications/claude/channel","params":{"content":"%s","meta":{"chat_id":"%s","message_id":"5"}}}\n' "$1" "$2"; }
cat > "$TMP/child.mjs" <<'JS'
import fs from 'node:fs'
process.stdout.write(fs.readFileSync(process.env.FAKE_IN, 'utf8'))
process.stdin.on('data', d => fs.appendFileSync(process.env.CHILD_IN, d))
setInterval(() => {}, 1000)
JS
REPLY='{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"reply","arguments":{"chat_id":"42","text":"好"}}}'
# $1＝送 reply 前等幾秒；$2＝送完再等幾秒
run() {
  : > "$TMP/api.log"; : > "$TMP/child.in"
  { sleep "$1"; printf '%s\n' "$REPLY"; sleep "$2"; } |
    HOME="$TMP" TG_API_STUB="$TMP/api.log" TG_BUSY_FILE="$TMP/busy" TG_TYPING_MS=300 CHILD_IN="$TMP/child.in" \
      FAKE_IN="$TMP/in.jsonl" TG_COMMANDS_CHILD="node $TMP/child.mjs" node "$ROOT/bin/tg-commands.mjs" > "$TMP/out.jsonl" 2>/dev/null
}
typing() { grep -c '^sendChatAction .*"typing"' "$TMP/api.log" || true; }

# 1. 忙碌：先回一句＋typing 持續到 reply，reply 後停
n '幫我查一下' 42 > "$TMP/in.jsonl"
: > "$TMP/busy"
run 1.2 1.8
grep -q '^sendMessage {"chat_id":"42","text":"收到，等等處理"}' "$TMP/api.log" || fail "忙碌沒先回：$(cat "$TMP/api.log")"
t=$(typing)
[ "$t" -ge 3 ] && [ "$t" -le 6 ] || fail "typing 次數不對（應在 reply 前補送、reply 後停）：$t"
cmp -s <(printf '%s\n' "$REPLY") "$TMP/child.in" || fail "reply 沒原樣轉給 plugin：$(cat "$TMP/child.in")"
[ "$(cat "$TMP/out.jsonl")" = "$(cat "$TMP/in.jsonl")" ] || fail '使用者訊息沒原樣轉給 Router'
echo '(busy) ok'

# 2. 閒置：不回「收到」，pane 一直閒 → typing 自己停
rm -f "$TMP/busy"
run 2.5 0.2
grep -q '收到，等等處理' "$TMP/api.log" && fail '閒置不該回收到'
t=$(typing)
[ "$t" -ge 1 ] && [ "$t" -le 4 ] || fail "閒置 typing 應很快自停：$t"
echo '(idle) ok'

# 3. 斜線指令（proxy 自己吃掉）不觸發 typing
n '/ping' 42 > "$TMP/in.jsonl"
: > "$TMP/busy"
run 0.8 0.2
[ "$(typing)" = 0 ] || fail "斜線指令不該 typing：$(cat "$TMP/api.log")"
echo '(slash) ok'
echo 'TG-SNAPPY PASS'
