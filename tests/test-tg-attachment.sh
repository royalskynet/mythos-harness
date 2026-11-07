#!/usr/bin/env bash
# A2（11-07）：channel 通知帶 attachment_file_id → proxy 自己向子行程呼叫 download_attachment，把路徑寫進訊息。
# 三案：成功 → 含 [附件已存 <路徑>]，且 tgproxy-dl- 回應不外流；逾時 → [附件下載失敗；無附件 → 原樣轉發。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tg-attach.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export MYTHOS_DIR="$TMP/m"
mkdir -p "$MYTHOS_DIR/state"
printf '{"jsonrpc":"2.0","method":"notifications/claude/channel","params":{"content":"看這份","meta":{"chat_id":"42","message_id":"7","attachment_file_id":"F1","attachment_size":"1000"}}}\n' > "$TMP/att.jsonl"
printf '{"jsonrpc":"2.0","method":"notifications/claude/channel","params":{"content":"一般訊息","meta":{"chat_id":"42","message_id":"8"}}}\n' > "$TMP/plain.jsonl"
# 假 plugin server：先吐 channel 通知；FAKE_MODE=ok 時回應 download_attachment，其他模式不回
cat > "$TMP/child.mjs" <<'JS'
import fs from 'node:fs'
import readline from 'node:readline'
process.stdout.write(fs.readFileSync(process.env.FAKE_IN, 'utf8'))
readline.createInterface({ input: process.stdin }).on('line', l => {
  let m; try { m = JSON.parse(l) } catch { return }
  if (m?.params?.name === 'download_attachment' && process.env.FAKE_MODE === 'ok')
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: m.id, result: { content: [{ type: 'text', text: '/tmp/x/a.docx' }] } }) + '\n')
})
setInterval(() => {}, 1000)
JS
run() { sleep 2 | HOME="$TMP" FAKE_IN="$1" FAKE_MODE="$2" TG_DL_TIMEOUT_MS=300 TG_COMMANDS_CHILD="node $TMP/child.mjs" node "$ROOT/bin/tg-commands.mjs" 2>/dev/null; }

out="$(run "$TMP/att.jsonl" ok)"
c="$(printf '%s\n' "$out" | jq -r 'select(.method=="notifications/claude/channel") | .params.content')"
printf '%s' "$c" | grep -qF '[附件已存 /tmp/x/a.docx]' || fail "成功案沒寫路徑：$out"
[ "$(printf '%s\n' "$out" | jq -r 'select(.method=="notifications/claude/channel") | .params.meta.attachment_path')" = /tmp/x/a.docx ] || fail '成功案 meta.attachment_path 不對'
printf '%s' "$out" | grep -q 'tgproxy-dl-' && fail "tgproxy-dl- 回應外流到 stdout：$out"
echo '(ok) ok'

out="$(run "$TMP/att.jsonl" none)"
printf '%s' "$out" | jq -r .params.content | grep -qF '[附件下載失敗' || fail "逾時案沒標失敗：$out"
echo '(timeout) ok'

out="$(run "$TMP/plain.jsonl" ok)"
[ "$out" = "$(cat "$TMP/plain.jsonl")" ] || fail "無附件應原樣轉發：$out"
echo '(plain) ok'
echo ALL OK
