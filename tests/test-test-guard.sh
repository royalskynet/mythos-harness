#!/usr/bin/env bash
# F1 驗收：測試不可能啟動真 runner。
#   (a) 會呼叫 bin/dispatch* 的測試都 source tests/lib-test-guard.sh（清單動態算）
#   (b) DISPATCH_DEEP_RUN_BIN 指 repo 的 bin/dispatch-deep-run（sandbox 外）跑 dispatch hard → exit 97、ledger 沒有列
#   (c) 直接跑 bin/dispatch-deep-run 帶 MYTHOS_TEST_SANDBOX、下一層 DEEP_RUN_BIN 不在 sandbox → exit 97、什麼都不寫
#   (d) dispatch-watch 要拉起 queued、runner 在 sandbox 外 → exit 97、ledger 原文不變
#   (f) 守門在第一次讀寫 ledger／events 之前：逾時 deep 票＋同 cwd queued 也不得落地任何改動
#   (g) TMUX_BIN 在 sandbox 外 → exit 97
#   (e) guard 不覆蓋已設定的值；沒設定的換成 sandbox 內 stub（含 CLAUDE_BIN）
#   (h) 工單 D：CLAUDE_BIN 在 sandbox 外 → dispatch hard（預設 bg-hard）、dispatch-bg、dispatch-watch（有 bg 列）、
#       dispatch-cancel（bg 列）一律 exit 97、ledger 不變
# 萬一守門失效：DEEP_RUN_BIN 是 guard stub、PATH 前面放假 deep-run，就算被執行也只是記一行。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-guard.XXXXXX")"
OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/test-guard-outside.XXXXXX")"
trap 'rm -rf "$TMP" "$OUTSIDE"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# sandbox 外的假 deep-run：被叫到就記下來（斷言它不能被叫到）
printf '#!/bin/sh\necho "$0 $*" >> "%s/outside-calls.log"\nexit 0\n' "$OUTSIDE" > "$OUTSIDE/deep-run"
chmod +x "$OUTSIDE/deep-run"
export PATH="$OUTSIDE:$PATH"

# (e) 先驗 guard 本身：已設定的不動、沒設定的換 stub
set_val="$OUTSIDE/already-set"
out="$(env -u DEEP_RUN_BIN -u DISPATCH_DEEP_RUN_BIN -u CLAUDE_BIN TMUX_BIN="$set_val" bash -c '. "$1" "$2"; printf "%s|%s|%s|%s|%s\n" "$MYTHOS_TEST_SANDBOX" "$TMUX_BIN" "$DEEP_RUN_BIN" "$DISPATCH_DEEP_RUN_BIN" "$CLAUDE_BIN"' _ "$ROOT/tests/lib-test-guard.sh" "$TMP/e")"
IFS='|' read -r e_sb e_tmux e_deep e_disp e_claude <<< "$out"
[ "$e_sb" = "$TMP/e" ] || fail "(e) MYTHOS_TEST_SANDBOX 不對：$e_sb"
[ "$e_tmux" = "$set_val" ] || fail "(e) guard 覆蓋了已設定的 TMUX_BIN：$e_tmux"
case "$e_deep" in "$TMP/e"/*) ;; *) fail "(e) 沒設的 DEEP_RUN_BIN 沒換成 sandbox stub：$e_deep" ;; esac
case "$e_disp" in "$TMP/e"/*) ;; *) fail "(e) 沒設的 DISPATCH_DEEP_RUN_BIN 沒換成 sandbox stub：$e_disp" ;; esac
case "$e_claude" in "$TMP/e"/*) ;; *) fail "(e) 沒設的 CLAUDE_BIN 沒換成 sandbox stub：$e_claude" ;; esac
MYTHOS_TEST_SANDBOX="$TMP/e" "$e_deep" x y; grep -q 'x y' "$TMP/e/stub-calls.log" || fail '(e) stub 沒把 argv 記進 stub-calls.log'

# (a) 每支呼叫 bin/dispatch* 的測試都要 source guard（行首就是 source 指令，不能被註解掉）
list="$(grep -l 'bin/dispatch' "$ROOT"/tests/*.sh | grep -v -e '/test-test-guard\.sh$' -e '/lib-test-guard\.sh$')"
[ -n "$list" ] || fail '(a) 清單是空的，grep 算錯了'
missing=''
for f in $list; do
  grep -qE '^\. "\$\(dirname "\$0"\)/lib-test-guard\.sh" "\$TMP"' "$f" || missing="$missing $(basename "$f")"
done
[ -z "$missing" ] || fail "(a) 這些測試沒 source lib-test-guard.sh：$missing"
# 工單 D：呼叫 bin/dispatch-bg 的測試也要在清單裡（子字串 bin/dispatch 涵蓋），逐支核對
for need in test-dispatch-bg.sh test-dispatch-bg-watch.sh test-dispatch-bg-e2e.sh; do
  printf '%s\n' "$list" | grep -q "/$need\$" || fail "(a) 動態清單漏了 $need"
done
bglist="$(grep -l 'bin/dispatch-bg' "$ROOT"/tests/*.sh | grep -v -e '/test-test-guard\.sh$' -e '/lib-test-guard\.sh$')"
for f in $bglist; do printf '%s\n' "$list" | grep -qxF "$f" || fail "(a) 呼叫 dispatch-bg 的 $(basename "$f") 不在清單"; done
echo "(a) ok：$(printf '%s\n' "$list" | wc -l | tr -d ' ') 支測試都有 source guard"

# 以下在守門下跑
export MYTHOS_DIR="$TMP/mythos"
export DCQ_HOME="$TMP/dcq"
mkdir -p "$MYTHOS_DIR/state/deep" "$DCQ_HOME"
unset DEEP_RUN_BIN DISPATCH_DEEP_RUN_BIN TMUX_BIN CLAUDE_BIN
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"
TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
: > "$TMP/t.md"; mkdir -p "$TMP/cwd"

# (b) runner 指 repo 的 bin/dispatch-deep-run → exit 97、ledger 沒寫任何列
rc=0
DISPATCH_HARD_BACKEND=deep DISPATCH_DEEP_RUN_BIN="$ROOT/bin/dispatch-deep-run" bash "$ROOT/bin/dispatch" "$TMP/t.md" "$TMP/cwd" hard >/dev/null 2>"$TMP/b.err" || rc=$?
[ "$rc" = 97 ] || fail "(b) dispatch hard 用 sandbox 外 runner 應 exit 97，得到 $rc"
grep -q '測試模式拒跑真 runner' "$TMP/b.err" || fail "(b) 沒印拒跑訊息：$(cat "$TMP/b.err")"
if [ -f "$TSV" ] && grep -q 'pending' "$TSV"; then fail "(b) ledger 寫了 pending：$(cat "$TSV")"; fi
[ -z "$(ls -A "$MYTHOS_DIR/state/deep")" ] || fail "(b) state/deep 有檔：$(ls "$MYTHOS_DIR/state/deep")"
echo '(b) ok'

# (c) 直接跑 wrapper：下一層 DEEP_RUN_BIN 在 sandbox 外、或沒設 → exit 97、不寫任何 state
for mode in outside unset; do
  rc=0
  if [ "$mode" = outside ]; then
    DEEP_RUN_BIN="$OUTSIDE/deep-run" bash "$ROOT/bin/dispatch-deep-run" c-1 "$TMP/t.md" "$TMP/cwd" 2>"$TMP/c.err" || rc=$?
  else
    env -u DEEP_RUN_BIN bash "$ROOT/bin/dispatch-deep-run" c-1 "$TMP/t.md" "$TMP/cwd" 2>"$TMP/c.err" || rc=$?
  fi
  [ "$rc" = 97 ] || fail "(c/$mode) dispatch-deep-run 應 exit 97，得到 $rc"
  grep -q '測試模式拒跑真 runner' "$TMP/c.err" || fail "(c/$mode) 沒印拒跑訊息"
  [ -z "$(ls -A "$MYTHOS_DIR/state/deep")" ] || fail "(c/$mode) state/deep 有檔：$(ls "$MYTHOS_DIR/state/deep")"
done
echo '(c) ok'

# (d) dispatch-watch：queued 可拉起、runner 在 sandbox 外 → exit 97、ledger 原文不變
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' d-1 hard "$TMP/t.md" "$(date +%s)" queued "$TMP/cwd" - deep > "$TSV"
cp "$TSV" "$TMP/d.before"
rc=0
DISPATCH_DEEP_RUN_BIN="$ROOT/bin/dispatch-deep-run" MYTHOS_TRANSCRIPT_DIR="$TMP/router" CLAUDE_PROJECTS_DIR="$TMP/projects" \
  bash "$ROOT/bin/dispatch-watch" 2>"$TMP/d.err" 9>&- || rc=$?
[ "$rc" = 97 ] || fail "(d) dispatch-watch 用 sandbox 外 runner 拉 queued 應 exit 97，得到 $rc"
cmp -s "$TSV" "$TMP/d.before" || fail "(d) ledger 被改了：$(cat "$TSV")"
[ ! -d "$MYTHOS_DIR/state/.dispatch-watch.lock" ] || fail '(d) exit 97 後 watch 鎖沒放'
echo '(d) ok'

# (f) 守門前置（F5＋F4）：逾時 deep pending（無 handle 無 rc）＋同 cwd queued，runner 指 repo 的真 runner
#     → exit 97；ledger 原文不變、state/deep 沒有新 rc、events 檔不存在或不變
mkdir -p "$TMP/fcwd"
old=$(( $(date +%s) - 200 ))
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' f-1 hard "$TMP/t.md" "$old" pending "$TMP/fcwd" - deep > "$TSV"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' f-2 hard "$TMP/t.md" "$(date +%s)" queued "$TMP/fcwd" - deep >> "$TSV"
cp "$TSV" "$TMP/f.before"
before_deep="$(ls -A "$MYTHOS_DIR/state/deep" 2>/dev/null)"
before_events=''
[ -f "$MYTHOS_DIR/state/events.jsonl" ] && before_events="$TMP/f.events" && cp "$MYTHOS_DIR/state/events.jsonl" "$before_events"
rc=0
DISPATCH_DEEP_RUN_BIN="$ROOT/bin/dispatch-deep-run" MYTHOS_TRANSCRIPT_DIR="$TMP/router" CLAUDE_PROJECTS_DIR="$TMP/projects" \
  bash "$ROOT/bin/dispatch-watch" 2>"$TMP/f.err" 9>&- || rc=$?
[ "$rc" = 97 ] || fail "(f) 守門沒前置，得到 $rc"
grep -q '測試模式拒跑真 runner' "$TMP/f.err" || fail "(f) 沒印拒跑訊息：$(cat "$TMP/f.err")"
cmp -s "$TSV" "$TMP/f.before" || fail "(f) ledger 被改了：$(cat "$TSV")"
[ "$(ls -A "$MYTHOS_DIR/state/deep" 2>/dev/null)" = "$before_deep" ] || fail "(f) state/deep 有新增：$(ls -A "$MYTHOS_DIR/state/deep")"
if [ -n "$before_events" ]; then cmp -s "$MYTHOS_DIR/state/events.jsonl" "$before_events" || fail '(f) events 被改了'
elif [ -f "$MYTHOS_DIR/state/events.jsonl" ]; then fail '(f) 新建了 events 檔'; fi
echo '(f) ok'

# (g) TMUX_BIN 在 sandbox 外 → 一樣 exit 97、ledger 不變
cp "$TMP/f.before" "$TSV"
rc=0
TMUX_BIN=/usr/bin/true bash "$ROOT/bin/dispatch-watch" 2>"$TMP/g.err" 9>&- || rc=$?
[ "$rc" = 97 ] || fail "(g) sandbox 外的 TMUX_BIN 應 exit 97，得到 $rc"
cmp -s "$TSV" "$TMP/f.before" || fail '(g) ledger 被改了'
echo '(g) ok'

# (h) CLAUDE_BIN 在 sandbox 外（工單 D）
printf '#!/bin/sh\necho "$0 $*" >> "%s/outside-calls.log"\necho 0491f0d0-0000\nexit 0\n' "$OUTSIDE" > "$OUTSIDE/claude"
chmod +x "$OUTSIDE/claude"
mkdir -p "$TMP/worker/.claude"; printf '{}\n' > "$TMP/worker/.claude/hard.json"
export MYTHOS_WORKER_DIR="$TMP/worker"
: > "$TSV"; cp "$TSV" "$TMP/h.before"
rc=0
DISPATCH_HARD_BACKEND=bg CLAUDE_BIN="$OUTSIDE/claude" bash "$ROOT/bin/dispatch" "$TMP/t.md" "$TMP/cwd" hard >/dev/null 2>"$TMP/h1.err" || rc=$?
[ "$rc" = 97 ] || fail "(h) dispatch hard（bg-hard）用 sandbox 外 claude 應 exit 97，得到 $rc"
cmp -s "$TSV" "$TMP/h.before" || fail "(h) dispatch hard 寫了 ledger：$(cat "$TSV")"
rc=0
CLAUDE_BIN="$OUTSIDE/claude" bash "$ROOT/bin/dispatch-bg" t-h "$TMP/t.md" >/dev/null 2>"$TMP/h2.err" || rc=$?
[ "$rc" = 97 ] || fail "(h) dispatch-bg 用 sandbox 外 claude 應 exit 97，得到 $rc"
cmp -s "$TSV" "$TMP/h.before" || fail '(h) dispatch-bg 寫了 ledger'
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' bg-0491f0d0 mid "$TMP/t.md" "$(date +%s)" pending "$TMP/worker" t-h bg > "$TSV"
cp "$TSV" "$TMP/h.before"
rc=0
CLAUDE_BIN="$OUTSIDE/claude" MYTHOS_TRANSCRIPT_DIR="$TMP/router" CLAUDE_PROJECTS_DIR="$TMP/projects" \
  bash "$ROOT/bin/dispatch-watch" 2>"$TMP/h3.err" 9>&- || rc=$?
[ "$rc" = 97 ] || fail "(h) dispatch-watch 有 bg 列、claude 在 sandbox 外應 exit 97，得到 $rc"
cmp -s "$TSV" "$TMP/h.before" || fail '(h) dispatch-watch 改了 ledger'
rc=0
CLAUDE_BIN="$OUTSIDE/claude" bash "$ROOT/bin/dispatch-cancel" bg-0491f0d0 >/dev/null 2>"$TMP/h4.err" || rc=$?
[ "$rc" = 97 ] || fail "(h) dispatch-cancel bg 列、claude 在 sandbox 外應 exit 97，得到 $rc"
cmp -s "$TSV" "$TMP/h.before" || fail '(h) dispatch-cancel 改了 ledger'
echo '(h) ok'

# (i) DCQ_BIN 在 sandbox 外（11-07：hard 預設改走 O）→ dispatch mid／hard 都 exit 97、ledger 不動
printf '#!/bin/sh\necho "$0 $*" >> "%s/outside-calls.log"\necho job-x\n' "$OUTSIDE" > "$OUTSIDE/dcq"; chmod +x "$OUTSIDE/dcq"
: > "$TSV"; cp "$TSV" "$TMP/i.before"
for t in mid hard; do
  rc=0
  env -u DISPATCH_HARD_BACKEND LINT_SKIP=1 DCQ_BIN="$OUTSIDE/dcq" bash "$ROOT/bin/dispatch" "$TMP/t.md" "$TMP/cwd" "$t" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 97 ] || fail "(i) dispatch $t 用 sandbox 外 dcq 應 exit 97，得到 $rc"
done
cmp -s "$TSV" "$TMP/i.before" || fail '(i) ledger 被改了'
echo '(i) ok'

[ ! -s "$OUTSIDE/outside-calls.log" ] || fail "sandbox 外的 deep-run 被叫到了：$(cat "$OUTSIDE/outside-calls.log")"
echo 'TEST-GUARD PASS'
