#!/usr/bin/env bash
# 端到端（真 claude --bg，計畫「預防加固」最後一條）：只在 MYTHOS_E2E=1 時跑，否則印 SKIP e2e、exit 0。
# 主 session 合回後自己跑：MYTHOS_E2E=1 bash tests/test-dispatch-bg-e2e.sh
#   dispatch-bg 一張「寫檔 X 後結束」（worker 目錄與 MYTHOS_DIR 都在 TMP，模型換 haiku）
#   → 中途 kill 呼叫端 shell 不影響 → 60 秒內 X 存在且 claude agents --json --all 該 session 為 done
set -eu
if [ "${MYTHOS_E2E:-}" != 1 ]; then echo 'SKIP e2e（設 MYTHOS_E2E=1 才跑真 claude --bg）'; exit 0; fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-bg-e2e.XXXXXX")"
REAL_CLAUDE="${E2E_CLAUDE:-$(command -v claude)}"
[ -x "$REAL_CLAUDE" ] || { echo "FAIL: 找不到 claude" >&2; exit 1; }
export MYTHOS_DIR="$TMP/mythos"
export MYTHOS_WORKER_DIR="$TMP/worker"
# sandbox 內的 wrapper：把 --model sonnet 換成 haiku（省錢），其餘原樣交給真 claude
export CLAUDE_BIN="$TMP/claude"
printf '#!/usr/bin/env bash\nargs=()\nfor a in "$@"; do [ "$a" = sonnet ] && a=haiku; args+=("$a"); done\nexec %q "${args[@]}"\n' "$REAL_CLAUDE" > "$CLAUDE_BIN"
chmod +x "$CLAUDE_BIN"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"  # F1：自己的 stub 設好之後才 source
sid=''
cleanup() {
  [ -n "$sid" ] && { "$REAL_CLAUDE" stop "$sid" >/dev/null 2>&1 || true; }
  [ -n "${KEEP:-}" ] || rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$MYTHOS_DIR/state"
bash "$ROOT/router/worker-sync.sh" || fail 'worker-sync 失敗'
X="$TMP/out/X.txt"; mkdir -p "$TMP/out"
printf '用 Write 工具把內容 ok 寫進 %s，不做別的事，寫完就結束。\n' "$X" > "$TMP/p.md"

# 呼叫端 shell 在背景跑 dispatch-bg，印出 id 後立刻被 kill（claude --bg 的 session 由 pty host 托管，不跟著死）
bash -c '"$1" e2e-x "$2" > "$3"; sleep 30' _ "$ROOT/bin/dispatch-bg" "$TMP/p.md" "$TMP/id" &
caller=$!
for _ in $(seq 1 40); do [ -s "$TMP/id" ] && break; sleep 0.5; done
kill "$caller" 2>/dev/null || true
wait "$caller" 2>/dev/null || true
id="$(cat "$TMP/id" 2>/dev/null || true)"
case "$id" in bg-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) fail "dispatch-bg 沒印出 bg-<短id>：$id" ;; esac
sid="${id#bg-}"
grep -q "^$id	" "$MYTHOS_DIR/state/dispatch-jobs.tsv" || fail 'ledger 沒有這張'

state=''
for _ in $(seq 1 60); do
  state="$("$REAL_CLAUDE" agents --json --all 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let a=[];try{a=JSON.parse(s)}catch{};const h=a.find(x=>(x.sessionId||"").startsWith(process.argv[1]));process.stdout.write(h?String(h.state||""):"")})' "$sid")"
  [ -f "$X" ] && [ "$state" = done ] && break
  sleep 1
done
[ -f "$X" ] || fail "60 秒內 X 沒出現（state=${state}）"
[ "$state" = done ] || fail "60 秒內 state 不是 done：${state}"
sid=''  # 已 done，不必 stop
echo 'DISPATCH-BG-E2E PASS'
