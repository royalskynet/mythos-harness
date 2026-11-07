#!/usr/bin/env bash
# 11-07 回歸：全部資料與 runner 都在暫存目錄。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mythos-1107.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"
_guard_var DISPATCH_BG_BIN
_guard_var DISPATCH_CANCEL_BIN
_guard_var TG_SEND_BIN
python3 "$ROOT/tests/check_1107.py" mailbox
