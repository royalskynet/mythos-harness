#!/usr/bin/env bash
# 旋鈕：dispatch-watch 讀 state/watchdog-knobs.env，只認 DEEP_STALL_MIN／DEEP_REVIEW_MIN=純整數、不執行檔內容、
# 環境變數優先。斷言靠 DISPATCH_WATCH_PRINT_KNOBS=1 的只讀出口。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/watch-knobs.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/mythos/state"
printf '%s\n' 'DEEP_STALL_MIN=5' 'DEEP_REVIEW_MIN=abc' "touch $TMP/pwned" > "$TMP/mythos/state/watchdog-knobs.env"

out="$(env -u DEEP_STALL_MIN -u DEEP_REVIEW_MIN MYTHOS_DIR="$TMP/mythos" DISPATCH_WATCH_PRINT_KNOBS=1 bash "$ROOT/bin/dispatch-watch")"
[ "$out" = 'DEEP_STALL_MIN=5 DEEP_REVIEW_MIN=30' ] || { echo "FAIL: 旋鈕值不對：$out" >&2; exit 1; }
[ ! -e "$TMP/pwned" ] || { echo 'FAIL: knobs.env 內容被執行了' >&2; exit 1; }

out="$(env MYTHOS_DIR="$TMP/mythos" DEEP_STALL_MIN=9 DISPATCH_WATCH_PRINT_KNOBS=1 bash "$ROOT/bin/dispatch-watch")"
case "$out" in 'DEEP_STALL_MIN=9 '*) ;; *) echo "FAIL: 環境變數沒優先：$out" >&2; exit 1 ;; esac
echo 'WATCH-KNOBS PASS'
