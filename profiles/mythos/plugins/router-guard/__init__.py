"""router-guard — Router 只聊天與派工，子代理才動手。"""

from __future__ import annotations

import os
import time
from typing import Any, Dict, Optional

LOG = os.environ.get("MYTHOS_ROUTER_GUARD_LOG", os.path.expanduser("~/bots/mythos/state/router-guard.log"))
MESSAGE = "Router 不動手：改呼叫 delegate_task"

OUTPUT_SCHEMA = {
    "type": "object",
    "properties": {
        "status": {"type": "string", "enum": ["done", "needs_human", "failed"]},
        "evidence": {"type": "string"},
        "artifacts": {"type": "array", "items": {"type": "string"}},
        "question": {"type": "string"},
        "remaining": {"type": "string"},
    },
    "required": ["status", "evidence"],
}

# Hermes tools/delegate_tool.py:368-373 → hermes_cli/lifecycle.py:25-37
# → plugins.invoke_hook；ctx.register_hook 可收到 child_session_id。
ALLOWED = frozenset({"delegate_task", "mythos_recall", "memory", "session_search"})
CHILD_SESSIONS: set[str] = set()


def _on_subagent_start(child_session_id: str = "", **_: Any) -> None:
    if child_session_id:
        CHILD_SESSIONS.add(child_session_id)


def check(tool_name: str) -> bool:
    return tool_name in ALLOWED


def _on_pre_tool_call(tool_name: str = "", args: Optional[Dict[str, Any]] = None, session_id: str = "", **_: Any) -> Optional[dict]:
    if session_id in CHILD_SESSIONS:  # 子代理放行
        return None
    if tool_name == "delegate_task":  # 預設同步會卡住 Router 回合；強制背景（tools/delegate_tool.py:596）
        new_args = {**(args or {}), "background": True}
        if "output_schema" not in new_args:
            new_args["output_schema"] = OUTPUT_SCHEMA
        if isinstance(new_args.get("tasks"), list):  # 多 task 時框架不套頂層 schema（delegate_tool_tasks.py:114-117）
            new_args["tasks"] = [{**t, "output_schema": t.get("output_schema", new_args["output_schema"])}
                                 if isinstance(t, dict) else t for t in new_args["tasks"]]
        return {"action": "modify", "args": new_args}
    if check(tool_name):
        return None
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{int(time.time())}\t{tool_name}\n")
    except OSError:
        pass  # 記帳失敗也要擋
    return {"action": "block", "message": MESSAGE}


def register(ctx) -> None:
    ctx.register_hook("subagent_start", _on_subagent_start)
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
