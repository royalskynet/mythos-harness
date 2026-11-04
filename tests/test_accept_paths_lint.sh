#!/usr/bin/env bash
# accept-paths-lint 自檢：舊 watchlist-watch.md 的過期 glob 必須被抓到，v2 必須乾淨。
set -u
here="$(cd "$(dirname "$0")" && pwd)"
lint="$here/../bin/accept-paths-lint"
old=~/bots/mythos/state/workorders/watchlist-watch.md
new=~/bots/mythos/state/workorders/watchlist-watch-v2.md
fail=0

out="$("$lint" "$old" 2>/dev/null)"; rc=$?
if [ "$rc" != 1 ] || ! printf '%s\n' "$out" | grep -q 'watchlist_watch.plist\*'; then
  echo "FAIL: 舊工單應 exit 1 並報 watchlist_watch.plist*（rc=$rc out=$out）"; fail=1
fi

out="$("$lint" "$new" 2>/dev/null)"; rc=$?
if [ "$rc" != 0 ] || [ -n "$out" ]; then
  echo "FAIL: v2 應 exit 0 且無輸出（rc=$rc out=$out）"; fail=1
fi

[ "$fail" = 0 ] && echo OK
exit "$fail"
