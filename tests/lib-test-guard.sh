#!/usr/bin/env bash
# 測試守門（F1）：被 source 後 export MYTHOS_TEST_SANDBOX="$1"（呼叫端傳自己的 TMP）。
# DISPATCH_DEEP_RUN_BIN／DEEP_RUN_BIN／TMUX_BIN 沒設定的，改指 guard 在 sandbox 自建的 stub；
# 已設定的一律不動（測試自己的 stub 要在 source 之前設好）。
# 已設定卻指到 sandbox 外的 runner，由 bin/dispatch、bin/dispatch-watch、bin/dispatch-deep-run
# 在 MYTHOS_TEST_SANDBOX 非空時 exit 97 擋下（tests/test-test-guard.sh 驗）。
# 用法：TMP="$(mktemp -d)" ; <設好自己的 stub> ; . "$(dirname "$0")/lib-test-guard.sh" "$TMP"
# stub 只把 argv（前面記 stub 名）追加到 $MYTHOS_TEST_SANDBOX/stub-calls.log 後 exit 0。

case "${1:-}" in
  /*) ;;
  *) echo "lib-test-guard: 要傳絕對路徑的 sandbox（現在是 '${1:-}'）" >&2; return 2 2>/dev/null || exit 2 ;;
esac
MYTHOS_TEST_SANDBOX="$1"
export MYTHOS_TEST_SANDBOX

_STUB_DIR="$MYTHOS_TEST_SANDBOX/.test-guard"
mkdir -p "$_STUB_DIR" || { echo "lib-test-guard: 建不了 $_STUB_DIR" >&2; return 1 2>/dev/null || exit 1; }

cat > "$_STUB_DIR/stub" <<'STUB'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >> "${MYTHOS_TEST_SANDBOX:?}/stub-calls.log"
exit 0
STUB
chmod +x "$_STUB_DIR/stub"

_guard_var() { # VAR 名稱：沒設定（或空字串）才換成 stub；已設定不動
  eval "_guard_v=\${$1:-}"
  if [ -z "$_guard_v" ]; then
    ln -sf stub "$_STUB_DIR/stub-$1"
    eval "export $1=\"\$_STUB_DIR/stub-$1\""
  fi
}
_guard_var DISPATCH_DEEP_RUN_BIN
_guard_var DEEP_RUN_BIN
_guard_var TMUX_BIN
unset _guard_v
unset -f _guard_var
