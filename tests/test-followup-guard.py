#!/usr/bin/env python3
"""11-09：追問剛轉過的結果時，pre_tool_call 擋 mythos_dispatch，強制 Router 直接白話答。
全在 mktemp 沙箱；不碰真 Genie／~/.hermes。
用法：python3 tests/test-followup-guard.py → 全過印 FOLLOWUP_GUARD_OK。"""
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN_DIR = os.path.join(ROOT, "profiles", "mythos", "plugins", "mythos-tools")
TMP = tempfile.mkdtemp(prefix="followup-guard.")
GENIE = os.path.join(TMP, "genie")
os.makedirs(os.path.join(GENIE, "router"))
os.makedirs(os.path.join(TMP, "mythos", "state"))
FAKE = os.path.join(GENIE, "router", "prefs.py")
with open(FAKE, "w") as f:
    f.write("import os\nprint('[genie prefs] fake')\n")

os.environ.update(MYTHOS_DIR=os.path.join(TMP, "mythos"), MYTHOS_GENIE_DIR=GENIE)
sys.path.insert(0, PLUGIN_DIR)
import __init__ as tools  # noqa: E402

HIST = [{"role": "user", "content": "[背景結果] 結論：測試補好了。"}, {"role": "assistant", "content": "測試補好了。"}]

# 追問 → pre_llm_call 注入提醒，且 session 被標記
got = tools._on_pre_llm_call(session_id="s1", user_message="那是什麼", conversation_history=HIST)
assert got and tools._EXPLAIN_HINT in got["context"], got
assert "s1" in tools._RESULT_ASK_SESSIONS
# pre_tool_call 擋 mythos_dispatch
blocked = tools._on_pre_tool_call(tool_name="mythos_dispatch", session_id="s1")
assert isinstance(blocked, dict) and blocked.get("action") == "block", blocked
assert "mythos_dispatch" in blocked.get("message", "")

# 非追問 → 不標記，不擋
got2 = tools._on_pre_llm_call(session_id="s2", user_message="幫我看備份有沒有跑", conversation_history=HIST)
assert not (got2 and tools._EXPLAIN_HINT in (got2.get("context") or ""))
assert "s2" not in tools._RESULT_ASK_SESSIONS
allowed = tools._on_pre_tool_call(tool_name="mythos_dispatch", session_id="s2")
assert allowed is None, allowed

# 其他工具不擋
assert tools._on_pre_tool_call(tool_name="mythos_recall", session_id="s1") is None

# 無 session_id 兜底：用全域旗標
tools._on_pre_llm_call(session_id="", user_message="目的是什麼", conversation_history=HIST)
assert tools._RESULT_ASK_CURRENT is True
blocked2 = tools._on_pre_tool_call(tool_name="mythos_dispatch")
assert isinstance(blocked2, dict) and blocked2.get("action") == "block", blocked2

# 新一輪非追問把旗標清掉
tools._on_pre_llm_call(session_id="", user_message="幫我看備份", conversation_history=HIST)
assert tools._RESULT_ASK_CURRENT is False
assert tools._on_pre_tool_call(tool_name="mythos_dispatch") is None

shutil.rmtree(TMP, True)
print("FOLLOWUP_GUARD_OK")