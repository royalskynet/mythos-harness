#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
# 夾具照舊上限寫；預設值另在最後檢查
export ADHD_MAX_CHARS=220 ADHD_MAX_LINES=6 ADHD_MAX_LINE_CHARS=40
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

# (g) 預設上限 500 字／12 行／每行 60（11-08 放寬）：約 270 字、7 行的回覆要過（舊上限 220／6 會擋）
unset ADHD_MAX_CHARS ADHD_MAX_LINES ADHD_MAX_LINE_CHARS
mid="$(printf '%s\n' \
  '測試補好了，八個檔案都已經推上 GitHub，自動檢查也重新跑過一次。' \
  '1. 原因是卡住的判斷方式改了，對應的測試一直沒送出，所以雲端的檢查一直失敗。' \
  '2. 做法是先在本機把八個測試全部跑過一遍，確認都通過以後，再一起送出去。' \
  '3. 驗收方式是看雲端檢查有沒有轉綠，以及本機重跑兩次是不是都通過，兩項都已經確認。' \
  '4. 另外把字數上限放寬到五百字，之後回答「那是什麼」這類問題可以講完整。' \
  '5. 對應的格式測試也一起更新，改回舊上限時測試會失敗，避免以後被誤改回去。' \
  '你不用做任何事，之後再有東西卡住，系統會照新的方式判斷並提醒你。')"
lint "$mid" || fail "(g) 約 270 字、7 行應在預設上限內：$(cat "$ROOT/.adhd-lint-test.err")"

rm -f "$ROOT/.adhd-lint-test.err"
echo 'ADHD-LINT PASS'
