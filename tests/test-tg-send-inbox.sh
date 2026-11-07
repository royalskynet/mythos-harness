#!/usr/bin/env bash
# WO3f：bin/tg-send 收件匣模式。假 Telegram（本機 HTTP stub），不碰真 API。
#   (a) MYTHOS_DELIVER=hermes → 寫一個 json、含原文、stub 沒被打
#   (b) 沒設模式 → 照舊打 stub、inbox 沒新檔
#   (c) state/deliver-mode=hermes → 進收件匣；MYTHOS_DELIVER=tg 蓋過它 → 打 stub
#   (d) hermes 模式下的 #full → 一律直送、不進收件匣
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tg-send-inbox.XXXXXX")"
spid=''
trap '_r=$?; trap "" EXIT; [ -n "$spid" ] && { kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null || true; }; rm -rf "$TMP"; exit "$_r"' EXIT
export MYTHOS_DIR="$TMP/mythos"
export TELEGRAM_STATE_DIR="$TMP/tg"
export TELEGRAM_BOT_TOKEN=T
export STUB_CALLS="$TMP/stub.calls"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"

cat > "$TMP/stub.mjs" <<'JS'
import http from 'node:http'
import fs from 'node:fs'
const srv = http.createServer((req, res) => {
  req.resume().on('end', () => {
    fs.appendFileSync(process.env.STUB_CALLS, 'hit\n')
    res.setHeader('content-type', 'application/json')
    res.end('{"ok":true,"result":{"message_id":500}}')
  })
}).listen(0, '127.0.0.1', () => fs.writeFileSync(process.argv[2], String(srv.address().port)))
JS
: > "$STUB_CALLS"
node "$TMP/stub.mjs" "$TMP/port" & spid=$!
for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
[ -s "$TMP/port" ] || { echo "FAIL: stub 沒起來" >&2; exit 1; }
export TG_API_BASE="http://127.0.0.1:$(cat "$TMP/port")"

mkdir -p "$TELEGRAM_STATE_DIR"
printf '{"allowFrom":["42"]}\n' > "$TELEGRAM_STATE_DIR/access.json"
INBOX="$MYTHOS_DIR/state/inbox"
calls() { grep -c hit "$STUB_CALLS" || true; }
inbox_n() { ls "$INBOX" 2>/dev/null | grep -c '\.json$' || true; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# (a) hermes 模式 → json
printf '全部做完了，順便提一句細節\n' | MYTHOS_DELIVER=hermes node "$ROOT/bin/tg-send" --thread t-in-1 --job bg-in0001 || fail "(a) tg-send 非零退出"
[ "$(inbox_n)" = 1 ] || fail "(a) inbox 應有 1 個 json：$(ls "$INBOX" 2>/dev/null)"
[ "$(calls)" = 0 ] || fail '(a) hermes 模式不該打 Telegram'
f=$(ls "$INBOX"/*.json)
[ "$(jq -r .thread "$f")" = t-in-1 ] || fail '(a) thread 不對'
[ "$(jq -r .job "$f")" = bg-in0001 ] || fail '(a) job 不對'
case "$(jq -r .text "$f")" in *'全部做完了，順便提一句細節'*) ;; *) fail "(a) 原文沒進 json：$(jq -r .text "$f")" ;; esac
[ "$(jq -r '.ts | type' "$f")" = number ] || fail '(a) ts 應是數字'
if ls "$INBOX"/*.tmp >/dev/null 2>&1; then fail '(a) 留了 .tmp'; fi
echo '(a) ok'

# (b) 沒設模式 → 直送
rm -rf "$INBOX"
printf '直送這則\n' | node "$ROOT/bin/tg-send" --thread t-in-2 --job bg-in0002 >/dev/null || fail '(b) tg-send 非零退出'
[ "$(calls)" = 1 ] || fail "(b) stub 應收到 1 次：$(calls)"
[ "$(inbox_n)" = 0 ] || fail "(b) 不該寫 inbox：$(ls "$INBOX" 2>/dev/null)"
echo '(b) ok'

# (c) deliver-mode 檔 → 收件匣；MYTHOS_DELIVER=tg 蓋過 → 直送
mkdir -p "$MYTHOS_DIR/state"
echo hermes > "$MYTHOS_DIR/state/deliver-mode"
printf '檔案切過去\n' | node "$ROOT/bin/tg-send" --thread t-in-3 --job bg-in0003 >/dev/null || fail '(c) tg-send 非零退出'
[ "$(inbox_n)" = 1 ] || fail '(c) deliver-mode 檔沒生效'
[ "$(calls)" = 1 ] || fail '(c) deliver-mode=hermes 打了 Telegram'
printf '強制直送\n' | MYTHOS_DELIVER=tg node "$ROOT/bin/tg-send" --thread t-in-4 --job bg-in0004 >/dev/null || fail '(c) tg-send 非零退出'
[ "$(calls)" = 2 ] || fail "(c) MYTHOS_DELIVER=tg 沒蓋過檔：$(calls)"
[ "$(inbox_n)" = 1 ] || fail '(c) MYTHOS_DELIVER=tg 還寫了 inbox'
echo '(c) ok'

# (d) hermes 模式 + #full → 直送
printf '#full\n全文內容\n' | MYTHOS_DELIVER=hermes node "$ROOT/bin/tg-send" --thread t-in-5 --job bg-full >/dev/null || fail '(d) tg-send 非零退出'
[ "$(calls)" = 3 ] || fail "(d) #full 沒直送：$(calls)"
[ "$(inbox_n)" = 1 ] || fail '(d) #full 寫進了 inbox'
echo '(d) ok'

echo 'TG-SEND-INBOX PASS'
