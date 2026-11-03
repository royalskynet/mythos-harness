#!/usr/bin/env bash
# 回歸：test_p1_harness.sh 中途 fail（P1_FORCE_FAIL_AT=23）時，已起的背景 sleep 600 不能變孤兒（ppid=1）。
# 突變驗證：拿掉 EXIT trap 裡的 kill → 這支必 FAIL。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

orphans() { ps -A -o pid=,ppid=,command= | awk '$2==1 { sub(/^[ \t]+/, ""); c=$0; sub(/^[0-9]+ +[0-9]+ +/, "", c); if (c=="sleep 600") print $1 }'; }

before="$(orphans)"
set +e
P1_FORCE_FAIL_AT=23 bash "$ROOT/tests/test_p1_harness.sh" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" != 0 ] || { echo 'FAIL: P1_FORCE_FAIL_AT=23 竟然 exit 0' >&2; exit 1; }
sleep 1

new=""
for p in $(orphans); do
  case "
$before
" in *"
$p
"*) ;; *) new="$new $p" ;; esac
done
if [ -n "$new" ]; then
  echo "FAIL: 留下孤兒 sleep 600:$new" >&2
  kill $new 2>/dev/null || true
  exit 1
fi
echo 'NO-ORPHAN PASS'
