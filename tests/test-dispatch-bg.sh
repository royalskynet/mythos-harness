#!/usr/bin/env bash
# bin/dispatch-bg（D1）驗收：stub claude 記 argv、印假 id。
#   1. 新開：ledger 有 bg 列、cwd＝worker 目錄、帶 bypass 以外該有的參數（--bg／--allowedTools 白名單／--name）、id＝bg-<短id>
#   2. 白名單沒有 mcp__telegram__*
#   3. --thread 命中 ledger → argv 有 --resume <sessionId>（短 id 是 sessionId 前 8 碼）
#   4. --hard → {model:sonnet, advisorModel} 的 settings、backend=bg-hard
#   5. 取不到 id（stub 不印 hex）→ stderr 有 claude 原文、ledger 不寫、exit 1
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-bg-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export MYTHOS_DIR="$TMP/mythos"
export MYTHOS_WORKER_DIR="$TMP/worker"
export CLAUDE_LOG="$TMP/claude.log"
export CLAUDE_BIN="$TMP/claude"
export FAKE_ID="$TMP/fake-id"
mkdir -p "$MYTHOS_DIR/state" "$MYTHOS_WORKER_DIR/.claude"
WORKER_REAL="$(cd "$MYTHOS_WORKER_DIR" && pwd -P)"
printf '{"model":"sonnet","advisorModel":"claude-opus-5-5"}\n' > "$MYTHOS_WORKER_DIR/.claude/hard.json"
# stub 印「Started background session 0491f0d0-…」這種形態；cwd 也記下來
cat > "$CLAUDE_BIN" <<'STUB'
#!/bin/sh
printf 'CWD=%s\t%s\n' "$(pwd -P)" "$*" >> "$CLAUDE_LOG"
if [ -f "$FAKE_ID" ]; then
  printf 'Session started in background.\nid: %s\n' "$(cat "$FAKE_ID")"
else
  printf 'error: background host unavailable\n'
  exit 1
fi
STUB
chmod +x "$CLAUDE_BIN"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"  # F1：自己的 stub 設好之後才 source

TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
fail() { echo "FAIL: $*" >&2; exit 1; }
printf 'doing x\n' > "$TMP/p.md"

# 1) 新開
echo 0491f0d0-1111-2222-3333-444455556666 > "$FAKE_ID"
: > "$CLAUDE_LOG"
id="$(bash "$ROOT/bin/dispatch-bg" t-a "$TMP/p.md")"
[ "$id" = bg-0491f0d0 ] || fail "id 應是 bg-<短id>：$id"
[ "$(awk -F'\t' '(NF!=8){bad=1} END{print bad+0}' "$TSV")" = 0 ] || fail "ledger 不是 8 欄：$(sed -n l "$TSV")"
line="$(cat "$TSV")"
[ "$(printf '%s' "$line" | cut -f2)" = mid ] || fail "tier 應是 mid：$line"
[ "$(printf '%s' "$line" | cut -f3)" = "$TMP/p.md" ] || fail "task 欄不對：$line"
[ "$(printf '%s' "$line" | cut -f5)" = pending ] || fail "狀態應是 pending：$line"
[ "$(printf '%s' "$line" | cut -f6)" = "$MYTHOS_WORKER_DIR" ] || fail "cwd 欄應是 worker 目錄：$line"
[ "$(printf '%s' "$line" | cut -f7)" = t-a ] || fail "thread 欄不對：$line"
[ "$(printf '%s' "$line" | cut -f8)" = bg ] || fail "backend 應是 bg：$line"
call="$(cat "$CLAUDE_LOG")"
case "$call" in "CWD=$WORKER_REAL"$'\t'*) ;; *) fail "沒在 worker 目錄跑：$call" ;; esac
for a in '--bg' '--model sonnet' '--name mythos:t-a' '--allowedTools Bash Read Write Edit Glob Grep' 'doing x'; do
  case "$call" in *"$a"*) ;; *) fail "argv 少了 ${a}：$call" ;; esac
done
case "$call" in *telegram*) fail "argv 帶了 telegram 工具：$call" ;; esac
echo '(1) ok'

# 2) 白名單常數就是這六個
grep -q "ALLOWED_TOOLS='Bash Read Write Edit Glob Grep'" "$ROOT/bin/dispatch-bg" || fail '工具白名單不是 Bash Read Write Edit Glob Grep'

# 3) --thread 續派
echo 7a7a7a7a-0000-0000-0000-000000000000 > "$FAKE_ID"
: > "$CLAUDE_LOG"
id2="$(bash "$ROOT/bin/dispatch-bg" --thread t-a "$TMP/p.md")"
[ "$id2" = bg-7a7a7a7a ] || fail "續派 id 不對：$id2"
grep -q -- '--resume 0491f0d0' "$CLAUDE_LOG" || fail "續派沒有 --resume：$(cat "$CLAUDE_LOG")"
# 沒命中的 thread → 不帶 --resume
: > "$CLAUDE_LOG"
bash "$ROOT/bin/dispatch-bg" --thread t-new "$TMP/p.md" >/dev/null
grep -q -- '--resume' "$CLAUDE_LOG" && fail "新 thread 竟然帶 --resume：$(cat "$CLAUDE_LOG")"
# 同 thread 兩列：取最新那列（7a7a7a7a）
: > "$CLAUDE_LOG"
bash "$ROOT/bin/dispatch-bg" --thread t-a "$TMP/p.md" >/dev/null
grep -q -- '--resume 7a7a7a7a' "$CLAUDE_LOG" || fail "同 thread 沒取最新 session：$(cat "$CLAUDE_LOG")"
echo '(3) ok'

# 4) --hard（換一個唯一短 id，免撞前面同 thread 的列）
echo deadbeef-0000-0000-0000-000000000000 > "$FAKE_ID"
: > "$CLAUDE_LOG"
idh="$(bash "$ROOT/bin/dispatch-bg" --hard t-a "$TMP/p.md")"
grep -q -- "--settings $MYTHOS_WORKER_DIR/.claude/hard.json" "$CLAUDE_LOG" || fail "--hard 沒帶 hard.json：$(cat "$CLAUDE_LOG")"
field() { awk -F "\t" -v i="$1" -v n="$2" '$1==i {print $n; exit}' "$TSV"; }
[ "$(field "$idh" 8)" = bg-hard ] || fail "--hard 的 backend 不是 bg-hard：$(cat "$TSV")"
[ "$(field "$idh" 2)" = hard ] || fail "--hard 的 tier 不是 hard"
echo '(4) ok'

# 5) 取不到 id → 原文上 stderr、ledger 不寫、exit 1
rm -f "$FAKE_ID"
cp "$TSV" "$TMP/before"
rc=0
bash "$ROOT/bin/dispatch-bg" t-b "$TMP/p.md" > "$TMP/o" 2> "$TMP/e" || rc=$?
[ "$rc" = 1 ] || fail "取不到 id 應 exit 1，得 $rc"
grep -q 'background host unavailable' "$TMP/e" || fail "stderr 沒有 claude 原文：$(cat "$TMP/e")"
cmp -s "$TSV" "$TMP/before" || fail '取不到 id 卻寫了 ledger'
[ ! -s "$TMP/o" ] || fail "取不到 id 卻印了 stdout：$(cat "$TMP/o")"
echo '(5) ok'

# 6) sandbox 外 claude → exit 97（守門）
rc=0
CLAUDE_BIN=/bin/echo bash "$ROOT/bin/dispatch-bg" t-c "$TMP/p.md" >/dev/null 2>"$TMP/e97" || rc=$?
[ "$rc" = 97 ] || fail "sandbox 外 claude 應 exit 97，得 $rc"
cmp -s "$TSV" "$TMP/before" || fail 'exit 97 卻寫了 ledger'
echo '(6) ok'

# 7) bin/dispatch hard 預設走 bg-hard：新開 session（同 thread 已有列也不續派到呼叫端自己）、
#    prompt 第一行要求在 cwd 開 git worktree、不進 C3 repo 佇列（ledger 沒有 deep／queued 列）
echo cafe0007-0000-0000-0000-000000000000 > "$FAKE_ID"
: > "$CLAUDE_LOG"
mkdir -p "$TMP/repo"
cp "$TSV" "$TMP/before7"
id7="$(env -u DISPATCH_HARD_BACKEND DISPATCH_THREAD=t-a bash "$ROOT/bin/dispatch" "$TMP/p.md" "$TMP/repo" hard)"
[ "$id7" = bg-cafe0007 ] || fail "7：dispatch hard 沒走 dispatch-bg：$id7"
[ "$(field "$id7" 8)" = bg-hard ] || fail "7：backend 不是 bg-hard：$(cat "$TSV")"
[ "$(field "$id7" 7)" = t-a ] || fail '7：thread 沒帶到 ledger'
grep -q -- '--resume' "$CLAUDE_LOG" && fail "7：dispatch hard 續派到既有 session：$(cat "$CLAUDE_LOG")"
grep -q -- "第一步：git -C '$TMP/repo' worktree add" "$CLAUDE_LOG" || fail "7：prompt 第一行沒要求 worktree：$(cat "$CLAUDE_LOG")"
[ "$(awk -F'\t' '$8=="deep" || $5=="queued"' "$TSV" | wc -l | tr -d ' ')" = 0 ] || fail "7：bg-hard 進了 deep／repo 佇列：$(cat "$TSV")"
# 沒給 DISPATCH_THREAD（thread=-）也能新開
echo cafe0008-0000-0000-0000-000000000000 > "$FAKE_ID"
id8="$(env -u DISPATCH_HARD_BACKEND -u DISPATCH_THREAD bash "$ROOT/bin/dispatch" "$TMP/p.md" "$TMP/repo" hard)"
[ "$id8" = bg-cafe0008 ] || fail "7：thread=- 的 hard 派不出去：$id8"
echo '(7) ok'

# 8) --thread 與位置參數 thread 不一致 → exit 2、ledger 不動
cp "$TSV" "$TMP/before8"
rc=0
bash "$ROOT/bin/dispatch-bg" --thread t-a t-zzz "$TMP/p.md" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "8：thread 不一致應 exit 2，得 $rc"
cmp -s "$TSV" "$TMP/before8" || fail '8：thread 不一致卻寫了 ledger'
echo '(8) ok'

# 9) deep 票重派仍走 deep（DISPATCH_HARD_BACKEND 沒設也一樣），不被預設帶去 bg-hard
printf 'redo\n' > "$TMP/redo.md"  # 另一個檔名：dispatch-retry 按檔名數重派次數，p.md 前面已經用很多次
printf 'deep-1-1-old\thard\t%s\t1\tfailed\t%s\t-\tdeep\n' "$TMP/redo.md" "$TMP/repo" >> "$TSV"
: > "$CLAUDE_LOG"
env -u DISPATCH_HARD_BACKEND DISPATCH_REPO_QUEUE=0 bash "$ROOT/bin/dispatch-retry" deep-1-1-old "補" >"$TMP/o9" 2>&1 || { cat "$TMP/o9" >&2; false; } || fail '9：retry deep 票失敗'
[ ! -s "$CLAUDE_LOG" ] || fail "9：retry deep 票叫了 claude：$(cat "$CLAUDE_LOG")"
awk -F'\t' '$1 ~ /^deep-/ && $1 != "deep-1-1-old" && $8=="deep" {f=1} END {exit !f}' "$TSV" || fail "9：retry 沒沿用 deep：$(cat "$TSV")"
echo '(9) ok'

# 10) router/worker-sync.sh：範本同步到 worker 目錄、留住目標既有檔、__MYTHOS_DIR__ 換成 repo 絕對路徑、不准放在 Mythos 底下
W="$TMP/wsync"; mkdir -p "$W"; printf 'keep\n' > "$W/mine.txt"
MYTHOS_WORKER_DIR="$W" MYTHOS_DIR="$TMP/my&repo|x" bash "$ROOT/router/worker-sync.sh" || fail '10：worker-sync 失敗'
[ "$(cat "$W/mine.txt")" = keep ] || fail '10：同步刪／改了目標既有檔'
grep -q advisorModel "$W/.claude/hard.json" || fail '10：hard.json 沒同步'
grep -q '__MYTHOS_DIR__' "$W/CLAUDE.md" "$W/.claude/settings.json" && fail '10：placeholder 沒換掉'
grep -qF "node \\\"$TMP/my&repo|x/bin/dispatch-gate.mjs\\\" pre" "$W/.claude/settings.json" || fail "10：gate 路徑沒填成 repo 絕對路徑：$(cat "$W/.claude/settings.json")"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$W/.claude/settings.json" || fail '10：settings.json 不是合法 JSON'
grep -q 'mcp__telegram' "$W/CLAUDE.md" && fail '10：worker CLAUDE.md 提到 telegram 工具'
rc=0; MYTHOS_WORKER_DIR="$TMP/my/worker" MYTHOS_DIR="$TMP/my" bash "$ROOT/router/worker-sync.sh" 2>/dev/null || rc=$?
[ "$rc" = 2 ] || fail "10：worker 目錄在 Mythos 底下應 exit 2，得 $rc"
echo 'DISPATCH-BG PASS'
