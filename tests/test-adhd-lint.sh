#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
lint() { printf '%s' "$1" | node "$ROOT/bin/adhd-lint.mjs" 2>"$ROOT/.adhd-lint-test.err"; }

# (a) 廢話實例 → exit 1 且含「客套句」
set +e
lint '老闆，所有未解的部分已經規劃好並派出去處理了，目前還在進行中，還沒全部完成。每張都會留紀錄，做完再跟您回報。正在進行中的單子不會動到，這邊目前沒有需要您決定的事。'
rc=$?; set -e
[ "$rc" = 1 ] || fail "(a1) 應 exit 1：$rc"
grep -q '客套句' "$ROOT/.adhd-lint-test.err" || fail "(a1) 應含客套句：$(cat "$ROOT/.adhd-lint-test.err")"
set +e
lint '目前還沒有動到任何設定，實際要怎麼改會等規劃那邊定出來。您可以先放心，後續有結果我再跟您回報。'
rc=$?; set -e
[ "$rc" = 1 ] || fail "(a2) 應 exit 1：$rc"
grep -q '客套句' "$ROOT/.adhd-lint-test.err" || fail "(a2) 應含客套句"

# (b) 合格
lint "$(printf '已完成兩件，剩一件今晚 02:00 跑。\n1. 計數腳本已上線\n2. 誤報已修\n3. 帳本改寫今晚 02:00')" || fail "(b)"

# (c) 短句
lint '收到' || fail "(c)"

# (d) 3 行但第 2 行沒編號
set +e; lint "$(printf '已完成兩件。\n計數腳本已上線\n誤報已修')"; rc=$?; set -e
[ "$rc" = 1 ] || fail "(d) 應 exit 1"
grep -q '編號' "$ROOT/.adhd-lint-test.err" || fail "(d) 應含編號"

# (e) 230 字（總長上限 220，8809759 改回後同步）
long="$(printf '%0230d' 0 | sed 's/0/字/g')"
set +e; lint "$long"; rc=$?; set -e
[ "$rc" = 1 ] || fail "(e) 應 exit 1"
grep -q '太長' "$ROOT/.adhd-lint-test.err" || fail "(e) 應含太長"

# (f) 11-07 實際長訊息
set +e
lint '待辦搬出的規劃單第三次成功了。這次改在獨立的工作副本跑，工單已寫好並通過派工前檢查，之後會自動派出執行單。'
rc=$?; set -e
[ "$rc" = 1 ] || fail "(f) 應 exit 1"

rm -f "$ROOT/.adhd-lint-test.err"
echo 'ADHD-LINT PASS'
