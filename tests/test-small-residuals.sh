#!/usr/bin/env bash
# 11-08 殘留三項的驗收（全在 mktemp 沙箱：假 tg-send、假 worker 庫，不打 TG、不寫真告警檔）：
#   G03 mythos_full_text 只取「該 thread」最新全文（對照 state/tg-msg-thread.tsv），對不到才退回全域最新（Router 現行不帶 thread）
#   G06 dispatch-cancel hermes 沒有 pid 檔 → 非零（4）＋stderr 說明，ledger 不改
#   G09 worker-latency 頂層例外 → stderr＋exit 3（dispatch-watch 那行有 `|| true`，不擋派工）
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/small-residuals.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export MYTHOS_DIR="$TMP/mythos"
export BRIEF_LINES_DIR="$TMP/brief"
export MYTHOS_WORKER_DB="$TMP/worker.db"   # worker-latency 不讀真的 ~/.hermes 庫
mkdir -p "$MYTHOS_DIR/state/tg-full" "$MYTHOS_DIR/state/bg" "$MYTHOS_DIR/bin" "$BRIEF_LINES_DIR"
. "$(dirname "$0")/lib-test-guard.sh" "$TMP"
fail() { echo "FAIL: $*" >&2; exit 1; }

# ---- G03：mythos_full_text 只取該 thread 最新全文
# 假 tg-send：把 stdin（#full＋全文）記到 $TMP/tg.in，不送真 TG
cat > "$MYTHOS_DIR/bin/tg-send" <<STUB
#!/bin/sh
cat > "$TMP/tg.in"
echo 777
STUB
chmod +x "$MYTHOS_DIR/bin/tg-send"
TG_FULL="$MYTHOS_DIR/state/tg-full"
printf 'A 舊全文' > "$TG_FULL/101.txt"
printf 'B 全文' > "$TG_FULL/202.txt"
printf 'A 最新全文' > "$TG_FULL/303.txt"
printf '未對照的全域最新' > "$TG_FULL/404.txt"
touch -t 209901010000 "$TG_FULL/404.txt"   # 全域 mtime 最新，但沒有任何 thread 對到它
# mid 505 那則沒有全文檔（短回覆），要跳過，取 303
printf '42\t101\tt-aaaa\tbg-1\t1\n42\t202\tt-bbbb\tbg-2\t2\n42\t303\tt-aaaa\tbg-3\t3\n42\t505\tt-aaaa\tbg-4\t4\n' \
  > "$MYTHOS_DIR/state/tg-msg-thread.tsv"
rc=0; PYTHONDONTWRITEBYTECODE=1 python3 -I - "$ROOT/profiles/mythos/plugins/mythos-tools" "$TMP/tg.in" <<'PY' || rc=$?
import os
import sys

sys.path.insert(0, sys.argv[1])
tg_in = sys.argv[2]
import __init__ as tools  # noqa: E402


def sent():
    return open(tg_in, encoding="utf-8").read() if os.path.exists(tg_in) else None


out = tools.mythos_full_text({"thread": "t-aaaa"})
assert out == "已送全文", out
assert sent() == "#full\nA 最新全文", repr(sent())  # 不是全域最新 404、也不是舊 101
os.unlink(tg_in)

out = tools.mythos_full_text({"thread": "t-bbbb"})
assert out == "已送全文" and sent() == "#full\nB 全文", (out, sent())
os.unlink(tg_in)

# 對不到（Router 現行不帶 thread、outlet 的 <epoch>.txt 不在對照表）→ 退回全域最新，線上「詳細」不能壞
out = tools.mythos_full_text({})
assert out == "已送全文" and sent() == "#full\n未對照的全域最新", f"沒 thread 應退回全域最新：{out!r} {sent()!r}"
os.unlink(tg_in)

out = tools.mythos_full_text({"thread": "t-cccc"})
assert out == "已送全文" and sent() == "#full\n未對照的全域最新", f"對不到 thread 應退回全域最新：{out!r} {sent()!r}"
print("G03_OK")
PY
[ "$rc" = 0 ] || fail "G03 python 驗收失敗（見上方 traceback）"
echo "G03 ok"

# ---- G06：dispatch-cancel hermes 沒有 pid 檔 → 4、stderr 說明、ledger 不改
TSV="$MYTHOS_DIR/state/dispatch-jobs.tsv"
printf 'bg-d00d0001\t2026-11-08 10:00:00\t/x/p.md\t1\tpending\t-\tt-zz9\thermes\n' > "$TSV"
before="$(cat "$TSV")"
rc=0; err="$(bash "$ROOT/bin/dispatch-cancel" bg-d00d0001 2>&1 >/dev/null)" || rc=$?
[ "$rc" = 4 ] || fail "G06 沒 pid 檔應非零（4），實際 ${rc}：${err}"
case "${err}" in *"沒有 pid 檔"*) ;; *) fail "G06 stderr 沒說明：${err}" ;; esac
[ "$(cat "$TSV")" = "$before" ] || fail "G06 ledger 不該改"
echo "G06 ok"

# ---- G09：worker-latency 頂層例外 → stderr＋exit 3；正常路徑仍 0
python3 -I -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE messages(session_id TEXT, role TEXT, timestamp REAL)")
c.execute("CREATE TABLE session_model_usage(session_id TEXT, model TEXT, input_tokens INT)")
c.commit()' "$MYTHOS_WORKER_DB"
# 讓 ledger 路徑是目錄：run() 讀帳時拋 IsADirectoryError（非 sqlite 錯誤），落到頂層 except
mkdir "$MYTHOS_DIR/state/worker-latency.tsv"
rc=0; PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/bin/worker-latency" >/dev/null 2>"$TMP/wl.err" || rc=$?
[ "$rc" = 3 ] || fail "G09 頂層例外應 exit 3，實際 ${rc}：$(cat "$TMP/wl.err")"
grep -q '^worker-latency: IsADirectoryError' "$TMP/wl.err" || fail "G09 stderr 沒說明例外：$(cat "$TMP/wl.err")"
rmdir "$MYTHOS_DIR/state/worker-latency.tsv"
rc=0; PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/bin/worker-latency" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "G09 正常路徑應 exit 0，實際 $rc"
grep -q 'worker-latency" 2>>"\$WATCH_LOG" || true' "$ROOT/bin/dispatch-watch" \
  || fail "G09 dispatch-watch 呼叫 worker-latency 沒有 || true，非零會中斷派工"
echo "G09 ok"

echo "RESIDUALS_OK"
