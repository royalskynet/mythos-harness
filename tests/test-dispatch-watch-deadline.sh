#!/usr/bin/env bash
# 回歸（11-04）：dispatch-watch 一輪卡住時，launchd 不會起下一輪，投遞整個停擺（00:07 卡到 19:05）。
# 驗：DW_MAX_SEC=2、NODE_BIN 換成卡住的 stub → 10 秒內 exit 124、brief-lines 多一行、卡住的孫行程不留下。
# 對照：沒卡住的一輪照常 exit 0、不寫告警。突變：拿掉 perl 包裝或 process group kill → 這支必 FAIL。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dw-deadline.XXXXXX")"
TAG="31.$$"
trap 'pkids="$(pgrep -f "^sleep $TAG\$" || true)"; [ -n "$pkids" ] && kill $pkids 2>/dev/null; rm -rf "$TMP"' EXIT

export MYTHOS_DIR="$TMP/mythos"
export DCQ_HOME="$TMP/dcq"
export TMUX_BIN="$TMP/tmux"
export MYTHOS_TRANSCRIPT_DIR="$TMP/router-transcript"
export BRIEF_LINES_DIR="$TMP/brief"
printf '#!/bin/sh\nexit 0\n' > "$TMUX_BIN"; chmod +x "$TMUX_BIN"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"
mkdir -p "$MYTHOS_DIR/state" "$DCQ_HOME"/{done,failed,running,pending} "$MYTHOS_TRANSCRIPT_DIR"
: > "$MYTHOS_DIR/state/dispatch-jobs.tsv"   # 沒有 ledger 檔時 watcher 第一步就退出
LOCK="$MYTHOS_DIR/state/.dispatch-watch.lock"
fail() { echo "FAIL: $*" >&2; exit 1; }

# 對照：正常一輪
bash "$ROOT/bin/dispatch-watch" || fail "正常一輪 rc=$?"
[ ! -e "$BRIEF_LINES_DIR/mythos-watch.txt" ] || fail '正常一輪不該寫告警'
echo '(ctl) ok'

# 卡住的一輪：NODE_BIN 每輪必經（events scan），換成永遠不結束的 stub
printf '#!/bin/sh\nexec sleep %s\n' "$TAG" > "$TMP/hang-node"; chmod +x "$TMP/hang-node"
start=$(date +%s)
set +e; DW_MAX_SEC=2 NODE_BIN="$TMP/hang-node" bash "$ROOT/bin/dispatch-watch"; rc=$?; set -e
took=$(( $(date +%s) - start ))
[ "$rc" = 124 ] || fail "卡住的一輪應 exit 124：$rc"
[ "$took" -le 10 ] || fail "卡住的一輪花了 ${took}s"
grep -q 'dispatch-watch 一輪超過 2s 被終止' "$BRIEF_LINES_DIR/mythos-watch.txt" || fail '沒寫告警'
sleep 1
if pgrep -f "^sleep $TAG\$" >/dev/null; then fail '卡住的孫行程還活著'; fi
[ ! -e "$LOCK" ] || fail '卡住的一輪被殺後鎖還在'
echo '(hang) ok'

# 卡住的 stub 忽略 TERM：要靠 2 秒後的 KILL 收掉
printf '#!/bin/sh\ntrap "" TERM\nwhile :; do sleep %s; done\n' "$TAG" > "$TMP/hang-node"
set +e; DW_MAX_SEC=2 NODE_BIN="$TMP/hang-node" bash "$ROOT/bin/dispatch-watch"; rc=$?; set -e
[ "$rc" = 124 ] || fail "忽略 TERM 的一輪應 exit 124：$rc"
sleep 1
if pgrep -f "hang-node" >/dev/null || pgrep -f "^sleep $TAG\$" >/dev/null; then fail '忽略 TERM 的孫行程還活著'; fi
[ ! -e "$LOCK" ] || fail 'KILL 後鎖還在'
[ "$(grep -c 被終止 "$BRIEF_LINES_DIR/mythos-watch.txt")" -eq 2 ] || fail '第二次逾時沒寫告警'
echo '(hang-ignore-term) ok'

# 被殺之後下一輪照常跑
bash "$ROOT/bin/dispatch-watch" || fail "逾時後下一輪 rc=$?"
echo '(next) ok'
echo 'DW-DEADLINE PASS'
