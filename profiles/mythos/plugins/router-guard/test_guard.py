#!/usr/bin/env python3
"""router-guard 自檢：python3 test_guard.py（純 python3、不打模型）。"""
import os
import sys
import tempfile

os.environ["MYTHOS_ROUTER_GUARD_LOG"] = os.path.join(tempfile.mkdtemp(), "guard.log")
# 假的難度判定與規劃人：goal 含 HARD 判 hard，其餘照內容印（不打模型）。
_fake = tempfile.mkdtemp()
os.makedirs(os.path.join(_fake, "bin"))
for _name, _body in (("triage", 'echo "$TRIAGE_CONFIG" >> "$(dirname "$0")/triage-config.seen"; cat "$1" >> "$(dirname "$0")/triage-goals.seen"; grep -q SLOW "$1" && sleep 2; grep -q HARD "$1" && echo hard || { grep -q BROKEN "$1" && exit 9; echo easy; }'),
                     ("bin/plan-hard", "echo plan")):
    with open(os.path.join(_fake, _name), "w") as _f:
        _f.write("#!/bin/sh\n" + _body + "\n")
    os.chmod(os.path.join(_fake, _name), 0o755)
os.environ.update(MYTHOS_HOME=_fake, MYTHOS_TRIAGE_BIN=os.path.join(_fake, "triage"),
                  MYTHOS_TIER_LOG=os.path.join(_fake, "tier.log"), MYTHOS_DISPATCH_LOG=os.path.join(_fake, "dispatch.log"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import __init__ as guard  # noqa: E402


def blocked(name):
    r = guard._on_pre_tool_call(tool_name=name, args={})
    return r is not None and r.get("action") == "block"


for n in ("terminal", "write_file", "mythos_dispatch", "mythos_full_text", "browser_navigate", "read_file", "web_search", "",
          "todo_list", "tool_search", "session_search"):
    assert blocked(n), f"應 block：{n!r}"
for n in ("delegate_task", "mythos_recall", "memory"):
    assert not blocked(n), f"應放行：{n!r}"
r = guard._on_pre_tool_call(tool_name="delegate_task", args={"tasks": [{"goal": "g"}]}, session_id="router-1")
assert r["action"] == "modify" and r["args"]["background"] is True, r
assert r["args"]["tasks"] == [{"goal": "g", "output_schema": guard.OUTPUT_SCHEMA}], r
r3 = guard._on_pre_tool_call(tool_name="delegate_task", args={"tasks": [{"goal": "a"}, {"goal": "b", "output_schema": {"type": "object"}}]})
assert r3["args"]["tasks"][0]["output_schema"] is guard.OUTPUT_SCHEMA and r3["args"]["tasks"][1]["output_schema"] == {"type": "object"}, r3
assert r["args"]["output_schema"] is guard.OUTPUT_SCHEMA, r
assert set(r["args"]["output_schema"]["required"]) == {"status", "evidence"}, r
assert r["args"]["output_schema"]["properties"]["status"]["enum"] == ["done", "needs_human", "failed"], r
mine = {"type": "object"}
r2 = guard._on_pre_tool_call(tool_name="delegate_task", args={"goal": "x", "output_schema": mine})
assert r2["action"] == "modify" and r2["args"]["background"] is True, r2
assert r2["args"]["output_schema"] is mine, r2
assert guard._on_pre_tool_call(tool_name="terminal", args={})["message"].startswith("Router 不動手")
assert open(guard.LOG).read().count("\tterminal\n") == 2
# 真正 register 的 lifecycle callback 必須記下 child id，空 id 不可放行。
class Context:
    def __init__(self):
        self.hooks = {}

    def register_hook(self, name, callback):
        self.hooks[name] = callback

    def register_command(self, name, handler, **_):
        self.commands = {**getattr(self, "commands", {}), name: handler}

    def inject_message(self, content, session_key=None):
        self.injected = getattr(self, "injected", []) + [(content, session_key)]
        return bool(session_key)


ctx = Context()
guard.register(ctx)
ctx.hooks["subagent_start"](child_session_id="child-1", parent_session_id="router-1")
for name in ("terminal", "read_file", "write_file", "mythos_dispatch"):
    assert ctx.hooks["pre_tool_call"](tool_name=name, session_id="child-1") is None
    assert ctx.hooks["pre_tool_call"](tool_name=name, session_id="router-1")["action"] == "block"
ctx.hooks["subagent_start"](child_session_id=None)
ctx.hooks["subagent_start"](child_session_id="")
assert blocked("terminal")
assert guard._on_pre_tool_call(tool_name="terminal", session_id="unknown")["action"] == "block"
# hard 子代理：跑過 plan-hard 才准動手；mid 以下、判定失敗的直接放行。
pre, start = ctx.hooks["pre_tool_call"], ctx.hooks["subagent_start"]
start(child_session_id="hard-1", child_goal="HARD 重構排程")
for name in ("terminal", "write_file", "read_file", "delegate_task"):
    r = pre(tool_name=name, args={"command": "ls"}, session_id="hard-1")
    assert r and r["action"] == "block" and "plan-hard" in r["message"], (name, r)
assert pre(tool_name="mythos_recall", session_id="hard-1") is None
assert pre(tool_name="terminal", args={"command": guard.PLAN_BIN + " '任務'"}, session_id="hard-1") is None
for name in ("terminal", "write_file"):
    assert pre(tool_name=name, args={"command": "ls"}, session_id="hard-1") is None, name
start(child_session_id="easy-1", child_goal="查天氣")
start(child_session_id="broken-1", child_goal="BROKEN")
for sid in ("easy-1", "broken-1"):
    assert pre(tool_name="terminal", args={"command": "ls"}, session_id=sid) is None, sid
tiers = {l.split("\t")[2]: l.split("\t")[1] for l in open(guard.TIER_LOG).read().splitlines()}
assert (tiers["hard-1"], tiers["easy-1"], tiers["broken-1"]) == ("hard", "easy", "mid"), tiers
os.chmod(guard.PLAN_BIN, 0o644)  # 沒有規劃人：hard 也不擋
start(child_session_id="hard-2", child_goal="HARD 沒規劃人")
assert pre(tool_name="terminal", args={"command": "ls"}, session_id="hard-2") is None
# 分級不占 Router：subagent_start 立刻返回（triage 慢 2 秒也一樣），子代理第一次動工具時才等結果。
import time  # noqa: E402
os.chmod(guard.PLAN_BIN, 0o755)
t0 = time.time()
start(child_session_id="slow-1", child_goal="SLOW HARD 大重構")
start(child_session_id="slow-2", child_goal="SLOW 查東西")
assert time.time() - t0 < 0.5, f"subagent_start 卡住 Router {time.time() - t0:.1f}s"
assert pre(tool_name="write_file", session_id="slow-1")["action"] == "block"
assert pre(tool_name="write_file", session_id="slow-2") is None
assert time.time() - t0 < 3.5, "兩個分級應平行跑"
# 派工帳：Router 的 delegate_task 耗時、子代理起訖；子代理結束後清掉狀態。
ctx.hooks["post_tool_call"](tool_name="delegate_task", duration_ms=42, session_id="router-1")
ctx.hooks["post_tool_call"](tool_name="terminal", duration_ms=9, session_id="slow-2")
ctx.hooks["subagent_stop"](child_session_id="slow-1", child_status="completed", duration_ms=1234)
assert pre(tool_name="write_file", session_id="slow-1")["message"].startswith("Router 不動手")
rows = [l.split("\t")[1:] for l in open(guard.DISPATCH_LOG).read().splitlines()]
assert ["dispatch", "router-1", "42"] in rows and ["stop", "slow-1", "completed", "1234"] in rows, rows
assert ["start", "slow-2"] in rows and not any(r[0] == "dispatch" and r[1] == "slow-2" for r in rows), rows
# 任務狀態：以 Router session 分帳，多件逐件列；做完的移到「剛做完」；子代理與沒任務的 session 不注入。
llm = ctx.hooks["pre_llm_call"]
assert llm(session_id="chat-A") is None and llm(session_id="") is None
start(child_session_id="t1", child_goal="查 A 頻道\n出片節奏", parent_session_id="chat-A")
start(child_session_id="t2", child_goal="跑 B 測試", parent_session_id="chat-A")
start(child_session_id="t3", child_goal="別的聊天室的事", parent_session_id="chat-B")
c = llm(session_id="chat-A")["context"]
assert "進行中 2 件" in c and "1. 查 A 頻道 出片節奏（已跑" in c and "2. 跑 B 測試" in c and "別的聊天室" not in c, c
assert llm(session_id="t1") is None, "子代理不注入"
ctx.hooks["subagent_stop"](child_session_id="t1", child_status="completed", duration_ms=5)
c = llm(session_id="chat-A")["context"]
assert "進行中 1 件" in c and "1. 跑 B 測試（已跑" in c and "剛做完" in c and "查 A 頻道 出片節奏（0 秒前，完成）" in c, c
ctx.hooks["subagent_stop"](child_session_id="t2", child_status="failed", duration_ms=5)
c = llm(session_id="chat-A")["context"]
assert "進行中 0 件（都做完了）" in c and "failed" in c and "不說「沒進展」" in c, c
assert "進行中 1 件" in llm(session_id="chat-B")["context"]
assert guard.task_status("chat-A", now=time.time() + guard.DONE_KEEP_S + 5) == "", "做完超過保留時間就不再提"
# Mythos 專用門檻有傳給分級器（只算最高一級）。
import json  # noqa: E402
seen = open(os.path.join(_fake, "triage-config.seen")).read().splitlines()
assert seen and all(json.loads(l) == {"hard_score_at": 2.5, "hard_needs_probability": 0.3} for l in seen), seen[:2]
# /hard：下一件派工不問分級器直接算 hard，只管一件；帶任務就送進對話；過期不算。
hard = ctx.commands["hard"]
assert "10 分鐘" in hard("")
start(child_session_id="forced-1", child_goal="FORCEDGOAL")
start(child_session_id="after-1", child_goal="AFTERGOAL")
assert pre(tool_name="write_file", session_id="forced-1")["action"] == "block"
assert pre(tool_name="write_file", session_id="after-1") is None, "/hard 只管下一件"
rows = [l.split("\t")[1:] for l in open(guard.TIER_LOG).read().splitlines()]
assert ["hard", "forced-1", "forced"] in rows and ["easy", "after-1"] in rows, rows[-3:]
goals = open(os.path.join(_fake, "triage-goals.seen")).read()
assert "AFTERGOAL" in goals and "FORCEDGOAL" not in goals, "/hard 那件不該叫分級器"
assert hard("重構排程", session_key="tg:1") == "收到，這件走 hard。" and ctx.injected == [("重構排程", "tg:1")]
assert "再發一次" in hard("重構排程", session_key="")
guard.FORCE_HARD_UNTIL = time.time() - 1
start(child_session_id="expired-1", child_goal="查天氣")
assert pre(tool_name="write_file", session_id="expired-1") is None, "/hard 過期不算"

# 靜默攔截：派工回合不准沉默、結果回合不准沉默、子代理與一般回覆不動。
llm, out = guard._on_pre_llm_call, guard._on_transform_llm_output
llm(session_id="loud-1", turn_id="t1", user_message="幫我查 M2 磁碟")
guard._on_post_tool_call(tool_name="delegate_task", session_id="loud-1")
assert out(response_text="[SILENT]", session_id="loud-1", turn_id="t1") == guard.DISPATCH_ACK
assert out(response_text="好，我看看", session_id="loud-1", turn_id="t1") is None, "有講話就不動"
llm(session_id="loud-1", turn_id="t2", user_message="哈囉")
assert out(response_text="[SILENT]", session_id="loud-1", turn_id="t2") is None, "沒派工的回合交給 Hermes 原本的處理"
done_msg = ("[ASYNC DELEGATION BATCH COMPLETE — deleg_x]\nheader\n\n"
            "--- ⚠ TASK 1/2: 查 nightnav 佇列  (status=completed, api_calls=40, TRUNCATED: hit max_iterations) ---\n"
            "[TRUNCATED — subagent hit its iteration cap]\n"
            '{"status": "done", "evidence": "佇列只有一支 sunset.sh"}\n\n'
            "--- ✓ TASK 2/2: 比對 plan  (status=completed, api_calls=5) ---\n"
            '```json\n{"status":"failed","evidence":"x","remaining":"缺 M2 權限"}\n```\n'
            "Full live transcript: /tmp/x.log\n")
llm(session_id="loud-1", turn_id="t3", user_message=done_msg)
r = out(response_text="[SILENT]", session_id="loud-1", turn_id="t3")
assert r and "查 nightnav 佇列" in r and "沒做完" in r and "sunset.sh" in r, r
assert "比對 plan" in r and "失敗" in r and "缺 M2 權限" in r, r
assert "deleg_" not in r and "status=" not in r, "不貼內部代號"
assert out(response_text="SILENT", session_id="loud-1", turn_id="t3"), "無括號標記也算沉默"
llm(session_id="child-loud", turn_id="c1", user_message=done_msg)
guard.CHILD_SESSIONS.add("child-loud")
assert out(response_text="[SILENT]", session_id="child-loud", turn_id="c1") is None, "子代理不動"
assert out(response_text="[SILENT]", session_id="loud-1", turn_id="stale") is None, "turn 對不上不動"
print("ROUTER_GUARD_OK")
