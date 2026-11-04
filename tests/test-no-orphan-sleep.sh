#!/usr/bin/env bash
# 回歸：test_p1_harness.sh 中途 fail（P1_FORCE_FAIL_AT=23）時，已起的背景 sleep 不能變孤兒（ppid=1）。
# 只認自己：harness 的 sleep 秒數是 600.<PID>（P1_SLEEP_TAG），這裡只計 args 精確等於本次 tag 的孤兒；
# 別的 harness 並行留下來的 sleep 600 不算（11-04 單次假陽性）。
# 突變驗證：拿掉 EXIT trap 裡的 kill → 這支必 FAIL。
#   （trap 的收屍清單是「這個行程起的背景 pid」，不含 sleep 本身：kill 拿掉、harness 被 SIGPIPE 殺掉時，
#    背景 sleep 的 ppid 變 1，正好就是這裡要抓的東西。）
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

orphans() { ps -A -o pid=,ppid=,command= | awk -v t="$TAG" '$2==1 { sub(/^[ \t]+/, ""); c=$0; sub(/^[0-9]+ +[0-9]+ +/, "", c); if (c=="sleep " t) print $1 }'; }

TAG="600.$$"
set +e
P1_SLEEP_TAG="$TAG" P1_FORCE_FAIL_AT=23 bash "$ROOT/tests/test_p1_harness.sh" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" != 0 ] || { echo 'FAIL: P1_FORCE_FAIL_AT=23 竟然 exit 0' >&2; exit 1; }
sleep 1

new="$(orphans)"
if [ -n "$new" ]; then
  echo "FAIL: 留下孤兒 sleep $TAG:$new" >&2
  kill $new 2>/dev/null || true
  exit 1
fi
echo 'NO-ORPHAN PASS'
