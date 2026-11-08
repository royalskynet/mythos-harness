#!/usr/bin/env python3
"""mythos-tools 收件匣自檢：python3 test_inbox.py（純 python3、假 ctx、tmp MYTHOS_DIR、假 tg-send）。"""
import json
import os
import stat
import sys
import tempfile
import time

TMP = tempfile.mkdtemp()
INBOX = os.path.join(TMP, "state", "inbox")
os.makedirs(INBOX)
os.makedirs(os.path.join(TMP, "bin"))
TG_LOG = os.path.join(TMP, "tg-send.log")
TG_RC = os.path.join(TMP, "tg-send.rc")
TG = os.path.join(TMP, "bin", "tg-send")
with open(TG, "w") as f:
    f.write('#!/bin/sh\n'
            'printf "%s\\n" "$*" >> "$TG_LOG"\n'
            'echo "MYTHOS_DELIVER=${MYTHOS_DELIVER:-}" >> "$TG_LOG"\n'
            'cat >> "$TG_LOG"\n'
            'exit "$(cat "$TG_RC")"\n')
os.chmod(TG, os.stat(TG).st_mode | stat.S_IXUSR)
os.environ.update(MYTHOS_DIR=TMP, TG_LOG=TG_LOG, TG_RC=TG_RC,
                  BRIEF_LINES_DIR=os.path.join(TMP, "brief"))
with open(TG_RC, "w") as f:
    f.write("0")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.modules.pop("__init__", None)  # discover 時 test_dispatch 可能已快取另一份 MYTHOS_DIR
import __init__ as tools  # noqa: E402

tools.WARN_TSV = os.path.join(os.environ["BRIEF_LINES_DIR"], "mythos-inbox.tsv")
fail = lambda m: sys.exit("FAIL: " + m)


class Ctx:
    def __init__(self, ret=True):
        self.ret, self.calls = ret, []

    def inject_message(self, content, session_key=None):
        self.calls.append((content, session_key))
        return self.ret


def put(name, text="結果文字", ts=None, job="bg-x", thread="t-x"):
    p = os.path.join(INBOX, name)
    with open(p, "w") as f:
        json.dump({"thread": thread, "job": job, "text": text,
                   "ts": int((ts if ts is not None else time.time()) * 1000)}, f)
    return p


def where(name):
    for sub in ("", "sent", "done", "failed"):
        if os.path.exists(os.path.join(INBOX, sub, name)):
            return sub or "inbox"
    return None


with open(tools.SESSION_KEY_FILE, "w") as f:
    f.write("tg:42:99\n")
now = time.time()

# 1) 注入成功 → sent/（只代表已排程，要等 state.db 落地確認；11-08 審查 #3）
put("1-1.json")
ctx = Ctx(True)
tools.drain_inbox(ctx, now + 1)
assert where("1-1.json") == "sent", where("1-1.json")
assert json.load(open(os.path.join(INBOX, "sent", "1-1.json")))["sent_ts"] == now + 1
assert ctx.calls == [("[背景結果]\n結果文字", "tg:42:99")], ctx.calls
assert not os.path.exists(TG_LOG), "注入成功不該直送"

# 2) inject 回 False 且未滿 60 秒 → 留在原地、不直送
put("2-1.json")
tools.drain_inbox(Ctx(False), now + 30)
assert where("2-1.json") == "inbox", where("2-1.json")
assert not os.path.exists(TG_LOG)

# 3) 滿 60 秒 → 假 tg-send（MYTHOS_DELIVER=tg）並搬 done
tools.drain_inbox(Ctx(False), now + 61)
assert where("2-1.json") == "done", where("2-1.json")
log = open(TG_LOG).read()
assert "--thread t-x --job bg-x" in log and "MYTHOS_DELIVER=tg" in log and "結果文字" in log, log
os.unlink(TG_LOG)

# 4) 假 tg-send 失敗 → failed，告警檔有 ⚠
with open(TG_RC, "w") as f:
    f.write("1")
put("4-1.json")
tools.drain_inbox(Ctx(False), now + 120)
assert where("4-1.json") == "failed", where("4-1.json")
warn = open(tools.WARN_TSV).read()
assert "⚠" in warn and "bg-x" in warn, warn
with open(TG_RC, "w") as f:
    f.write("0")

# 5) 沒 session key → 等滿 60 秒直送（這裡只驗未滿 60 秒不動）
os.unlink(tools.SESSION_KEY_FILE)
put("5-1.json")
tools.drain_inbox(Ctx(True), now + 10)
assert where("5-1.json") == "inbox", where("5-1.json")

# 6) 壞檔不炸、也不搬
with open(os.path.join(INBOX, "6-1.json"), "w") as f:
    f.write("{壞掉")
tools.drain_inbox(Ctx(True), now + 999)
assert where("6-1.json") == "inbox", where("6-1.json")

# 7) inject 拋例外 → 不炸
os.makedirs(os.path.dirname(tools.SESSION_KEY_FILE), exist_ok=True)
with open(tools.SESSION_KEY_FILE, "w") as f:
    f.write("k\n")
put("7-1.json")


class Boom(Ctx):
    def inject_message(self, *a, **k):
        raise RuntimeError("boom")


tools.drain_inbox(Boom(True), now + 1)
assert where("7-1.json") == "inbox", where("7-1.json")

# 8) 只在 gateway 行程掃：CLI 的 inject 會進 CLI 佇列回 True（訊息被吞）
class _Mgr:
    def __init__(self, cli, gw):
        self._cli_ref = object() if cli else None
        self.has_gateway_message_injector = gw


class _MCtx:
    def __init__(self, cli, gw):
        self._manager = _Mgr(cli, gw)


assert tools._gateway_ready(_MCtx(False, True)) is True
assert tools._gateway_ready(_MCtx(True, True)) is False
assert tools._gateway_ready(_MCtx(False, False)) is False
assert tools._gateway_ready(object()) is False

# 9) sent/ 三態：臨時 state.db（結構同真庫 messages 的相關欄位）＋假 ctx
import sqlite3
DB = os.path.join(TMP, "state.db")
tools.STATE_DB = DB
con = sqlite3.connect(DB)
con.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, content TEXT, timestamp REAL NOT NULL)")
con.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL)")
con.executemany("INSERT INTO sessions(id, source) VALUES (?,?)", [("s", "telegram"), ("cli", "cli")])
con.commit()
SENT = os.path.join(INBOX, "sent")
os.makedirs(SENT, exist_ok=True)
for n in os.listdir(SENT):
    os.unlink(os.path.join(SENT, n))
for n in os.listdir(INBOX):
    if n.endswith(".json"):
        os.unlink(os.path.join(INBOX, n))


def put_sent(name, text, sent_ts):
    with open(os.path.join(SENT, name), "w") as f:
        json.dump({"thread": "t-x", "job": "bg-s", "text": text, "ts": int(sent_ts * 1000), "sent_ts": sent_ts}, f)


T = "落地測試" + "字" * 60  # 超過 40 字，驗證只比前 40 字
S0 = now + 1000
if os.path.exists(TG_LOG):
    os.unlink(TG_LOG)
# 9a) 已落地（user 訊息含前 40 字、時間 ≥ sent_ts）→ done，不直送
put_sent("9a.json", T, S0)
con.execute("INSERT INTO messages(session_id, role, content, timestamp) VALUES ('s','user',?,?)", ("[背景結果]\n" + T, S0 + 3))
con.commit()
tools.drain_inbox(Ctx(True), S0 + 5)
assert where("9a.json") == "done", where("9a.json")
assert not os.path.exists(TG_LOG), "已落地不該直送"
# 9b) 逾時未落地（只有舊訊息、或 assistant 訊息不算）→ 呼叫 fallback 並搬 done
T2 = "另一則結果" + "乙" * 60
put_sent("9b.json", T2, S0)
con.execute("INSERT INTO messages(session_id, role, content, timestamp) VALUES ('s','user',?,?)", (T2, S0 - 50))  # 早於 sent_ts
con.execute("INSERT INTO messages(session_id, role, content, timestamp) VALUES ('s','assistant',?,?)", (T2, S0 + 3))  # 非 user
con.commit()
tools.drain_inbox(Ctx(True), S0 + tools.FALLBACK_AFTER + 1)
assert where("9b.json") == "done", where("9b.json")
log = open(TG_LOG).read()
assert "--thread t-x --job bg-s" in log and "MYTHOS_DELIVER=tg" in log and "另一則結果" in log, log
os.unlink(TG_LOG)
# 9c) 未逾時且未落地 → 留在 sent，不直送
put_sent("9c.json", "還沒到時間的結果", S0)
tools.drain_inbox(Ctx(True), S0 + 10)
assert where("9c.json") == "sent", where("9c.json")
assert not os.path.exists(TG_LOG)
# 9d) 逾時未落地且直送失敗 → failed
with open(TG_RC, "w") as f:
    f.write("1")
tools.drain_inbox(Ctx(True), S0 + tools.FALLBACK_AFTER + 1)
assert where("9c.json") == "failed", where("9c.json")
with open(TG_RC, "w") as f:
    f.write("0")
# 9e) state.db 不存在 → 當未落地（不炸），逾時走直送
os.unlink(DB)
put_sent("9e.json", "庫不見了的結果", S0)
tools.drain_inbox(Ctx(True), S0 + 5)
assert where("9e.json") == "sent", where("9e.json")
# 9f) 別的 cli session 有相同 40 字前綴的 user 訊息 → 不算落地（11-08 G05）
if os.path.exists(TG_LOG):
    os.unlink(TG_LOG)
con = sqlite3.connect(DB)
con.execute("CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, content TEXT, timestamp REAL NOT NULL)")
con.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL)")
con.executemany("INSERT INTO sessions(id, source) VALUES (?,?)", [("s", "telegram"), ("cli", "cli")])
con.commit()
T3 = "共同前綴的結果" + "丙" * 60
put_sent("9f.json", T3, S0)
con.execute("INSERT INTO messages(session_id, role, content, timestamp) VALUES ('cli','user',?,?)", (T3[:40] + "（別人的）", S0 + 3))
con.commit()
tools.drain_inbox(Ctx(True), S0 + 10)
assert where("9f.json") == "sent", where("9f.json")
assert not os.path.exists(TG_LOG), "別 session 不算落地，未逾時不直送"
# 9g) telegram session 有完整文字才落地
con.execute("INSERT INTO messages(session_id, role, content, timestamp) VALUES ('s','user',?,?)", ("[背景結果]\n" + T3, S0 + 12))
con.commit()
tools.drain_inbox(Ctx(True), S0 + 20)
assert where("9f.json") == "done", where("9f.json")
assert not os.path.exists(TG_LOG), "已落地不該直送"
print("INBOX_OK")
