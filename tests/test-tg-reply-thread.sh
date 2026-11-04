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
printf '42\t900\tt-a\tbg-a1\t1\n42\t901\tt-b\tbg-b1\t1\n' > "$MYTHOS_DIR/state/tg-msg-thread.tsv"

# 追問直送 worker（11-04）：命中 → proxy 自己 dispatch-bg --thread 續派，Router 只收「已直送」；順序不變
cat > "$TMP/dbg" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$DBG_LOG"
[ -f "$DBG_FAIL" ] && { echo 'claude --bg 沒印出短 id' >&2; exit 1; }
echo bg-0e0e0e01
SH
chmod +x "$TMP/dbg"
mkdir -p "$TMP/bots/mythos/logs"
run() { sleep 2 | HOME="$TMP" DBG_LOG="$TMP/dbg.log" DBG_FAIL="$TMP/dbg.fail" DISPATCH_BG_BIN="$TMP/dbg" FAKE_IN="$TMP/in.jsonl" TG_COMMANDS_CHILD="node $TMP/child.mjs" node "$ROOT/bin/tg-commands.mjs" 2>/dev/null; }
run > "$TMP/out.jsonl"
[ "$(grep -c . "$TMP/out.jsonl")" = 4 ] || fail "直送：應轉出 4 行：$(cat "$TMP/out.jsonl")"
c1="$(sed -n 1p "$TMP/out.jsonl" | jq -r .params.content)"
[ "$c1" = '[已直送 worker thread=t-a job=bg-0e0e0e01] 再改一下' ] || fail "直送：第 1 行不對（或順序亂了）：$c1"
[ "$(wc -l < "$TMP/dbg.log" | tr -d ' ')" = 1 ] || fail "直送：dispatch-bg 應只叫一次：$(cat "$TMP/dbg.log")"
set -- $(cat "$TMP/dbg.log")
[ "$1 $2 $3" = '--thread t-a t-a' ] || fail "直送：dispatch-bg 參數不對：$*"
grep -q '再改一下' "$4" && grep -q '^thread=t-a$' "$4" || fail "直送：prompt 檔沒帶 thread 或原話：$(cat "$4")"
for i in 2 3 4; do
  [ "$(sed -n ${i}p "$TMP/out.jsonl")" = "$(sed -n ${i}p "$TMP/in.jsonl")" ] || fail "直送：第 $i 則應原樣轉發"
done
grep -q 'reply hit thread=t-a job=bg-a1 → 直送 bg-0e0e0e01' "$TMP/bots/mythos/logs/tg-commands.log" || fail '直送：log 沒記命中'
echo '(direct) ok'

# 直送失敗 → 退回舊標註交 Router
: > "$TMP/dbg.fail"; : > "$TMP/dbg.log"
c1="$(run | sed -n 1p | jq -r .params.content)"
[ "$c1" = '[回覆 bg thread=t-a job=bg-a1] 再改一下' ] || fail "直送失敗沒退回標註：$c1"
rm -f "$TMP/dbg.fail"
echo '(direct-fail) ok'

# /fix 展開要真的送出去（11-04 前送的是原始那行）
mkdir -p "$TMP/.claude/commands"; printf -- '---\nx: 1\n---\n症狀：$ARGUMENTS\n' > "$TMP/.claude/commands/fix.md"
n '/fix 壞了' 42 '' > "$TMP/in.jsonl"
c1="$(run | sed -n 1p | jq -r .params.content)"
[ "$c1" = '症狀：壞了' ] || fail "/fix 展開沒送出：$c1"
echo '(fix-expand) ok'
echo 'TG-REPLY-THREAD PASS'
