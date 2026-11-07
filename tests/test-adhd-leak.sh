#!/usr/bin/env bash
# 11-08b dsh 差距 #5：斷裂用語（工單／派工／後台／團隊／工作者／背景任務／job id／thread／t-代號／八碼 hex）。
# lint 失敗；--truncate 刪掉含該詞的句子；刪光回「好，我處理一下。」
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
LINT="$ROOT/bin/adhd-lint.mjs"
ERR="$(mktemp "${TMPDIR:-/tmp}/adhd-leak.XXXXXX")"; trap 'rm -f "$ERR"' EXIT
for w in 工單 派工 後台 團隊 工作者 背景任務 'job id' thread Thread; do
  set +e; printf '好的，這件事%s已經處理完了。\n' "$w" | node "$LINT" 2>"$ERR"; rc=$?; set -e
  [ "$rc" = 1 ] || fail "含「$w」應 lint 失敗：rc=$rc"
  grep -q '斷裂用語' "$ERR" || fail "含「$w」訊息應含斷裂用語：$(cat "$ERR")"
done
for w in 't-abcdef' 'deadbeef' '3f9a0c1b'; do
  set +e; printf '已完成備份，編號 %s 的那份放好了。\n' "$w" | node "$LINT" 2>"$ERR"; rc=$?; set -e
  [ "$rc" = 1 ] && grep -q '斷裂用語' "$ERR" || fail "含「$w」應 lint 失敗：rc=$rc $(cat "$ERR")"
done
# 不誤殺：日期／金額（純數字八碼）、short-term 這類英文字
printf '已完成對帳，20261108 的金額 12345678 元都對上了。\n' | node "$LINT" || fail '純數字八碼不該被當 hex 代號'
printf '已完成設定，short-term 的做法先用著。\n' | node "$LINT" || fail 'short-term 不該被當 t- 代號'
# 短句也要擋
set +e; printf '工單好了。\n' | node "$LINT" 2>/dev/null; rc=$?; set -e
[ "$rc" = 1 ] || fail "短句含斷裂詞也應失敗：rc=$rc"

# --truncate：只刪含詞的句子
out="$(printf '工單 t-abcdef 已交給後台團隊。\n' | node "$LINT" --truncate)"
[ "$out" = '好，我處理一下。' ] || fail "整句都是斷裂詞應回固定一句：$out"
printf '%s\n' "$out" | node "$LINT" || fail '固定句要過 lint'
out="$(printf '已完成備份。工單 t-abc123 已結案。明天 09:00 再跑一次。\n' | node "$LINT" --truncate)"
case "$out" in *工單*|*t-abc123*) fail "含詞句子沒刪：$out" ;; esac
case "$out" in *已完成備份。*明天\ 09:00\ 再跑一次。*) ;; *) fail "不含詞的句子應保留：$out" ;; esac
printf '%s' "$out" | node "$LINT" || fail '刪完要過 lint'
# 多行編號：含詞那條刪掉、重新編號
out="$(printf '已完成兩件事。\n1. 備份已做\n2. 後台團隊在處理\n3. 帳本已對\n' | node "$LINT" --truncate)"
case "$out" in *後台*|*團隊*) fail "編號行沒刪：$out" ;; esac
printf '%s\n' "$out" | grep -q '^2\. 帳本已對$' || fail "編號沒重排：$out"
# 過長又含詞：截斷後仍不含斷裂詞、且過 lint
long="已完成備份。$(printf '很長的說明內容%.0s' $(seq 1 60))。工單 t-abcdef 另外處理。"
out="$(printf '%s\n' "$long" | node "$LINT" --truncate)"
case "$out" in *工單*|*t-abcdef*) fail "過長又含詞：截斷後仍含斷裂詞：$out" ;; esac
printf '%s\n' "$out" | node "$LINT" || fail "過長又含詞：截斷後要過 lint：$out"
echo 'ADHD-LEAK PASS'
