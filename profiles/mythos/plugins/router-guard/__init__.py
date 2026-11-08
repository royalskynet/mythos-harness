"""router-guard — Router 不做事：工具層白名單。

flash 會違反只寫在 prompt 的規則，所以限制做在 `pre_tool_call`：只放行派工、查記憶與 Hermes
內建的記憶讀寫；其他（terminal、檔案、web、delegate_task、browser…）一律 block，
把「改呼叫 mythos_dispatch」當工具結果回給模型，它下一步自己重派。每次擋下行為記一行 log。
"""

from __future__ import annotations

import os
import time
from typing import Any, Dict, Optional

LOG = os.environ.get("MYTHOS_ROUTER_GUARD_LOG", os.path.expanduser("~/bots/mythos/state/router-guard.log"))
MESSAGE = "Router 不做事：改呼叫 mythos_dispatch(request=使用者原話)"

# 來源：~/.hermes/hermes-agent/tools/ 裡的工具名。
#   memory_tool.py:306  "name": "memory"          （記憶讀寫）
#   session_search_tool.py:652  "name": "session_search"（查過去對話，唯讀）
#   todo_tool.py:325  name="todo_list"            （Agent 自己的待辦，不碰機器）
# send_message_tool.py:756 有 "name": "send_message"，但同檔開頭註解明寫「intentionally NOT
# registered as an agent-callable model tool」，叫它也送不出去，不放。
# 11-08 使用者定：Router 只准聊天＋派工。mythos_full_text 只把已寫好的回覆全文轉送，不做事。
# 第一道防線是 config.yaml 的 platform_toolsets（只給 mythos toolset、no_mcp）：MCP 工具不經 pre_tool_call，擋不到。
# 11-08b：記憶互通屬聊天，mythos_recall（單次唯讀、10s 上限、30s 內只准一次）放行。
ALLOWED = frozenset({"mythos_dispatch", "mythos_full_text", "mythos_recall"})


def check(tool_name: str) -> bool:
    return tool_name in ALLOWED


def _on_pre_tool_call(tool_name: str = "", args: Optional[Dict[str, Any]] = None, **_: Any) -> Optional[dict]:
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
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
