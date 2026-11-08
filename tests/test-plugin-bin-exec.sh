#!/usr/bin/env bash
# 外掛直接 exec 的 bin/* 在 git 裡必須是 100755。
# 外掛測試用的假執行檔自己 chmod 755，蓋不到真檔權限；真檔 644 時「詳細」與收件匣 TG 退路都會 PermissionError（11-08）。
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0 n=0
for p in profiles/*/plugins/*/__init__.py; do
  for name in $(grep -o 'os.path.join(MYTHOS, "bin", "[^"]*")' "$p" | sed 's/.*"bin", "\([^"]*\)")/\1/' | sort -u); do
    n=$((n+1))
    mode="$(git ls-files -s "bin/$name" | awk '{print $1}')"
    if [ "$mode" != 100755 ]; then echo "FAIL: bin/$name 是 ${mode:-未追蹤}，$p 會直接執行它"; fail=1; fi
  done
done
[ "$n" -gt 0 ] || { echo "FAIL: 沒抽到任何外掛 bin 呼叫"; exit 1; }
[ "$fail" = 0 ] && echo "PLUGIN-BIN-EXEC PASS ($n)"
exit "$fail"
