#!/usr/bin/env bash
# 旋鈕：dispatch-watch 讀 state/watchdog-knobs.env，只認 DEEP_STALL_MIN／DEEP_REVIEW_MIN／DEEP_HANDOFF_SEC=純整數、不執行檔內容、
# 環境變數優先。斷言靠 DISPATCH_WATCH_PRINT_KNOBS=1 的只讀出口。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/watch-knobs.XXXXXX")"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"  # F1：沒設的 runner／tmux 換 guard stub（本檔只在單一指令前綴設 stub）
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/mythos/state"
printf '%s\n' 'DEEP_STALL_MIN=5' 'DEEP_REVIEW_MIN=abc' "touch $TMP/pwned" > "$TMP/mythos/state/watchdog-knobs.env"

out="$(env -u DEEP_STALL_MIN -u DEEP_REVIEW_MIN -u DEEP_HANDOFF_SEC -u BG_STALL_MIN MYTHOS_DIR="$TMP/mythos" DISPATCH_WATCH_PRINT_KNOBS=1 bash "$ROOT/bin/dispatch-watch")"
[ "$out" = 'DEEP_STALL_MIN=5 DEEP_REVIEW_MIN=30 DEEP_HANDOFF_SEC=120 BG_STALL_MIN=60' ] || { echo "FAIL: 旋鈕值不對：$out" >&2; exit 1; }
[ ! -e "$TMP/pwned" ] || { echo 'FAIL: knobs.env 內容被執行了' >&2; exit 1; }

out="$(env MYTHOS_DIR="$TMP/mythos" DEEP_STALL_MIN=9 DISPATCH_WATCH_PRINT_KNOBS=1 bash "$ROOT/bin/dispatch-watch")"
case "$out" in 'DEEP_STALL_MIN=9 '*) ;; *) echo "FAIL: 環境變數沒優先：$out" >&2; exit 1 ;; esac
# F3：DEEP_HANDOFF_SEC 在白名單內（檔內值生效），非整數不收
printf '%s\n' 'DEEP_HANDOFF_SEC=45' > "$TMP/mythos/state/watchdog-knobs.env"
out="$(env -u DEEP_STALL_MIN -u DEEP_REVIEW_MIN -u DEEP_HANDOFF_SEC -u BG_STALL_MIN MYTHOS_DIR="$TMP/mythos" DISPATCH_WATCH_PRINT_KNOBS=1 bash "$ROOT/bin/dispatch-watch")"
[ "$out" = 'DEEP_STALL_MIN=15 DEEP_REVIEW_MIN=30 DEEP_HANDOFF_SEC=45 BG_STALL_MIN=60' ] || { echo "FAIL: DEEP_HANDOFF_SEC 沒讀進白名單：$out" >&2; exit 1; }
printf '%s\n' 'DEEP_HANDOFF_SEC=1;x' > "$TMP/mythos/state/watchdog-knobs.env"
out="$(env -u DEEP_STALL_MIN -u DEEP_REVIEW_MIN -u DEEP_HANDOFF_SEC -u BG_STALL_MIN MYTHOS_DIR="$TMP/mythos" DISPATCH_WATCH_PRINT_KNOBS=1 bash "$ROOT/bin/dispatch-watch")"
[ "$out" = 'DEEP_STALL_MIN=15 DEEP_REVIEW_MIN=30 DEEP_HANDOFF_SEC=120 BG_STALL_MIN=60' ] || { echo "FAIL: DEEP_HANDOFF_SEC 非整數也被收：$out" >&2; exit 1; }
echo 'WATCH-KNOBS PASS'
