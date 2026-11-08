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
os.environ.update(MYTHOS_DIR=os.path.join(TMP, "mythos"), MYTHOS_GENIE_DIR=GENIE)
sys.path.insert(0, PLUGIN_DIR)
import __init__ as tools  # noqa: E402

got = tools._on_pre_llm_call(session_id="s1")
if got != {"context": "[genie prefs] fake genie-prefs.json"}:
    fail(f"應注入假 prefs 輸出，得到 {got!r}")

write_fake("import sys\nsys.exit(1)\n", 2)
got = tools._on_pre_llm_call(session_id="s1")
if got is not None:
    fail(f"prefs.py 失敗應不注入，得到 {got!r}")

shutil.rmtree(TMP, True)
print("GENIE_CONTEXT_OK")
