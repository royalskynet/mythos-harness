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
# F2 用的背景持鎖 pid（trap 開頭就要有定義，set -u 下沒定義會讓 trap 自己爆掉）
lpid=''
# bash 3.2 在 set -e／set -u 下，trap 內任何非零或未定義變數都會蓋掉腳本的 exit code → 全部吞掉、結尾 exit 0
trap '_r=$?; trap "" EXIT; [ -n "$lpid" ] && kill "$lpid" 2>/dev/null; [ -n "$lpid" ] && wait "$lpid" 2>/dev/null; chflags nouchg "$TSV" 2>/dev/null; [ "$(whoami)" = "$(stat -f %Su "$TMP")" ] && chmod -R u+w "$TMP"; rm -rf "$TMP"; exit "$_r"' EXIT
# kill + wait 背景持鎖；wait 的 exit status 是 perl 的，不接住會變成腳本結尾的 exit code
unlock() { kill "$lpid" 2>/dev/null; wait "$lpid" 2>/dev/null || true; lpid=''; :; }
export MYTHOS_DIR="$TMP/mythos"
export MYTHOS_WORKER_DIR="$TMP/worker"
export CLAUDE_LOG="$TMP/claude.log"
export CLAUDE_BIN="$TMP/claude"
export FAKE_ID="$TMP/fake-id"
export FAKE_AGENTS="$TMP/fake-agents.json"
export FAKE_NOTE="$TMP/fake-note"
mkdir -p "$MYTHOS_DIR/state" "$MYTHOS_WORKER_DIR/.claude"
WORKER_REAL="$(cd "$MYTHOS_WORKER_DIR" && pwd -P)"
printf '{"model":"sonnet","advisorModel":"claude-opus-5-5"}\n' > "$MYTHOS_WORKER_DIR/.claude/hard.json"
# stub 印「Started background session 0491f0d0-…」這種形態；cwd 也記下來
cat > "$CLAUDE_BIN" <<'STUB'
#!/bin/sh
if [ "${1:-}" = agents ]; then cat "$FAKE_AGENTS" 2>/dev/null || echo '[]'; exit 0; fi
printf 'CWD=%s\t%s\n' "$(pwd -P)" "$*" >> "$CLAUDE_LOG"
if [ -f "$FAKE_NOTE" ]; then cat "$FAKE_NOTE"; exit 0; fi
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

# 3) --thread 續派：--resume 要帶完整 sessionId（短 id 會讓 claude 起一個不跑的 copy，11-04 實測）
printf '[{"id":"0491f0d0","sessionId":"0491f0d0-1111-2222-3333-444455556666"},{"id":"7a7a7a7a","sessionId":"7a7a7a7a-0000-0000-0000-000000000000"}]\n' > "$FAKE_AGENTS"
echo 7a7a7a7a-0000-0000-0000-000000000000 > "$FAKE_ID"
: > "$CLAUDE_LOG"
id2="$(bash "$ROOT/bin/dispatch-bg" --thread t-a "$TMP/p.md")"
[ "$id2" = bg-7a7a7a7a ] || fail "續派 id 不對：$id2"
grep -q -- '--resume 0491f0d0-1111-2222-3333-444455556666 ' "$CLAUDE_LOG" || fail "續派沒帶完整 sessionId：$(cat "$CLAUDE_LOG")"
# 沒命中的 thread → 不帶 --resume
: > "$CLAUDE_LOG"
bash "$ROOT/bin/dispatch-bg" --thread t-new "$TMP/p.md" >/dev/null
grep -q -- '--resume' "$CLAUDE_LOG" && fail "新 thread 竟然帶 --resume：$(cat "$CLAUDE_LOG")"
# 同 thread 兩列：取最新那列（7a7a7a7a）
: > "$CLAUDE_LOG"
bash "$ROOT/bin/dispatch-bg" --thread t-a "$TMP/p.md" >/dev/null
grep -q -- '--resume 7a7a7a7a-0000-0000-0000-000000000000 ' "$CLAUDE_LOG" || fail "同 thread 沒取最新 session：$(cat "$CLAUDE_LOG")"
# claude agents 列不到 → 不硬續短 id，改新開並在 stderr 說明
echo '[]' > "$FAKE_AGENTS"
: > "$CLAUDE_LOG"
bash "$ROOT/bin/dispatch-bg" --thread t-a "$TMP/p.md" >/dev/null 2> "$TMP/e3"
grep -q -- '--resume' "$CLAUDE_LOG" && fail "換不到完整 id 竟然還帶 --resume：$(cat "$CLAUDE_LOG")"
grep -q '找不到 7a7a7a7a 的完整 sessionId' "$TMP/e3" || fail "換不到完整 id 沒說明：$(cat "$TMP/e3")"
# 續派的真實輸出：note 行先出現原 session id，ledger 要記 backgrounded 那行的新 id
printf 'note: session 0491f0d0 is already running in the background, so this started a copy as 5e5e5e5e. `claude attach 0491f0d0` opens the original.\nbackgrounded \302\267 5e5e5e5e \302\267 mythos:t-c\n' > "$FAKE_NOTE"
id3="$(bash "$ROOT/bin/dispatch-bg" t-c "$TMP/p.md")"
rm -f "$FAKE_NOTE"
[ "$id3" = bg-5e5e5e5e ] || fail "note 行的原 id 被當成新 id：$id3"
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
echo '(10) ok'

# 11) F2a：拿鎖失敗 → 停掉已啟動的 worker（只有這一個 worker、ledger 零列）
echo f2a00001-0000-0000-0000-000000000000 > "$FAKE_ID"
: > "$CLAUDE_LOG"
cp "$TSV" "$TMP/before11"
perl -MFcntl=:flock -e 'open(my $f,">>",$ARGV[0]) or die; flock($f,LOCK_EX) or die; open(my $r,">",$ARGV[1]); close $r; sleep 60' \
  "$MYTHOS_DIR/state/.ledger.flock" "$TMP/locked" 2>/dev/null &
lpid=$!
n=0
while [ ! -f "$TMP/locked" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
[ -f "$TMP/locked" ] && kill -0 "$lpid" 2>/dev/null || fail '11：背景持鎖沒起來'
rc=0
LEDGER_LOCK_TRIES=1 bash "$ROOT/bin/dispatch-bg" t-f2a "$TMP/p.md" >"$TMP/o11" 2>"$TMP/e11" || rc=$?
unlock
[ "$rc" != 0 ] || fail '11：拿不到鎖卻 exit 0'
cmp -s "$TSV" "$TMP/before11" || fail '11：拿不到鎖卻寫了 ledger'
grep -q 'stop f2a00001' "$CLAUDE_LOG" || fail "11：沒停掉已啟動的 worker：$(cat "$CLAUDE_LOG")"
grep -q '已停止 worker' "$TMP/e11" || fail "11：stderr 沒有已停止 worker：$(cat "$TMP/e11")"
echo '(11) ok'

# 12) F2b：append 失敗 → 同樣停掉 worker；ledger 內容不變
echo f2b00002-0000-0000-0000-000000000000 > "$FAKE_ID"
: > "$CLAUDE_LOG"
chflags uchg "$TSV" || fail '12：設不了 uchg'
rc=0
bash "$ROOT/bin/dispatch-bg" t-f2b "$TMP/p.md" >"$TMP/o12" 2>"$TMP/e12" || rc=$?
chflags nouchg "$TSV"
[ "$rc" != 0 ] || fail '12：寫 ledger 失敗卻 exit 0'
cmp -s "$TSV" "$TMP/before11" || fail '12：寫入失敗卻改了 ledger'
grep -q 'stop f2b00002' "$CLAUDE_LOG" || fail "12：沒停掉已啟動的 worker：$(cat "$CLAUDE_LOG")"
grep -q '已停止 worker' "$TMP/e12" || fail "12：stderr 沒有已停止 worker：$(cat "$TMP/e12")"
echo '(12) ok'

# 13) F3：--hard 的第 6 欄記 --cwd 的 repo，dispatch-retry 重派時 worktree 指向它；非 hard 一律記 worker 目錄
REPO_A="$TMP/repoA"; mkdir -p "$REPO_A"
printf 'retry me\n' > "$TMP/f3-retry.md"
echo f3000013-0000-0000-0000-000000000000 > "$FAKE_ID"
: > "$CLAUDE_LOG"
id13="$(bash "$ROOT/bin/dispatch-bg" --hard --cwd "$REPO_A" t-f3 "$TMP/f3-retry.md")"
[ "$(field "$id13" 6)" = "$REPO_A" ] || fail "13：bg-hard 第 6 欄不是 --cwd 的 repo：$(grep "$id13" "$TSV")"
: > "$CLAUDE_LOG"
DISPATCH_BG_BIN="$ROOT/bin/dispatch-bg" DISPATCH_HARD_BACKEND=bg DISPATCH_THREAD=- bash "$ROOT/bin/dispatch-retry" "$id13" '追加' \
  2>"$TMP/e13" || { cat "$TMP/e13" >&2; fail '13：dispatch-retry 非零'; }
grep -qF "git -C '$REPO_A' worktree add" "$CLAUDE_LOG" || fail "13：重派 worktree 沒指向 repoA：$(cat "$CLAUDE_LOG")"
# CWD= 與 --settings 本來就在 worker 目錄；只驗 worktree 指令沒指向它
if grep -qF "git -C '$MYTHOS_WORKER_DIR'" "$CLAUDE_LOG"; then fail "13：重派 worktree 指向 worker 目錄：$(cat "$CLAUDE_LOG")"; fi
echo f4000014-0000-0000-0000-000000000000 > "$FAKE_ID"
id14="$(bash "$ROOT/bin/dispatch-bg" --cwd "$REPO_A" t-f4 "$TMP/p.md")"
[ "$(field "$id14" 6)" = "$MYTHOS_WORKER_DIR" ] || fail "13：非 hard 帶 --cwd 竟記成 repoA：$(grep "$id14" "$TSV")"
echo '(13) ok'
# 14) --from-chat：prompt 由 chat-prompt.mjs 從 transcript 抓老闆原話自動寫，claude 拿到的內容含原話與補充
RT="$TMP/router.jsonl"
printf '%s\n' '{"type":"user","origin":{"kind":"channel"},"message":{"content":"<channel source=\"telegram\" chat_id=\"1\">\n幫我把 log 輪替修好\n</channel>"}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__telegram__reply","input":{"text":"收到"}}]}}' > "$RT"
echo f5000015-0000-0000-0000-000000000000 > "$FAKE_ID"
: > "$CLAUDE_LOG"
id15="$(bash "$ROOT/bin/dispatch-bg" --from-chat t-fc --note '先看 launchd' --transcript "$RT")"
[ "$id15" = bg-f5000015 ] || fail "14：from-chat id 不對：$id15"
grep -q '幫我把 log 輪替修好' "$CLAUDE_LOG" || fail "14：worker prompt 沒帶原話：$(cat "$CLAUDE_LOG")"
grep -q '先看 launchd' "$CLAUDE_LOG" || fail "14：worker prompt 沒帶補充"
case "$(field "$id15" 3)" in */mythos/state/bg/t-fc-*.md) ;; *) fail "14：ledger task 欄應是自動 prompt 檔：$(field "$id15" 3)" ;; esac
bash "$ROOT/bin/dispatch-bg" --from-chat t-fc 2>/dev/null && fail '14：缺 --transcript 應拒跑'
echo '(14) ok'
echo 'DISPATCH-BG PASS'
