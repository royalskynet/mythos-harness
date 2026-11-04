#!/usr/bin/env bash
# E3：bin/tg-plugin-patch 只對 fixture 副本測——插入一次、重跑冪等、錨點缺失／重複 exit 3 且 bytes 不變。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tg-patch.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
P="$ROOT/bin/tg-plugin-patch"
F="$TMP/server.ts"
cat > "$F" <<'TS'
  mcp.notification({
    method: 'notifications/claude/channel',
    params: {
      content: text,
      meta: {
        chat_id,
        ...(msgId != null ? { message_id: String(msgId) } : {}),
        user: from.username ?? String(from.id),
      },
    },
  })
TS
cp "$F" "$TMP/orig.ts"

out="$(node "$P" "$F")" || fail "首次 patch 非零：$out"
[ "$(grep -c 'mythos-patch:reply_to' "$F")" = 1 ] || fail '沒插入 marker'
grep -A1 -F 'message_id: String(msgId)' "$F" | tail -1 | grep -q '^        \.\.\.(ctx\.message?\.reply_to_message?\.message_id != null ? { reply_to_message_id:' || fail '插入位置或縮排不對'
cmp -s "$F.mythos-orig" "$TMP/orig.ts" || fail '.mythos-orig 不是原檔'
[ $(wc -l < "$F") -eq $(( $(wc -l < "$TMP/orig.ts") + 1 )) ] || fail '不是只多一行'
ls "$TMP" | grep -q 'mythos-tmp' && fail '暫存檔殘留'

cp "$F" "$TMP/once.ts"
out="$(node "$P" "$F")" || fail "重跑非零：$out"
[ "$out" = already ] || fail "重跑應印 already：$out"
cmp -s "$F" "$TMP/once.ts" || fail '重跑改了檔案'

# 錨點缺失
grep -v -F 'message_id: String(msgId)' "$TMP/orig.ts" > "$TMP/none.ts"; cp "$TMP/none.ts" "$TMP/none.bak"
set +e; node "$P" "$TMP/none.ts" 2>/dev/null; rc=$?; set -e
[ "$rc" = 3 ] || fail "錨點缺失應 exit 3：$rc"
cmp -s "$TMP/none.ts" "$TMP/none.bak" || fail '錨點缺失時動了檔案'
[ ! -e "$TMP/none.ts.mythos-orig" ] || fail '錨點缺失還留了 .mythos-orig'

# 錨點重複
{ cat "$TMP/orig.ts"; cat "$TMP/orig.ts"; } > "$TMP/dup.ts"; cp "$TMP/dup.ts" "$TMP/dup.bak"
set +e; node "$P" "$TMP/dup.ts" 2>/dev/null; rc=$?; set -e
[ "$rc" = 3 ] || fail "錨點重複應 exit 3：$rc"
cmp -s "$TMP/dup.ts" "$TMP/dup.bak" || fail '錨點重複時動了檔案'

echo 'TG-PLUGIN-PATCH PASS'
