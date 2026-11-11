#!/usr/bin/env python3
"""守 Mythos 依賴的 claude-mem 本機改動：python3 tests/test-claude-mem-local-patch.py

claude-mem 升版會蓋掉 ~/.hermes/plugins/claude-mem，重裝 gateway 會洗掉 plist 環境變數。
1. on_memory_write 第一句是 return（10-31 LGL：原生 memory 不複製進 claude-mem）
2. 每輪注入仍讀 CLAUDE_MEM_HERMES_TURN_LIMIT／TURN_MAX（11-07 本機 patch）
3. gateway plist 不設 TURN_LIMIT／TURN_MAX（11-11：改用完整 claude-mem，每輪注入走外掛預設 5 筆／4000 字）
4. 線上 profile 用 claude-mem provider，plugins/claude-mem 連得到
ponytail: 沒有 ~/.hermes（CI）就 SKIP；只在本機跑時守得住。
"""
import ast
import os
import plistlib
import sys

HOME = os.path.expanduser("~")
PLUGIN = os.environ.get("CM_PLUGIN", f"{HOME}/.hermes/plugins/claude-mem/__init__.py")
PLIST = os.environ.get("CM_PLIST", f"{HOME}/Library/LaunchAgents/ai.hermes.gateway-mythos.plist")
PROFILE = os.environ.get("CM_PROFILE", f"{HOME}/.hermes/profiles/mythos")

if not os.path.exists(PLUGIN):
    print("SKIP 沒有 claude-mem Hermes plugin（CI）")
    sys.exit(0)

tree = ast.parse(open(PLUGIN, encoding="utf-8").read())
fn = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "on_memory_write")
assert isinstance(fn.body[0], ast.Return), "on_memory_write 不再先 return：原生 memory 會被複製進 claude-mem"

envs = {}
for n in tree.body:
    if isinstance(n, ast.Assign) and isinstance(n.value, ast.Call) and getattr(n.value.func, "id", "") == "_env_int":
        envs[n.targets[0].id] = n.value.args[0].value
for var, name in (("TURN_NOTES_LIMIT", "CLAUDE_MEM_HERMES_TURN_LIMIT"), ("TURN_NOTES_MAX", "CLAUDE_MEM_HERMES_TURN_MAX")):
    assert envs.get(var) == name, f"{var} 不再讀 {name}：plist 的壓低設定失效"

env = plistlib.load(open(PLIST, "rb")).get("EnvironmentVariables", {})
left = sorted(k for k in env if k.startswith("CLAUDE_MEM_HERMES_TURN_"))
assert not left, f"plist 還在壓低 claude-mem 每輪注入：{left}"

cfg = open(f"{PROFILE}/config.yaml", encoding="utf-8").read()
assert "\n  provider: claude-mem\n" in cfg, "線上 config 沒有 memory.provider: claude-mem"
assert os.path.exists(f"{PROFILE}/plugins/claude-mem/__init__.py"), "plugins/claude-mem 連結斷了"
print("CLAUDE_MEM_PATCH_OK")
