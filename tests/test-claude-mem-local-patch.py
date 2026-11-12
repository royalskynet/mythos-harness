#!/usr/bin/env python3
"""守 Mythos 依賴的 claude-mem 本機改動：python3 tests/test-claude-mem-local-patch.py

claude-mem 升版會蓋掉 ~/.hermes/plugins/claude-mem，重裝 gateway 會洗掉 plist 環境變數。
1. on_memory_write 第一句是 return（10-31 LGL：原生 memory 不複製進 claude-mem）
2. 每輪注入仍讀 CLAUDE_MEM_HERMES_TURN_LIMIT／TURN_MAX（11-07 本機 patch）
3. gateway plist 設 TURN_LIMIT=0（11-12：關每輪 prefetch）
4. TURN_LIMIT=0 真的停用 prefetch（11-12：_env_int 會把 0 當無效值，所以 TURN_NOTES_LIMIT 走 _env_nonneg_int）
5. 線上 profile 用 claude-mem provider、記憶上限 1200／300，plugins/claude-mem 連得到
ponytail: 沒有 ~/.hermes（CI）就 SKIP；只在本機跑時守得住。
"""
import ast
import importlib.util
import os
import plistlib
import sys

HOME = os.path.expanduser("~")
PLUGIN = os.environ.get("CM_PLUGIN", f"{HOME}/.hermes/plugins/claude-mem/__init__.py")
PLIST = os.environ.get("CM_PLIST", f"{HOME}/Library/LaunchAgents/ai.hermes.gateway-mythos.plist")
PROFILE = os.environ.get("CM_PROFILE", f"{HOME}/.hermes/profiles/mythos")
HERMES_AGENT = os.environ.get("CM_HERMES_AGENT", f"{HOME}/.hermes/hermes-agent")

if not os.path.exists(PLUGIN):
    print("SKIP 沒有 claude-mem Hermes plugin（CI）")
    sys.exit(0)

tree = ast.parse(open(PLUGIN, encoding="utf-8").read())
fn = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "on_memory_write")
assert isinstance(fn.body[0], ast.Return), "on_memory_write 不再先 return：原生 memory 會被複製進 claude-mem"

envs = {}
for n in tree.body:
    if not isinstance(n, ast.Assign) or not isinstance(n.value, ast.Call):
        continue
    if getattr(n.value.func, "id", "") in ("_env_int", "_env_nonneg_int"):
        envs[n.targets[0].id] = n.value.args[0].value
for var, name in (("TURN_NOTES_LIMIT", "CLAUDE_MEM_HERMES_TURN_LIMIT"), ("TURN_NOTES_MAX", "CLAUDE_MEM_HERMES_TURN_MAX")):
    assert envs.get(var) == name, f"{var} 不再讀 {name}：env 的壓低設定失效"

env = plistlib.load(open(PLIST, "rb")).get("EnvironmentVariables", {})
# 11-12：每輪 prefetch 會留在歷史裡逐回合重播（上游 #136229），線上要關；記憶只在 session 開始進 system prompt。
assert env.get("CLAUDE_MEM_HERMES_TURN_LIMIT") == "0", f"plist 沒把每輪 prefetch 關掉：CLAUDE_MEM_HERMES_TURN_LIMIT={env.get('CLAUDE_MEM_HERMES_TURN_LIMIT')!r}"

cfg = open(f"{PROFILE}/config.yaml", encoding="utf-8").read()
assert "\n  provider: claude-mem\n" in cfg, "線上 config 沒有 memory.provider: claude-mem"
assert "\n  memory_char_limit: 1200\n" in cfg, "線上 config 的 memory_char_limit 不是 1200"
assert "\n  user_char_limit: 300\n" in cfg, "線上 config 的 user_char_limit 不是 300"
assert os.path.exists(f"{PROFILE}/plugins/claude-mem/__init__.py"), "plugins/claude-mem 連結斷了"


def _load(limit_env):
    """Import the plugin with a given TURN_LIMIT, return (module, provider-with-stub)."""
    sys.path.insert(0, HERMES_AGENT)
    os.environ["CLAUDE_MEM_HERMES_TURN_LIMIT"] = limit_env
    spec = importlib.util.spec_from_file_location(
        "cm_probe", PLUGIN, submodule_search_locations=[os.path.dirname(PLUGIN)])
    mod = importlib.util.module_from_spec(spec)
    sys.modules["cm_probe"] = mod
    spec.loader.exec_module(mod)

    class Stub:
        def relevant_notes(self, cwd, query, limit=5):
            return "STUB-NOTE"

        def recent_context(self, cwd):
            return "STUB-CONTEXT"

    prov = mod.ClaudeMemMemoryProvider()
    prov.initialize("probe", cwd=PROFILE, agent_context="primary")
    prov._client = Stub()
    return mod, prov


try:
    mod, prov = _load("0")
    assert mod.TURN_NOTES_LIMIT == 0, f"TURN_LIMIT=0 被吃成 {mod.TURN_NOTES_LIMIT}（_env_int 會把 0 當無效值）"
    assert prov.prefetch("q") == "", "TURN_LIMIT=0 時 prefetch 仍回內容：每輪注入沒關掉"
    assert "STUB-CONTEXT" in (prov.system_prompt_block() or ""), "session block 被連帶關掉了"
    mod, prov = _load("5")
    assert prov.prefetch("q") == "STUB-NOTE", "TURN_LIMIT=5 時 prefetch 沒作用：探針失去鑑別力"
except ImportError as exc:  # no hermes-agent runtime (CI): fall back to source check
    src = open(PLUGIN, encoding="utf-8").read()
    assert "TURN_NOTES_LIMIT <= 0" in src, f"prefetch 沒有 TURN_LIMIT=0 早退（且 import 失敗：{exc}）"

print("CLAUDE_MEM_PATCH_OK")
