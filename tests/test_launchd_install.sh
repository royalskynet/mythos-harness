#!/usr/bin/env bash
# 驗收：launchd 範本只有佔位路徑，install.sh 換成本機路徑後是合法 plist、指到真的腳本。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
if grep -l -E '/Users/|/home/' "$ROOT"/launchd/*.plist; then fail "範本含寫死的家目錄"; fi
NO_LOAD=1 LAUNCH_AGENTS_DIR="$TMP" bash "$ROOT/launchd/install.sh" >/dev/null
n=0
for f in "$TMP"/*.plist; do
  n=$((n+1))
  if grep -q '__REPO__\|__HOME__' "$f"; then fail "$(basename "$f") 佔位沒換掉"; fi
  plutil -lint "$f" >/dev/null || fail "$(basename "$f") 不是合法 plist"
  script="$(plutil -extract ProgramArguments.1 raw "$f")"
  [ -f "$script" ] || fail "$(basename "$f") 指到不存在的 $script"
  [ "$(plutil -extract EnvironmentVariables.HOME raw "$f")" = "$HOME" ] || fail "$(basename "$f") HOME 沒換成本機"
done
[ "$n" -ge 2 ] || fail "應產出至少 2 份 plist，只有 $n"
echo "LAUNCHD-INSTALL PASS"
