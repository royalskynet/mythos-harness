#!/usr/bin/env bash
# bin/worker-latency：首回延遲記帳＋慢的告警（假 state.db，不碰真的 worker）
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${WL_BIN:-$ROOT/bin/worker-latency}"
T="$(mktemp -d /tmp/test-wl.XXXXXX)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
export MYTHOS_DIR="$T/m" MYTHOS_WORKER_DB="$T/state.db" BRIEF_LINES_DIR="$T/brief"
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
mk s-wait $((now-30)) ''
mk s-old $((now-5*86400)) $((now-5*86400+200))

python3 "$BIN" || fail "rc≠0"
[ "$(wc -l < "$L" | tr -d ' ')" = 2 ] || fail "應記 2 筆（慢、快；未回與太舊不記）：$(cat "$L")"
grep -q $'^s-slow\t.*\t148.0\tdeepseek-v4.1-flash$' "$L" || fail "慢的那筆欄位不對：$(cat "$L")"
grep -q $'^s-fast\t.*\t9.0\t' "$L" || fail "快的那筆不對"
[ "$(wc -l < "$A" | tr -d ' ')" = 1 ] || fail "只有慢的要告警：$(cat "$A" 2>/dev/null)"
grep -q '⚠ 148s（deepseek-v4.1-flash，.*7 天內第 1 次）' "$A" || fail "告警格式：$(cat "$A")"

python3 "$BIN"
[ "$(wc -l < "$L" | tr -d ' ')" = 2 ] || fail "重跑不可重記"
[ "$(wc -l < "$A" | tr -d ' ')" = 1 ] || fail "重跑不可重複告警"

python3 - "$MYTHOS_WORKER_DB" "$((now-10))" <<'EOF'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.execute("insert into messages(session_id,role,timestamp) values('s-wait','assistant',?)",(float(sys.argv[2]),)); c.commit()
EOF
mk s-slow2 $((now-300)) $((now-180))
python3 "$BIN"
[ "$(wc -l < "$L" | tr -d ' ')" = 4 ] || fail "回了之後要補記：$(cat "$L")"
grep -q '⚠ 120s.*7 天內第 2 次' "$A" || fail "第二次慢要標第 2 次：$(cat "$A")"
[ "$(wc -l < "$A" | tr -d ' ')" = 2 ] || fail "s-wait 20s 不該告警"

rm -f "$MYTHOS_WORKER_DB"; python3 "$BIN" || fail "沒有 DB 要靜默 rc=0"
echo "WORKER-LATENCY PASS"
