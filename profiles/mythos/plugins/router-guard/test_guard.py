#!/usr/bin/env python3
"""router-guard 自檢：python3 test_guard.py（純 python3、不打模型）。"""
import os
import sys
import tempfile

os.environ["MYTHOS_ROUTER_GUARD_LOG"] = os.path.join(tempfile.mkdtemp(), "guard.log")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import __init__ as guard  # noqa: E402


def blocked(name):
    r = guard._on_pre_tool_call(tool_name=name, args={})
    return r is not None and r.get("action") == "block"


for n in ("terminal", "write_file", "mythos_dispatch", "mythos_full_text", "browser_navigate", "read_file", "web_search", "",
          "todo_list", "tool_search"):
    assert blocked(n), f"應 block：{n!r}"
for n in ("delegate_task", "mythos_recall", "memory", "session_search"):
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
print("ROUTER_GUARD_OK")
