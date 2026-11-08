#!/usr/bin/env bash
# 11-07 Codex 審計：brief-answer 先 scrub（不通就不送任何 LLM）→ 免費模型 → haiku 墊底；
# --not-found 不叫模型；tg-send 1＝確定沒送（exit 7）、2＝不明（exit 8，呼叫端不再轉述）
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/brief.XXXXXX")"
trap 'rm -rf "$TMP"; [ -n "${SPID:-}" ] && kill "$SPID" 2>/dev/null; true' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export LC_ALL=C
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"
L="$TMP/calls.log"
printf '#!/bin/sh\necho "free-models" >> %s\nprintf "m1\\nm2\\nm3\\n"\n' "$L" > "$TMP/fm"
printf '#!/bin/sh\necho "free $1" >> %s\ncat > %s/free-in\n[ "$1" = "$FREE_OK" ] && echo "免費答：$1"\n[ "$1" = "$FREE_OK" ]\n' "$L" "$TMP" > "$TMP/fa"
printf '#!/bin/sh\necho "haiku" >> %s\ncat >/dev/null\necho "haiku 答"\n' "$L" > "$TMP/claude"
chmod +x "$TMP/fm" "$TMP/fa" "$TMP/claude"
# 假 scrub：把 0912-345-678 換成 <PHONE>
cat > "$TMP/scrub.py" <<'P'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        d = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        b = json.dumps({"texts": [t.replace("0912-345-678", "<PHONE>") for t in d["texts"]]}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H); print(s.server_port, flush=True); s.serve_forever()
P
python3 "$TMP/scrub.py" > "$TMP/port" & SPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/port" ] && break; sleep 0.2; done
export BRIEF_SCRUB="http://127.0.0.1:$(cat "$TMP/port")/scrub" BRIEF_FREE_MODELS="$TMP/fm" BRIEF_FREE_ASK="$TMP/fa" BRIEF_CLAUDE="$TMP/claude"
b() { : > "$L"; echo '電話 0912-345-678 的服務還在' | "$ROOT/bin/brief-answer" --stdout --kind quick --q '服務在嗎' "$@"; }
# 1) 免費第一名就成功：不叫 haiku，送出去的已去識別
out="$(FREE_OK=m1 b)"; [ "$out" = '免費答：m1' ] || fail "1：$out"
grep -q haiku "$L" && fail '1：免費成功還叫了 haiku'
grep -q '<PHONE>' "$TMP/free-in" && ! grep -q '0912' "$TMP/free-in" || fail '1：送免費模型前沒 scrub'
# 2) 免費只試前 2 名，都敗 → haiku
out="$(FREE_OK=m3 b)"; [ "$out" = 'haiku 答' ] || fail "2：$out"
[ "$(grep -c '^free ' "$L")" = 2 ] || fail "2：免費應只試 2 名：$(cat "$L")"
# 3) scrub 不通 → 不送任何 LLM，推原文
out="$(BRIEF_SCRUB=http://127.0.0.1:9/scrub FREE_OK=m1 b)"
grep -q -E '^(free|haiku)' "$L" && fail "3：scrub 不通還送了 LLM：$(cat "$L")"
[ "$out" = '電話 0912-345-678 的服務還在' ] || fail "3：應推原文：$out"
# 4) --not-found：固定句子，不叫任何模型
out="$(FREE_OK=m1 b --not-found)"; [ -n "$out" ] && [ ! -s "$L" ] || fail "4：not-found 叫了模型或沒輸出：$(cat "$L")"
# 5) tg-send 退出碼對應：1→7、2→8
mkdir -p "$TMP/b2"; cp "$ROOT/bin/brief-answer" "$TMP/b2/"
for pair in 1:7 2:8 0:0; do
  printf '#!/bin/sh\ncat >/dev/null\nexit %s\n' "${pair%%:*}" > "$TMP/b2/tg-send"; chmod +x "$TMP/b2/tg-send"
  rc=0; echo x | "$TMP/b2/brief-answer" --not-found --kind recall --q q 2>/dev/null || rc=$?
  [ "$rc" = "${pair##*:}" ] || fail "5：tg-send ${pair%%:*} 應得 ${pair##*:}，得到 $rc"
done

# 6) adhd-lint：stub 第一次回廢話、第二次回合格 → 送出的是第二次
cat > "$TMP/fa2" <<F
#!/bin/sh
cat >/dev/null
n="$TMP/fa2.n"; c=0; [ -f "\$n" ] && c=\$(cat "\$n"); c=\$((c+1)); echo "\$c" > "\$n"
if [ "\$c" = 1 ]; then
  echo '老闆，這件事已經處理好了。您可以放心，後續有結果我再跟您回報。這句特別長讓檢查一定不通過用來觸發重寫。'
else
  printf '已完成，約 10 分鐘內可查。\\n1. 服務正常\\n2. 不用再等'
fi
F
cp "$ROOT/bin/adhd-lint.mjs" "$TMP/adhd-lint.mjs"
chmod +x "$TMP/fa2"; rm -f "$TMP/fa2.n"
out="$( (env ADHD_LINT_BIN="$TMP/adhd-lint.mjs" BRIEF_SCRUB="$BRIEF_SCRUB" BRIEF_FREE_MODELS="$TMP/fm" BRIEF_FREE_ASK="$TMP/fa2" BRIEF_CLAUDE= BRIEF_FREE_MAX=1 "$ROOT/bin/brief-answer" --stdout --kind quick --q '狀況' < <(echo 資料)) )"
case "$out" in *'您可以放心'*) fail "6：應送第二次合格：$out" ;; esac
case "$out" in *'已完成'*) ;; *) fail "6：應含合格內容：$out" ;; esac
# 7) 兩次都廢話 → 照送且 stderr 含 adhd-lint 仍不過
printf '#!/bin/sh\ncat >/dev/null\necho "您可以放心，後續有結果我再跟您回報。這段話特別長特別囉嗦讓它一定不過檢查再長一點點。"\n' > "$TMP/fabad"
chmod +x "$TMP/fabad"
(env ADHD_LINT_BIN="$TMP/adhd-lint.mjs" BRIEF_SCRUB="$BRIEF_SCRUB" BRIEF_FREE_MODELS="$TMP/fm" BRIEF_FREE_ASK="$TMP/fabad" BRIEF_CLAUDE= BRIEF_FREE_MAX=1 "$ROOT/bin/brief-answer" --stdout --kind quick --q "狀況" < <(echo 資料) >"$TMP/bout7" 2>"$TMP/berr7") || true
grep -q "adhd-lint 仍不過" "$TMP/berr7" || fail "7：stderr 應含仍不過：$(cat "$TMP/berr7")"
[ -s "$TMP/bout7" ] || fail "7：仍應照送"

echo 'BRIEF-ANSWER PASS'
