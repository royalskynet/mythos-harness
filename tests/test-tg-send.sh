#!/usr/bin/env bash
# E2 驗收：bin/tg-send 與 dispatch-watch 的 PASS 直發（至多一次）。全用本機 HTTP stub／假 claude／假 tmux。
#   (a) 成功：stub 收到全文、對照表多一列、Router 沒收到、票變 notified-PASS；再跑一輪不重送
#   (b) 500：退回 Router 投遞；再跑一輪不直發
#   (c) 回應不結束：時限內收掉成 unknown＋已 ACK＋brief-lines 告警；再跑一輪不重送
#   (d) 上輪卡在 sending 超過 600 秒 → 照 unknown 收掉；(d2) 未逾時的 sending 不交 Router
#   (e) bg-hard 不直發　(f) 截斷　(g) sandbox 指真 base → 97　(h) 未設 MYTHOS_DIR、cwd=/ → 對照表寫到腳本所在 repo　(i) 送出後斷線 → exit 2
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tg-send.XXXXXX")"
spid=''
trap '_r=$?; trap "" EXIT; [ -n "$spid" ] && { kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null || true; }; rm -rf "$TMP"; exit "$_r"' EXIT
export MYTHOS_DIR="$TMP/mythos"
export DCQ_HOME="$TMP/dcq"
export TMUX_BIN="$TMP/tmux"
export TMUX_LOG="$TMP/tmux.log"
export MYTHOS_TRANSCRIPT_DIR="$TMP/router-transcript"
export CLAUDE_PROJECTS_DIR="$TMP/projects"
export CLAUDE_BIN="$TMP/claude"
export FAKE_AGENTS="$TMP/agents.json"
export CLAUDE_LOG="$TMP/claude.log"
export BRIEF_LINES_DIR="$TMP/brief"
export TELEGRAM_STATE_DIR="$TMP/tg"
export TELEGRAM_BOT_TOKEN=T
export STUB_MODE="$TMP/stub.mode" STUB_CALLS="$TMP/stub.calls"
cat > "$CLAUDE_BIN" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$CLAUDE_LOG"
case "$1" in agents) tr -d '\n' < "$FAKE_AGENTS"; printf '\n' ;; esac
exit 0
STUB
chmod +x "$CLAUDE_BIN"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"

cat > "$TMUX_BIN" <<'TMUX'
#!/bin/sh
printf '%s\n' "$*" >> "$TMUX_LOG"
case " $* " in *" capture-pane "*) echo 'idle screen' ;; esac
exit 0
TMUX
chmod +x "$TMUX_BIN"

# stub：模式檔 ok／500／hang；每個請求的 body 一行記進 STUB_CALLS
cat > "$TMP/stub.mjs" <<'JS'
import http from 'node:http'
import fs from 'node:fs'
let mid = 900
const srv = http.createServer((req, res) => {
  let b = ''
  req.on('data', d => (b += d)).on('end', () => {
    fs.appendFileSync(process.env.STUB_CALLS, b + '\n')
    const mode = fs.readFileSync(process.env.STUB_MODE, 'utf8').trim()
    if (mode === 'hang') { res.writeHead(200, { 'content-type': 'application/json' }); res.write('{"ok":'); return }
    if (mode === 'destroy') { req.socket.destroy(); return }
    if (mode === '500') { res.writeHead(500); res.end('{"ok":false}'); return }
    res.setHeader('content-type', 'application/json')
    res.end(JSON.stringify({ ok: true, result: { message_id: mid++ } }))
  })
}).listen(0, '127.0.0.1', () => fs.writeFileSync(process.argv[2], String(srv.address().port)))
JS
echo ok > "$STUB_MODE"; : > "$STUB_CALLS"
node "$TMP/stub.mjs" "$TMP/port" & spid=$!
for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
[ -s "$TMP/port" ] || { echo "FAIL: stub 沒起來" >&2; exit 1; }
export TG_API_BASE="http://127.0.0.1:$(cat "$TMP/port")"

mkdir -p "$MYTHOS_DIR/state/bg" "$MYTHOS_TRANSCRIPT_DIR" "$CLAUDE_PROJECTS_DIR" "$TELEGRAM_STATE_DIR"
printf '{"allowFrom":["42"]}\n' > "$TELEGRAM_STATE_DIR/access.json"
printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$MYTHOS_TRANSCRIPT_DIR/router.jsonl"
TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
EV="$MYTHOS_DIR/state/events.jsonl"
MAP="$MYTHOS_DIR/state/tg-msg-thread.tsv"
fail() { echo "FAIL: $*" >&2; exit 1; }
row() { printf '%s\t%s\t%s\t%s\tpending\t%s\tt-%s\t%s\n' "$1" mid "$TMP/p.md" "$(date +%s)" "$TMP/worker" "$2" "$3" >> "$TSV"; }
status_of() { awk -F '\t' -v i="$1" '$1==i {print $5; exit}' "$TSV"; }
calls() { grep -c . "$STUB_CALLS" || true; }
ev() { jq -r --arg e "$1" "select(.event_id==\$e) | $2" "$EV"; }
agents=''
done_job() { # 短id backend 結果文字
  row "bg-$1" "$1" "$2"
  printf '%s\n' "$3" > "$MYTHOS_DIR/state/bg/$1.result"
  agents="$agents${agents:+,}{\"sessionId\":\"$1-1111-2222-3333-444455556666\",\"kind\":\"background\",\"state\":\"done\"}"
  printf '[%s]' "$agents" > "$FAKE_AGENTS"
}
watch() { bash "$ROOT/bin/dispatch-watch" 9>&- || fail "dispatch-watch 非零退出"; }

# (a) 成功
done_job aaaa0001 bg '[t-aaaa0001 結論] 全部做完'
watch
[ "$(calls)" = 1 ] || fail "(a) stub 應收到 1 次：$(calls)"
grep -q '全部做完' "$STUB_CALLS" || fail '(a) stub 沒收到 result 全文'
grep -q '回覆這則訊息' "$STUB_CALLS" || fail '(a) 缺續派提示'
grep -q "$(printf '^42\t900\tt-aaaa0001\tbg-aaaa0001\t')" "$MAP" || fail "(a) 對照表沒登錄：$(cat "$MAP" 2>/dev/null)"
if grep -q 'event_id=bg-aaaa0001-PASS' "$TMUX_LOG" 2>/dev/null; then fail '(a) 直發成功還投遞給 Router'; fi
[ "$(ev bg-aaaa0001-PASS .direct)" = sent ] || fail "(a) direct 應是 sent：$(ev bg-aaaa0001-PASS .direct)"
[ "$(status_of bg-aaaa0001)" = notified-PASS ] || fail "(a) ledger 應 notified-PASS：$(status_of bg-aaaa0001)"
watch
[ "$(calls)" = 1 ] || fail "(a) 第二輪重送了：$(calls)"
echo '(a) ok'

# (b) 500 → Router
echo 500 > "$STUB_MODE"
done_job bbbb0002 bg '[t-bbbb0002 結論] 好了'
watch
[ "$(calls)" = 2 ] || fail "(b) stub 應收到第 2 次：$(calls)"
[ "$(ev bg-bbbb0002-PASS .direct)" = failed ] || fail "(b) direct 應是 failed：$(ev bg-bbbb0002-PASS .direct)"
grep -q 'event_id=bg-bbbb0002-PASS' "$TMUX_LOG" || fail '(b) 沒退回 Router 投遞'
echo ok > "$STUB_MODE"
watch
[ "$(calls)" = 2 ] || fail "(b) 失敗後又直發：$(calls)"
echo '(b) ok'

# (c) 回應不結束 → unknown
echo hang > "$STUB_MODE"
done_job cccc0003 bg '[t-cccc0003 結論] 卡住測試'
t0=$(date +%s)
TG_SEND_TIMEOUT_MS=1000 watch
[ $(( $(date +%s) - t0 )) -le 10 ] || fail '(c) 逾時沒在 10 秒內收掉'
[ "$(ev bg-cccc0003-PASS .direct)" = unknown ] || fail "(c) direct 應是 unknown：$(ev bg-cccc0003-PASS .direct)"
[ "$(ev bg-cccc0003-PASS .acked_at)" != null ] || fail '(c) unknown 沒標 ACK'
grep -q '直發結果不明 bg-cccc0003' "$BRIEF_LINES_DIR/mythos-direct.txt" || fail '(c) brief-lines 沒告警'
if grep -q 'event_id=bg-cccc0003-PASS' "$TMUX_LOG"; then fail '(c) 不明還投遞給 Router'; fi
n=$(calls); echo ok > "$STUB_MODE"
watch
[ "$(calls)" = "$n" ] || fail '(c) 不明後又重送'
echo '(c) ok'

# (d) 卡在 sending 超過 600 秒
old=$(( $(date +%s) - 700 ))
row bg-dddd0004 dddd0004 bg
printf '{"event_id":"bg-dddd0004-PASS","job_id":"bg-dddd0004","status":"PASS","created":%s,"delivered_at":null,"acked_at":null,"tries":0,"direct":"sending"}\n' "$old" >> "$EV"
watch
[ "$(ev bg-dddd0004-PASS .direct)" = unknown ] || fail "(d) sending 殘留沒收掉：$(ev bg-dddd0004-PASS .direct)"
grep -q '直發結果不明 bg-dddd0004' "$BRIEF_LINES_DIR/mythos-direct.txt" || fail '(d) 沒告警'
if grep -q 'event_id=bg-dddd0004-PASS' "$TMUX_LOG"; then fail '(d) sending 殘留被投遞給 Router'; fi
echo '(d) ok'

# (d2) 未逾時的 sending（另一輪送到一半）→ 不交 Router、維持 sending
row bg-dddd0014 dddd0014 bg
printf '{"event_id":"bg-dddd0014-PASS","job_id":"bg-dddd0014","status":"PASS","created":%s,"delivered_at":null,"acked_at":null,"tries":0,"direct":"sending"}\n' "$(( $(date +%s) - 10 ))" >> "$EV"
watch
if grep -q 'event_id=bg-dddd0014-PASS' "$TMUX_LOG"; then fail '(d2) 送到一半的 sending 被投遞給 Router'; fi
[ "$(ev bg-dddd0014-PASS .direct)" = sending ] || fail "(d2) 未逾時 sending 被改掉：$(ev bg-dddd0014-PASS .direct)"
echo '(d2) ok'

# (e) bg-hard 不直發
n=$(calls)
done_job eeee0005 bg-hard '[t-eeee0005 結論] hard 做完'
watch
[ "$(calls)" = "$n" ] || fail '(e) bg-hard 被直發'
grep -q 'event_id=bg-eeee0005-PASS' "$TMUX_LOG" || fail '(e) bg-hard 沒走 Router'
echo '(e) ok'

# (f) 截斷
: > "$STUB_CALLS"
head -c 5000 /dev/zero | tr '\0' 'x' | node "$ROOT/bin/tg-send" --thread t-f --job bg-ffff0006 >/dev/null || fail '(f) tg-send 失敗'
txt="$(head -1 "$STUB_CALLS" | jq -r .text)"
len="$(head -1 "$STUB_CALLS" | jq -r '.text | length')"   # 用 jq 算字數；bash ${#} 在 C locale 算的是位元組
[ "$len" -le 3500 ] || fail "(f) 沒截到 3500 內：$len"
case "$txt" in *'…（截斷，全文 state/bg/ffff0006.result）') ;; *) fail "(f) 截斷尾巴不對" ;; esac
echo '(f) ok'

# (g) sandbox 指非 127.0.0.1 的 base → 97，且 stub 沒收到。先用 localhost 指向 stub：守門被拿掉時會打到 stub 先 FAIL，不會出網
: > "$STUB_CALLS"
set +e; echo hi | TG_API_BASE="http://localhost:$(cat "$TMP/port")" node "$ROOT/bin/tg-send" --thread t-g --job bg-g 2>/dev/null; rc=$?; set -e
[ "$rc" = 97 ] || fail "(g) localhost base 應 exit 97：$rc"
[ "$(calls)" = 0 ] || fail '(g) localhost base 有請求送出'
set +e; echo hi | TG_API_BASE=https://api.telegram.org node "$ROOT/bin/tg-send" --thread t-g --job bg-g 2>/dev/null; rc=$?; set -e
[ "$rc" = 97 ] || fail "(g) 應 exit 97：$rc"
[ "$(calls)" = 0 ] || fail '(g) 有請求送出'
echo '(g) ok'

# (i) 收完請求才斷線 → 不明（exit 2），不是確定沒送；連線被拒才是 exit 1
echo destroy > "$STUB_MODE"; : > "$STUB_CALLS"
set +e; echo hi | node "$ROOT/bin/tg-send" --thread t-i --job bg-i 2>/dev/null; rc=$?; set -e
[ "$(calls)" = 1 ] || fail "(i) stub 應收到請求：$(calls)"
[ "$rc" = 2 ] || fail "(i) 送出後斷線應 exit 2：$rc"
closed=$(node -e "const s=require('net').createServer().listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close()})")
set +e; echo hi | TG_API_BASE="http://127.0.0.1:$closed" node "$ROOT/bin/tg-send" --thread t-i --job bg-i 2>/dev/null; rc=$?; set -e
[ "$rc" = 1 ] || fail "(i) 連線被拒應 exit 1：$rc"
echo ok > "$STUB_MODE"
echo '(i) ok'

# (h) 未設 MYTHOS_DIR、cwd=/ → 對照表寫到腳本所在 repo 的 state/
mkdir -p "$TMP/repo/bin"; cp "$ROOT/bin/tg-send" "$TMP/repo/bin/tg-send"
(cd / && echo hi | env -u MYTHOS_DIR node "$TMP/repo/bin/tg-send" --thread t-h --job bg-hhhh0008 >/dev/null) || fail '(h) tg-send 失敗'
grep -q 'bg-hhhh0008' "$TMP/repo/state/tg-msg-thread.tsv" || fail '(h) 對照表沒寫到 repo/state'
echo '(h) ok'

echo 'TG-SEND PASS'
