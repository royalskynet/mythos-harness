#!/usr/bin/env python3
"""11-08：Router 每回合套 Genie 說話規則（直接跑 Genie 本體的 prefs.py，不複製）。
- 找得到 prefs.py → pre_llm_call 回 {"context": 它印的內容}，且帶 GENIE_PREFS=state/genie-prefs.json。
- prefs.py 失敗 → 不注入（回 None），不擋對話。
全在 mktemp 沙箱，用假 prefs.py；不碰真 Genie 與 ~/.hermes。
用法：python3 tests/test-genie-context.py → 全過印 GENIE_CONTEXT_OK。"""
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN_DIR = os.path.join(ROOT, "profiles", "mythos", "plugins", "mythos-tools")
TMP = tempfile.mkdtemp(prefix="genie-ctx.")
GENIE = os.path.join(TMP, "genie")
os.makedirs(os.path.join(GENIE, "router"))
os.makedirs(os.path.join(TMP, "mythos", "state"))
FAKE = os.path.join(GENIE, "router", "prefs.py")


def write_fake(body, bump):
    with open(FAKE, "w") as f:
        f.write(body)
    os.utime(FAKE, (1700000000 + bump,) * 2)  # 換 mtime，快取才會重讀


def fail(msg):
    shutil.rmtree(TMP, True)
    sys.exit("FAIL: " + msg)


write_fake("import os,sys\nassert sys.argv[1]=='context'\n"
           "print('[genie prefs] fake', os.path.basename(os.environ['GENIE_PREFS']))\n", 1)
os.environ.update(MYTHOS_DIR=os.path.join(TMP, "mythos"), MYTHOS_GENIE_DIR=GENIE,
                  MYTHOS_GENIE_BIN=os.path.join(ROOT, "bin", "genie-context"))
sys.path.insert(0, PLUGIN_DIR)
import __init__ as tools  # noqa: E402

got = tools._on_pre_llm_call(session_id="s1")
if got != {"context": "[genie prefs] fake genie-prefs.json"}:
    fail(f"應注入假 prefs 輸出，得到 {got!r}")

HIST = [{"role": "user", "content": "[背景結果] 結論：測試補好了。"}, {"role": "assistant", "content": "測試補好了。"}]
got = tools._on_pre_llm_call(session_id="s1", user_message="這些都是什麼專案什麼功能目的", conversation_history=HIST)
if not got or tools._EXPLAIN_HINT not in got["context"] or "fake" not in got["context"]:
    fail(f"追問剛轉過的結果應加白話提醒＋Genie，得到 {got!r}")
for msg, hist in (("幫我看備份有沒有跑", HIST), ("那是什麼", [{"role": "user", "content": "哈囉"}])):
    got = tools._on_pre_llm_call(session_id="s1", user_message=msg, conversation_history=hist)
    if got and tools._EXPLAIN_HINT in got["context"]:
        fail(f"{msg!r} 不該加白話提醒")

write_fake("import sys\nsys.exit(1)\n", 2)
got = tools._on_pre_llm_call(session_id="s1")
if got is not None:
    fail(f"prefs.py 失敗應不注入，得到 {got!r}")

# 找 Genie：沒設 MYTHOS_GENIE_DIR 時跟著 Claude Code 裝的版本（installed_plugins.json 的 user scope installPath）
import json  # noqa: E402
import subprocess  # noqa: E402
INST = os.path.join(TMP, "installed_plugins.json")
with open(INST, "w") as f:
    json.dump({"plugins": {"genie-harness@genie-harness": [
        {"scope": "project", "installPath": "/nonexistent"}, {"scope": "user", "installPath": GENIE}]}}, f)
env = {k: v for k, v in os.environ.items() if k != "MYTHOS_GENIE_DIR"}
env.update(HOME=TMP, CLAUDE_INSTALLED_PLUGINS=INST)
d = subprocess.run([os.path.join(ROOT, "bin", "genie-context"), "--dir"], capture_output=True, text=True, env=env).stdout.strip()
if d != GENIE:
    fail(f"應找到 installed_plugins.json 的 user installPath，得到 {d!r}")

shutil.rmtree(TMP, True)
print("GENIE_CONTEXT_OK")
