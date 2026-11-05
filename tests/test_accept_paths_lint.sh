#!/usr/bin/env bash
# accept-paths-lint 自檢（自含 fixture，不依賴正式工單）：過期 glob 必須被抓到，路徑都在的必須乾淨。
set -u
here="$(cd "$(dirname "$0")" && pwd)"
lint="$here/../bin/accept-paths-lint"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/collectors"; : > "$tmp/collectors/real.py"
old="$tmp/old.md"; new="$tmp/new.md"
printf '## 驗收\n```bash\ncd %s\nls collectors/gone_watch.plist*\n```\n' "$tmp" > "$old"
printf '## 驗收\n```bash\ncd %s\nls collectors/real.py\n```\n' "$tmp" > "$new"
fail=0

out="$("$lint" "$old" 2>/dev/null)"; rc=$?
if [ "$rc" != 1 ] || ! printf '%s\n' "$out" | grep -q 'gone_watch.plist\*'; then
  echo "FAIL: 過期工單應 exit 1 並報 gone_watch.plist*（rc=$rc out=$out）"; fail=1
fi

out="$("$lint" "$new" 2>/dev/null)"; rc=$?
if [ "$rc" != 0 ] || [ -n "$out" ]; then
  echo "FAIL: 乾淨工單應 exit 0 且無輸出（rc=$rc out=$out）"; fail=1
fi

[ "$fail" = 0 ] && echo OK
exit "$fail"
