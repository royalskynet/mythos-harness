#!/usr/bin/env bash
# 把 launchd 範本的 __REPO__／__HOME__ 換成本機路徑，放進 ~/Library/LaunchAgents 並載入。
# NO_LOAD=1 只產檔不載入；LAUNCH_AGENTS_DIR 可改輸出位置（測試用）；ONLY=ai.mythos.watchdog 只處理那一份。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
mkdir -p "$OUT" "$ROOT/logs"
for tpl in "$ROOT"/launchd/*.plist; do
  name="$(basename "$tpl")"
  # ONLY：只換指定那一份，不碰其他 plist（11-04 Codex 二審：installer 不能重載全部）
  if [ -n "${ONLY:-}" ]; then
    label="${name%.plist}"
    [ "$ONLY" = "$name" ] || [ "$ONLY" = "$label" ] || continue
  fi
  sed -e "s#__REPO__#$ROOT#g" -e "s#__HOME__#$HOME#g" "$tpl" > "$OUT/$name"
  plutil -lint "$OUT/$name" >/dev/null
  if [ "${NO_LOAD:-0}" != 1 ]; then
    label="${name%.plist}"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true   # 沒載入過會失敗，正常
    launchctl bootstrap "gui/$(id -u)" "$OUT/$name" || { rc=$?; echo "bootstrap $label rc=${rc}（141／125＝停手查）" >&2; exit "$rc"; }
  fi
  echo "$OUT/$name"
done
