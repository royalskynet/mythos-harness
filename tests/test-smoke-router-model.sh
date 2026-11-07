#!/usr/bin/env bash
# smoke-router-model 判準：check_dispatch / check_relay 對照 tmp sqlite，不呼叫真模型。
set -u
cd "$(dirname "$0")/.." || exit 1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
DB="$TMP/state.db"
sqlite3 "$DB" <<'SQL'
CREATE TABLE sessions(id TEXT PRIMARY KEY, source TEXT NOT NULL, model TEXT, started_at REAL NOT NULL);
CREATE TABLE messages(id INTEGER PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL, tool_name TEXT);
SQL
SMOKE_LIB_ONLY=1 . bin/smoke-router-model
fails=0
ok() { if "$@" 2>/dev/null; then echo "ok   ${*:1}"; else echo "FAIL $*"; fails=$((fails+1)); fi; }
ng() { if "$@" 2>/dev/null; then echo "FAIL (應失敗) $*"; fails=$((fails+1)); else echo "ok   (預期失敗)"; fi; }

T0=1000
sqlite3 "$DB" "INSERT INTO sessions VALUES('t-late','telegram','flash',1500); INSERT INTO sessions VALUES('s-ok','oneshot','flash',1100);"
sqlite3 "$DB" "INSERT INTO messages(session_id,role,tool_name) VALUES('s-ok','tool','mythos_dispatch');"
ok check_dispatch "$DB" $T0 flash

rm -f "$DB"; sqlite3 "$DB" <<'SQL'
CREATE TABLE sessions(id TEXT PRIMARY KEY, source TEXT NOT NULL, model TEXT, started_at REAL NOT NULL);
CREATE TABLE messages(id INTEGER PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL, tool_name TEXT);
INSERT INTO sessions VALUES('t-late','telegram','flash',1500);
SQL
ng check_dispatch "$DB" $T0 flash

rm -f "$DB"; sqlite3 "$DB" <<'SQL'
CREATE TABLE sessions(id TEXT PRIMARY KEY, source TEXT NOT NULL, model TEXT, started_at REAL NOT NULL);
CREATE TABLE messages(id INTEGER PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL, tool_name TEXT);
INSERT INTO sessions VALUES('s-diff','oneshot','beam-free',1100);
INSERT INTO messages(session_id,role,tool_name) VALUES('s-diff','tool','mythos_dispatch');
SQL
ng check_dispatch "$DB" $T0 flash

ng check_relay '已完成：磁碟空間一事，工單已交出去。'
ng check_relay '這由 t-ab12 處理。'
ok check_relay '磁碟剩 120GB，主要被 Docker 映像佔掉。'
ng check_relay ''

echo "---"
[ $fails -eq 0 ] && echo "PASS test-smoke-router-model" || { echo "FAIL test-smoke-router-model ($fails)"; exit 1; }
