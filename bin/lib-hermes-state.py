#!/usr/bin/env python3
"""Hermes state.db 唯讀查詢（N11／N12，11-08）。watchdog、dispatch-watch、hermes-contract 共用。

只開 `file:...?mode=ro`，不寫庫、不印訊息內容。子指令（stdout 一行，exit 0；只有用法錯才非零）：
  schema <db>                          表／欄是否齊（REQUIRED_SCHEMA）→ OK ／ FAIL <原因>
  router-silent <db> <silent_min> <now>
      最近一則 TG 使用者訊息之後，超過 silent_min 分鐘沒有 assistant 最終回覆 → SILENT <t0> <分鐘> <HH:MM>
      沒有超時／已回覆 → OK ；庫打不開、schema 不符、查詢錯 → UNAVAILABLE <kind> <原因>（絕不當 OK）
  worker-loop <db> <rkey> <N>          找 rkey 對應的 worker session，看尾端連續同名同結果的工具呼叫
      → LOOP <進度字串> ／ NOLOOP <尾端連續次數> ／ UNKNOWN <原因>

job↔session 對應（worker-loop）：dispatch-bg 把結果檔路徑 state/bg/r-<rk>.result 寫進 prompt，
    rk 存在 state/bg/<sid>.rkey；worker 的 user 訊息含這串字，即唯一對應。對不到或多於一個 → UNKNOWN。
結果比對：tool 列的 content 只在記憶體算 sha1，不回傳、不印、不寫檔。
"""
import hashlib
import os
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

TPE = timezone(timedelta(hours=8))

# 唯一的 schema 依賴清單：表名 → 本程式會讀的欄位。hermes-contract 與下面查詢都以它為準。
REQUIRED_SCHEMA = {
    "sessions": ("id", "source", "started_at"),
    "messages": ("id", "session_id", "role", "content", "tool_calls", "tool_name", "timestamp", "display_kind"),
}


def _connect(db):
    if not os.path.exists(db):
        return None, "missing", "庫檔不存在"
    try:
        return sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=2), None, None
    except sqlite3.Error as e:
        return None, "query", type(e).__name__


def _schema_problem(con):
    """回 None＝齊全；否則回原因字串。"""
    for table, cols in REQUIRED_SCHEMA.items():
        have = {r[1] for r in con.execute("PRAGMA table_info(%s)" % table).fetchall()}
        if not have:
            return "缺表 %s" % table
        miss = [c for c in cols if c not in have]
        if miss:
            return "表 %s 缺欄 %s" % (table, ",".join(miss))
    return None


def cmd_schema(db):
    con, kind, why = _connect(db)
    if con is None:
        return "FAIL %s：%s" % (kind, why)
    try:
        p = _schema_problem(con)
    except sqlite3.Error as e:
        return "FAIL query：%s" % type(e).__name__
    finally:
        con.close()
    return "OK" if p is None else "FAIL schema：%s" % p


def cmd_router_silent(db, silent_min, now):
    con, kind, why = _connect(db)
    if con is None:
        return "UNAVAILABLE %s %s" % (kind, why)
    try:
        p = _schema_problem(con)
        if p:
            return "UNAVAILABLE schema %s" % p
        t0 = con.execute(
            "SELECT MAX(m.timestamp) FROM messages m JOIN sessions s ON s.id = m.session_id"
            " WHERE s.source = 'telegram' AND m.role = 'user'"
            " AND COALESCE(m.display_kind, '') <> 'internal_notification'").fetchone()[0]
        if t0 is None:
            return "OK no-user"
        replied = con.execute(
            "SELECT COUNT(*) FROM messages m JOIN sessions s ON s.id = m.session_id"
            " WHERE s.source = 'telegram' AND m.role = 'assistant' AND m.tool_calls IS NULL"
            " AND COALESCE(m.display_kind, '') <> 'hidden' AND LENGTH(COALESCE(m.content, '')) > 0"
            " AND m.timestamp > ?", (t0,)).fetchone()[0]
    except sqlite3.Error as e:
        return "UNAVAILABLE query %s" % type(e).__name__
    finally:
        con.close()
    if replied:
        return "OK replied"
    mins = int((now - t0) // 60)
    if mins < silent_min:
        return "OK within-window"
    when = datetime.fromtimestamp(t0, TPE).strftime("%H:%M")
    return "SILENT %d %d %s" % (int(t0), mins, when)


def _fmt_t(ts):
    return datetime.fromtimestamp(ts, TPE).strftime("%H:%M:%S")


def cmd_worker_loop(db, rk, n):
    con, kind, why = _connect(db)
    if con is None:
        return "UNKNOWN %s %s" % (kind, why)
    try:
        p = _schema_problem(con)
        if p:
            return "UNKNOWN schema %s" % p
        needle = "r-%s.result" % rk
        rows = con.execute(
            "SELECT DISTINCT session_id FROM messages WHERE role = 'user' AND INSTR(content, ?) > 0", (needle,)
        ).fetchall()
        if not rows:
            return "UNKNOWN 找不到對應 session（尚未開工，或 prompt 沒含結果檔路徑）"
        if len(rows) > 1:
            return "UNKNOWN 結果檔路徑對到 %d 個 session，不可靠" % len(rows)
        sid = rows[0][0]
        tools = con.execute(
            "SELECT tool_name, timestamp, content FROM messages WHERE session_id = ? AND role = 'tool' ORDER BY id",
            (sid,)).fetchall()
    except sqlite3.Error as e:
        return "UNKNOWN query %s" % type(e).__name__
    finally:
        con.close()
    # 只留（名、時間、結果摘要）；結果摘要是 sha1，內容不離開這個迴圈
    seq = [(name or "?", ts, hashlib.sha1((c or "").encode("utf-8", "replace")).hexdigest()) for name, ts, c in tools]
    if not seq:
        return "NOLOOP 0"
    last = seq[-1]
    run = 0
    for item in reversed(seq):
        if item[0] != last[0] or item[2] != last[2]:
            break
        run += 1
    if run < n:
        return "NOLOOP %d" % run
    recent = "；".join("%s %s" % (name, _fmt_t(ts)) for name, ts, _ in seq[-8:])
    out = "LOOP 連續 %d 次同名同結果：%s（%s–%s）；最近工具（名稱與時間）：%s" % (
        run, last[0], _fmt_t(seq[-run][1]), _fmt_t(seq[-1][1]), recent)
    return out[:400]


def main(argv):
    if len(argv) == 3 and argv[1] == "schema":
        print(cmd_schema(argv[2]))
        return 0
    if len(argv) == 5 and argv[1] == "router-silent":
        print(cmd_router_silent(argv[2], float(argv[3]), float(argv[4])))
        return 0
    if len(argv) == 5 and argv[1] == "worker-loop":
        print(cmd_worker_loop(argv[2], argv[3], int(argv[4])).replace("\n", " ").replace("\t", " "))
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
