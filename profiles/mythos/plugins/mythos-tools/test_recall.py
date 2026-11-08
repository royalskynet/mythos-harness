#!/usr/bin/env python3
"""mythos_recall 自檢：python3 -B test_recall.py（不打真記憶服務，不通信真的 bin/recall）。
11-08 G10：每回合一次（按 session 計數，不看時間窗）；recall 各種結束碼各回對應字串。"""
import os, subprocess, sys, tempfile, types
os.environ.setdefault("MYTHOS_DIR", tempfile.mkdtemp())
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import __init__ as mt  # noqa: E402

FAIL = lambda m: sys.exit("FAIL: " + m)

calls = []
RC = lambda rc, out="備份每天 03:00 跑": types.SimpleNamespace(stdout=out, stderr="", returncode=rc)
delayed = []


def fake_run(cmd, **kw):
    calls.append(cmd)
    if delayed:
        mt.time.time = lambda: real_time() + 31  # 假時間：同一回合隔了 31 秒也不能再查
    return RC(0)


real_time = mt.time.time
mt.time.time = lambda: 1000.0
mt.subprocess.run = fake_run

# 1) 同 session 同回合：第二次擋（即使「隔了 31 秒」）
mt._on_pre_llm_call(session_id="s1")
assert mt.mythos_recall({"keywords": "備份"}, session_id="s1") == "備份每天 03:00 跑"
delayed.append(1)
r = mt.mythos_recall({"keywords": "備份 backup"}, session_id="s1")
assert len(calls) == 1 and r.startswith("這回合已查過一次"), (calls, r)

# 2) 新回合（pre_llm_call）後 1 秒可再查
mt.time.time = lambda: real_time() + 32
mt._on_pre_llm_call(session_id="s1")
mt.time.time = lambda: real_time() + 33
assert mt.mythos_recall({"keywords": "備份"}, session_id="s1") == "備份每天 03:00 跑" and len(calls) == 2, calls

# 3) 不同 session 互不影響
assert mt.mythos_recall({"keywords": "x"}, session_id="s2") == "備份每天 03:00 跑" and len(calls) == 3

# 4) handler 拿不到 session_id：讀 pre_tool_call 記的「目前 session」
mt._on_pre_tool_call(tool_name="mythos_recall", session_id="s3")
assert mt.mythos_recall({"keywords": "y"}) == "備份每天 03:00 跑" and len(calls) == 4
r = mt.mythos_recall({"keywords": "y"})  # s3 同回合第二次
assert len(calls) == 4 and r.startswith("這回合已查過一次"), r
mt._on_pre_tool_call(tool_name="mythos_dispatch", session_id="s4")  # 非 recall 工具不記
mt._on_pre_llm_call(session_id="s4")

# 5) 兩條路都沒有：放行一次並寫 log recall-no-session
logp = os.path.join(mt.STATE, "mythos-inbox.log")
if os.path.exists(logp):
    os.unlink(logp)
mt._recall_current = ""
assert mt.mythos_recall({"keywords": "z"}) == "備份每天 03:00 跑" and len(calls) == 5
assert "recall-no-session" in open(logp).read(), open(logp).read()

# 6) 計數字典有上限
for i in range(mt._RECALL_CAP + 50):
    mt._on_pre_llm_call(session_id=f"cap{i}")
assert len(mt._recall_used) <= mt._RECALL_CAP, len(mt._recall_used)

# 7) 結束碼：1／6／逾時／找不到執行檔／其他非零
mt._on_pre_llm_call(session_id="rc")


def once(kw):
    mt._on_pre_llm_call(session_id="rc")
    calls.clear()
    mt.time.time = real_time  # 假時間只用在第 1、2 案
    return mt.mythos_recall({"keywords": "q"}, session_id="rc")


def set_run(f):
    mt.subprocess.run = f


set_run(lambda cmd, **kw: RC(1, ""))
assert once({}) == "查不到相關紀錄。", once({})
set_run(lambda cmd, **kw: RC(6, ""))
assert once({}) == "記憶來源暫時不可用，要更確定再 mythos_dispatch。"
def timeout(cmd, **kw):
    raise subprocess.TimeoutExpired(cmd, 10)
set_run(timeout)
assert once({}) == "記憶查詢逾時，先說查不到，要更確定再 mythos_dispatch。"
def nofile(cmd, **kw):
    raise FileNotFoundError(2, "No such file or directory")
set_run(nofile)
assert once({}).startswith("查詢失敗："), once({})
set_run(lambda cmd, **kw: RC(3, ""))
assert once({}).startswith("查詢失敗（3）"), once({})
set_run(lambda cmd, **kw: RC(0, ""))
assert once({}) == "查不到相關紀錄。"

assert mt.mythos_recall({}) == "缺 keywords"
print("RECALL_TURN_OK")
