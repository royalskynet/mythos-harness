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

# #full 也過淨化（--sanitize-only）：斷裂用語／內部代號照刪，不縮短。本機 stub fetch，不連外、不送 TG。
FULLD="$(mktemp -d "${TMPDIR:-/tmp}/adhd-leak-full.XXXXXX")"
trap 'rm -f "$ERR"; rm -rf "$FULLD"' EXIT
printf '{"allowFrom":[123]}' > "$FULLD/access.json"
printf 'export const adhdLint = () => []\nexport const adhdTruncate = s => s\n' > "$FULLD/adhd-lint-stub.mjs"
printf 'export const record = () => {}\nexport const jobIds = () => []\nexport const envIds = () => []\n' > "$FULLD/lr.mjs"
# 探測器：adhd-lint 換成不攔的 stub（不然原樣送出也會過，證明不了淨化）；淨化子行程改跑工作樹那支真的
# --sanitize-only。路徑由獨立的 python 檔改寫（TMPDIR 可能為空、目錄很淺，別用 sed 塞絕對路徑）。
sed -e "s#from './adhd-lint.mjs'#from '$FULLD/adhd-lint-stub.mjs'#" \
    -e "s#from './lib-request.mjs'#from '$FULLD/lr.mjs'#" "$ROOT/bin/tg-send" > "$FULLD/tg-send.mjs"
cat > "$FULLD/patch.py" <<'PY'
import sys
path, real_lint = sys.argv[1], sys.argv[2]
t = open(path).read()
old = "path.join(path.dirname(fileURLToPath(import.meta.url)), 'adhd-lint.mjs'), '--sanitize-only'"
if old not in t:
    sys.exit('tg-send 的淨化呼叫改過，本段失效')
open(path, 'w').write(t.replace(old, repr(real_lint) + ", '--sanitize-only'"))
PY
python3 "$FULLD/patch.py" "$FULLD/tg-send.mjs" "$ROOT/bin/adhd-lint.mjs" || fail '#full 探測器組不起來（tg-send 的 #full 沒接淨化？）'
node --check "$FULLD/tg-send.mjs" || fail '#full 探測器組不起來'
cat > "$FULLD/hook.mjs" <<'JS'
import fs from 'node:fs'
import { syncBuiltinESMExports } from 'node:module'
globalThis.fetch = async (_u, o) => {
  fs.writeFileSync(process.env.TG_CAPTURE, JSON.parse(o.body).text)
  return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true, result: { message_id: 1 } }) }
}
syncBuiltinESMExports()  // tg-send 用 `import fs`，換掉的寫入要同步回 tg-send 拿到的同名物件
JS
send_full() { # 程式 收檔
  rm -f "$2"
  printf '#full\n已完成三件。\n派工 t-abc123 已送回結果。\n第三行照原樣保留，不縮短也不截斷。\n' \
    | MYTHOS_DIR="$FULLD" TELEGRAM_STATE_DIR="$FULLD" TELEGRAM_BOT_TOKEN=x TG_CAPTURE="$2" MYTHOS_DELIVER=tg \
      node --import "$FULLD/hook.mjs" "$1" --thread t-x --job j >/dev/null 2>"$FULLD/err.txt"
}
send_full "$FULLD/tg-send.mjs" "$FULLD/sent.txt" || fail "#full 送失敗：$(cat "$FULLD/err.txt")"
out="$(cat "$FULLD/sent.txt" 2>/dev/null || true)"
case "$out" in *派工*|*t-abc123*) fail "#full 送出內容仍含斷裂用語：$out" ;; esac
case "$out" in *已完成三件*) ;; *) fail "#full 正文被吃掉：$out" ;; esac
case "$out" in *不縮短也不截斷*) ;; *) fail "#full 不該縮短：$out" ;; esac
# 對照組：同一段內容、拿掉 #full 淨化那行 → 必須洩漏（證明上面那幾條擋得住）
sed 's#^if (fullMode) fullText = sanitizeOnly(fullText)$#// broken#' "$FULLD/tg-send.mjs" > "$FULLD/tg-send-broken.mjs"
grep -q '// broken' "$FULLD/tg-send-broken.mjs" || fail '複本沒拔掉淨化那行（tg-send 改過），本段失效'
send_full "$FULLD/tg-send-broken.mjs" "$FULLD/broken.txt" || true
case "$(cat "$FULLD/broken.txt" 2>/dev/null)" in *派工*) ;; *) fail '對照組沒洩漏（複本失效），本段證明不了淨化' ;; esac
echo '#full 淨化 ok'
