#!/usr/bin/env bash
# 把 launchd 範本的 __REPO__／__HOME__ 換成本機路徑，放進 ~/Library/LaunchAgents 並載入。
# NO_LOAD=1 只產檔不載入；LAUNCH_AGENTS_DIR 可改輸出位置（測試用）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
mkdir -p "$OUT" "$ROOT/logs"
for tpl in "$ROOT"/launchd/*.plist; do
  name="$(basename "$tpl")"
  sed -e "s#__REPO__#$ROOT#g" -e "s#__HOME__#$HOME#g" "$tpl" > "$OUT/$name"
  plutil -lint "$OUT/$name" >/dev/null
  if [ "${NO_LOAD:-0}" != 1 ]; then
    launchctl bootout "gui/$(id -u)" "$OUT/$name" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$OUT/$name"
  fi
  echo "$OUT/$name"
done
