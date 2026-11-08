#!/usr/bin/env bash
# bin/worker-latency：首回延遲記帳＋慢的告警（假 state.db，不碰真的 worker）
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${WL_BIN:-$ROOT/bin/worker-latency}"
T="$(mktemp -d /tmp/test-wl.XXXXXX)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
export MYTHOS_DIR="$T/m" MYTHOS_WORKER_DB="$T/state.db" BRIEF_LINES_DIR="$T/brief" MYTHOS_WORKER_ALIVE=1
L="$MYTHOS_DIR/state/worker-latency.tsv"; A="$BRIEF_LINES_DIR/mythos-worker-latency.tsv"

mk() { # sid user_ts assistant_ts(空＝還沒回)
  python3 - "$MYTHOS_WORKER_DB" "$@" <<'EOF'
import sqlite3,sys
db,sid,u,a=sys.argv[1:5]
c=sqlite3.connect(db)
c.execute("create table if not exists messages(id integer primary key, session_id, role, timestamp)")
c.execute("create table if not exists session_model_usage(session_id, model, input_tokens, first_seen)")
c.execute("insert into messages(session_id,role,timestamp) values(?,?,?)",(sid,'user',float(u)))
if a:
  c.execute("insert into messages(session_id,role,timestamp) values(?,?,?)",(sid,'assistant',float(a)))
  c.execute("insert into session_model_usage values(?,?,?,?)",(sid,'aux',300,float(u)+2))
  c.execute("insert into session_model_usage values(?,?,?,?)",(sid,'deepseek-v4.1-flash',17954,float(a)))
c.commit()
EOF
}
now=$(date +%s)
mk s-slow $((now-600)) $((now-452))
mk s-fast $((now-500)) $((now-491))
mk s-still $((now-95)) ''   # 11-08 G09：逾 90 秒仍未回 → 告警一次
mk s-wait $((now-30)) ''
mk s-old $((now-5*86400)) $((now-5*86400+200))

python3 "$BIN" || fail "rc≠0"
[ "$(wc -l < "$L" | tr -d ' ')" = 3 ] || fail "應記 3 列（慢、快、未回的去重列；太舊不記）：$(cat "$L")"
grep -q $'^s-still-stall\t' "$L" && ! grep -q $'^s-wait' "$L" || fail "只有逾時未回的寫去重列：$(cat "$L")"
grep -q $'^s-slow\t.*\t148.0\tdeepseek-v4.1-flash$' "$L" || fail "慢的那筆欄位不對：$(cat "$L")"
grep -q $'^s-fast\t.*\t9.0\t' "$L" || fail "快的那筆不對"
[ "$(wc -l < "$A" | tr -d ' ')" = 2 ] || fail "慢的首回＋逾時未回各告一次：$(cat "$A" 2>/dev/null)"
grep -q '⚠ 148s（deepseek-v4.1-flash，.*7 天內第 1 次）' "$A" || fail "告警格式：$(cat "$A")"
grep -q '首回逾 90 秒仍未回.*⚠ s-still' "$A" || fail "逾時未回告警：$(cat "$A")"

python3 "$BIN"
[ "$(wc -l < "$L" | tr -d ' ')" = 3 ] || fail "重跑不可重記（多的那列是 s-still 的去重列）：$(cat "$L")"
[ "$(wc -l < "$A" | tr -d ' ')" = 2 ] || fail "重跑不可重複告警（含未回）：$(cat "$A")"

python3 - "$MYTHOS_WORKER_DB" "$((now-10))" <<'EOF'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.execute("insert into messages(session_id,role,timestamp) values('s-wait','assistant',?)",(float(sys.argv[2]),))
c.execute("insert into messages(session_id,role,timestamp) values('s-still','assistant',?)",(float(sys.argv[2])-7,)); c.commit()
EOF
mk s-slow2 $((now-300)) $((now-180))
python3 "$BIN"
[ "$(wc -l < "$L" | tr -d ' ')" = 6 ] || fail "回了之後要補記（含 stall 去重列）：$(cat "$L")"
grep -q $'^s-still\t.*\t[0-9]' "$L" || fail "s-still 回了要補記秒數：$(cat "$L")"
grep -q '⚠ 120s.*7 天內第 2 次' "$A" || fail "第二次慢要標第 2 次：$(cat "$A")"
[ "$(wc -l < "$A" | tr -d ' ')" = 3 ] || fail "s-wait 20s 不該告警、s-still 回了不再重告：$(cat "$A")"
[ "$(grep -c 's-still' "$A")" = 1 ] || fail "s-still 只該告一次：$(cat "$A")"

# 沒有 worker 行程（被取消／被殺）：不報仍未回
rm -rf "$T/m2" "$T/b2" "$T/db2"; mkdir -p "$T/m2"
MYTHOS_WORKER_DB="$T/db2" mk s-dead $((now-200)) ''
MYTHOS_DIR="$T/m2" MYTHOS_WORKER_DB="$T/db2" BRIEF_LINES_DIR="$T/b2" MYTHOS_WORKER_ALIVE=0 python3 "$BIN" || fail "dead rc≠0"
[ ! -s "$T/b2/mythos-worker-latency.tsv" ] || fail "沒有 worker 行程不該報仍未回：$(cat "$T/b2/mythos-worker-latency.tsv")"
# 沙箱 MYTHOS_DIR 卻沒覆寫 worker 庫（測試跑 dispatch-watch）：整支跳過，不讀真庫、不寫告警
out="$(env -u MYTHOS_WORKER_DB MYTHOS_DIR="$T/m3" BRIEF_LINES_DIR="$T/b3" python3 "$BIN" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$T/b3" ] && [ ! -e "$T/m3/state/worker-latency.tsv" ] || fail "沙箱未覆寫 DB 要跳過：rc=$rc $out"

rm -f "$MYTHOS_WORKER_DB"; out="$(python3 "$BIN" 2>&1)"; rc=$?
[ "$rc" = 3 ] || fail "DB 不存在要 rc=3，實得 $rc：$out"
echo "$out" | grep -q 'telemetry_unavailable' || fail "stderr 要含 telemetry_unavailable：$out"
printf 'not a db' > "$MYTHOS_WORKER_DB"; out="$(python3 "$BIN" 2>&1)"; rc=$?
[ "$rc" = 3 ] && echo "$out" | grep -q 'telemetry_unavailable' || fail "壞 DB 要 rc=3＋telemetry_unavailable：$rc $out"
echo "WORKER-LATENCY PASS"
