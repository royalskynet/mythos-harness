#!/usr/bin/env bash
# E3：tg-commands.mjs 的回覆標註。假子行程（TG_COMMANDS_CHILD）灌 channel 通知，看 proxy 轉出什麼：
#   命中而且是該 thread 最新 job → 加標註；同 thread 已有更新的 job → 不標註；chat 不同 → 不標註；沒有 reply_to → bytes 相同
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tg-reply.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export MYTHOS_DIR="$TMP/m"
mkdir -p "$MYTHOS_DIR/state"
T=$(printf '\t')
printf '42\t900\tt-a\tbg-a1\t1\n42\t901\tt-b\tbg-b1\t1\n' > "$MYTHOS_DIR/state/tg-msg-thread.tsv"
for r in "bg-a1 t-a bg" "bg-b1 t-b bg" "bg-x9 t-x bg" "bg-b2 t-b bg-hard"; do
  set -- $r
  printf '%s\tmid\tp.md\t1\tnotified-PASS\t/w\t%s\t%s\n' "$1" "$2" "$3" >> "$MYTHOS_DIR/state/dispatch-jobs.tsv"
done
n() { printf '{"jsonrpc":"2.0","method":"notifications/claude/channel","params":{"content":"%s","meta":{"chat_id":"%s"%s,"message_id":"5"}}}\n' "$1" "$2" "$3"; }
{
  n '再改一下' 42 ',"reply_to_message_id":"900"'
  n '舊的那則' 42 ',"reply_to_message_id":"901"'
  n '別的聊天室' 43 ',"reply_to_message_id":"900"'
  n '一般訊息' 42 ''
} > "$TMP/in.jsonl"
cat > "$TMP/child.mjs" <<'JS'
import fs from 'node:fs'
process.stdout.write(fs.readFileSync(process.env.FAKE_IN, 'utf8'))
setInterval(() => {}, 1000)
JS
out="$(sleep 1 | HOME="$TMP" FAKE_IN="$TMP/in.jsonl" TG_COMMANDS_CHILD="node $TMP/child.mjs" node "$ROOT/bin/tg-commands.mjs" 2>/dev/null)"
printf '%s\n' "$out" > "$TMP/out.jsonl"
[ "$(grep -c . "$TMP/out.jsonl")" = 4 ] || fail "應轉出 4 行：$(cat "$TMP/out.jsonl")"
c1="$(sed -n 1p "$TMP/out.jsonl" | jq -r .params.content)"
[ "$c1" = '[回覆 bg thread=t-a job=bg-a1] 再改一下' ] || fail "命中最新 job 沒標註：$c1"
[ "$(sed -n 1p "$TMP/out.jsonl" | jq -r .params.meta.reply_to_message_id)" = 900 ] || fail 'meta 被弄丟'
for i in 2 3 4; do
  [ "$(sed -n ${i}p "$TMP/out.jsonl")" = "$(sed -n ${i}p "$TMP/in.jsonl")" ] || fail "第 $i 則應原樣轉發：$(sed -n ${i}p "$TMP/out.jsonl")"
done
# 對照表讀不到 → 原樣
rm "$MYTHOS_DIR/state/tg-msg-thread.tsv"
out="$(sleep 1 | HOME="$TMP" FAKE_IN="$TMP/in.jsonl" TG_COMMANDS_CHILD="node $TMP/child.mjs" node "$ROOT/bin/tg-commands.mjs" 2>/dev/null)"
[ "$out" = "$(cat "$TMP/in.jsonl")" ] || fail '對照表不在時沒原樣轉發'
echo 'TG-REPLY-THREAD PASS'
