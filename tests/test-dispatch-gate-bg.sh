#!/usr/bin/env bash
# 計畫第 5 項（工單 D）：Router 只多開一條 Bash＝完全符合的 bin/dispatch-bg 指令，prompt 檔只准 Write 到 state/bg/。
#   允許：剛好符合的 dispatch-bg（新開／--thread 續派）、Write 到 $MYTHOS/state/bg/<名>.md
#   拒絕：串接（; && | 換行）、$(...)、反引號、其他目錄的 prompt 檔、--hard、絕對路徑或前置空白、Write 到 state/bg/ 以外、
#         state/bg/ 的子目錄、非 .md、symlink、Edit；既有 Router 規則（其他 Bash、Read）照舊 deny
#   worker 模式（transcript 不在 Router 目錄下）：pinGuard 生效、telegram reply deny、一般 Bash 放行
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gate-bg-test.XXXXXX")"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"  # F1：沒設的 runner／tmux 換 guard stub（本檔不派工，只餵 gate）
trap 'rm -rf "$TMP"' EXIT
GATE="$ROOT/bin/dispatch-gate.mjs"
export MYTHOS_DIR="$TMP/mythos"
ROUTER_DIR="$TMP/router-projects"
WORKER_TDIR="$TMP/worker-projects"
mkdir -p "$MYTHOS_DIR/state/bg" "$MYTHOS_DIR/state/workorders" "$ROUTER_DIR" "$WORKER_TDIR" "$TMP/outside"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"幫我派一張"}}' > "$ROUTER_DIR/r.jsonl"
cp "$ROUTER_DIR/r.jsonl" "$WORKER_TDIR/w.jsonl"
ln -s "$TMP/outside/target.md" "$MYTHOS_DIR/state/bg/link.md"

fails=0
# $1 名稱 $2 期望 allow|deny $3 Router|worker $4 tool $5 欄位名 $6 值
check() {
  tp="$ROUTER_DIR/r.jsonl"; [ "$3" = worker ] && tp="$WORKER_TDIR/w.jsonl"
  out="$(node -e 'const [tool,k,v,tp]=process.argv.slice(1);process.stdout.write(JSON.stringify({tool_name:tool,tool_input:{[k]:v},transcript_path:tp}))' "$4" "$5" "$6" "$tp" |
    MYTHOS_TRANSCRIPT_DIR="$ROUTER_DIR" node "$GATE" pre)"
  case "$out" in *'"deny"'*) got=deny ;; *) got=allow ;; esac
  if [ "$got" = "$2" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s（期望 %s，得 %s）\n' "$1" "$2" "$got"; fails=$((fails + 1)); fi
}
NL='
'

# 允許
check 'Router dispatch-bg 新開' allow router Bash command 'bin/dispatch-bg t-a state/bg/t-a-1.md'
check 'Router dispatch-bg --thread 續派' allow router Bash command 'bin/dispatch-bg --thread t-a t-a state/bg/t-a.2.md'
check 'Router Write state/bg 絕對路徑' allow router Write file_path "$MYTHOS_DIR/state/bg/t-a-1.md"
check 'Router Write state/bg 相對路徑' allow router Write file_path 'state/bg/t-a-2.md'

# Bash 反例
check '串接 ;' deny router Bash command 'bin/dispatch-bg x y; rm -rf ~'
check '合法前綴＋; rm' deny router Bash command 'bin/dispatch-bg t-a state/bg/x.md; rm -rf ~'
check '合法前綴＋&&' deny router Bash command 'bin/dispatch-bg t-a state/bg/x.md && echo hi'
check '合法前綴＋|' deny router Bash command 'bin/dispatch-bg t-a state/bg/x.md | cat'
check '背景 &' deny router Bash command 'bin/dispatch-bg t-a state/bg/x.md &'
check '$(...)' deny router Bash command 'bin/dispatch-bg $(whoami) state/bg/x.md'
check '${...}' deny router Bash command 'bin/dispatch-bg t-a state/bg/${HOME}.md'
check '反引號' deny router Bash command 'bin/dispatch-bg `id` state/bg/x.md'
check '換行接指令' deny router Bash command "bin/dispatch-bg t-a state/bg/x.md${NL}rm -rf ~"
check '結尾換行' deny router Bash command "bin/dispatch-bg t-a state/bg/x.md${NL}"
check '其他目錄 prompt（workorders）' deny router Bash command 'bin/dispatch-bg t-a state/workorders/x.md'
check '其他目錄 prompt（/tmp）' deny router Bash command 'bin/dispatch-bg t-a /tmp/x.md'
check '其他目錄 prompt（../）' deny router Bash command 'bin/dispatch-bg t-a state/bg/../x.md'
check 'state/bg 子目錄' deny router Bash command 'bin/dispatch-bg t-a state/bg/sub/x.md'
check '非 .md' deny router Bash command 'bin/dispatch-bg t-a state/bg/x.sh'
check 'Router 不准 --hard' deny router Bash command 'bin/dispatch-bg --hard t-a state/bg/x.md'
check '多帶參數' deny router Bash command 'bin/dispatch-bg t-a t-b state/bg/x.md'
check '絕對路徑 bin' deny router Bash command '/usr/local/bin/dispatch-bg t-a state/bg/x.md'
check '前置空白' deny router Bash command ' bin/dispatch-bg t-a state/bg/x.md'
check 'env 前綴' deny router Bash command 'FOO=1 bin/dispatch-bg t-a state/bg/x.md'
check 'bin/dispatch 本體' deny router Bash command 'bin/dispatch state/bg/x.md /tmp mid'
check '其他 Bash 照舊 deny' deny router Bash command 'ls'

# Write／Edit 反例
check 'Write state/ 根' deny router Write file_path "$MYTHOS_DIR/state/x.md"
check 'Write workorders' deny router Write file_path "$MYTHOS_DIR/state/workorders/x.md"
check 'Write state/bg 子目錄' deny router Write file_path "$MYTHOS_DIR/state/bg/sub/x.md"
check 'Write ../ 跳出' deny router Write file_path "$MYTHOS_DIR/state/bg/../x.md"
check 'Write /tmp' deny router Write file_path "$TMP/outside/x.md"
check 'Write 非 .md' deny router Write file_path "$MYTHOS_DIR/state/bg/x.sh"
check 'Write 隱藏檔' deny router Write file_path "$MYTHOS_DIR/state/bg/.x.md"
check 'Write symlink' deny router Write file_path "$MYTHOS_DIR/state/bg/link.md"
check 'Edit state/bg 不開' deny router Edit file_path "$MYTHOS_DIR/state/bg/t-a-1.md"
check 'Read 照舊 deny' deny router Read file_path "$MYTHOS_DIR/state/bg/t-a-1.md"

# worker 模式：pinGuard 生效、telegram reply deny、其餘放行
PIN="$TMP/home/.claude/delegate-guard/p-123.sh"
check 'worker 一般 Bash 放行' allow worker Bash command 'ls -la; echo hi'
check 'worker pinGuard（Write）' deny worker Write file_path "$PIN"
check 'worker pinGuard（Bash）' deny worker Bash command "rm $PIN"
check 'worker telegram reply deny' deny worker mcp__telegram__reply text 'hi'

[ "$fails" = 0 ] || { echo "GATE-BG FAIL：$fails 條" >&2; exit 1; }
echo 'GATE-BG PASS'
