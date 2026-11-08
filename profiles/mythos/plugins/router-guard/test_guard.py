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


for n in ("terminal", "write_file", "delegate_task", "browser_navigate", "read_file", "web_search", "",
          "memory", "session_search", "todo_list", "tool_search"):
    assert blocked(n), f"應 block：{n!r}"
for n in ("mythos_dispatch", "mythos_full_text", "mythos_recall"):
    assert not blocked(n), f"應放行：{n!r}"
assert guard._on_pre_tool_call(tool_name="terminal", args={})["message"].startswith("Router 不做事")
assert open(guard.LOG).read().count("\tterminal\n") == 2
print("ROUTER_GUARD_OK")
