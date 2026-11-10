#!/usr/bin/env python3
"""path-guard 自檢：python3 -I test_guard.py（純 python3、不打模型、不刪任何東西）。"""
import importlib.util
import json
import os
import sys
import tempfile

_tmp = tempfile.mkdtemp()
os.environ["MYTHOS_PATH_GUARD_LOG"] = os.path.join(_tmp, "guard.log")
_here = os.path.dirname(os.path.abspath(__file__))


def load(conf):
    """用指定設定載入一份新的模組；conf=None 表示設定檔不存在。"""
    path = os.path.join(_tmp, f"conf-{id(conf)}.json")
    if conf is not None:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(conf, f)
    os.environ["MYTHOS_PATH_GUARD_CONF"] = path
    # -I 下 sys.path 不含 cwd，用 spec 載入 __init__.py
    spec = importlib.util.spec_from_file_location("path_guard", os.path.join(_here, "__init__.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


guard = load({
    "message": "受保護：{path}",
    "presets": [[".cache/demo-index", True], [".config/demo", True], ["notes-mirror", True],
                [".local/share/demo-proxy", True], ["dev/demo-app", True], [".android/avd/demo.avd", True],
                [".android/avd/demo.ini", False], ["Library/LaunchAgents/com.example.demo.plist", False]],
    "launchd": r"local\.demo-[\w.-]+|com\.example\.demo",
    "plist_glob": r"local\.demo-[^/\s'\"]+\.plist",
    "avd": "demo",
})
H = guard.HOME


def blocked(tool, **args):
    r = guard._on_pre_tool_call(tool_name=tool, args=args)
    return r is not None and r.get("action") == "block"


def ok(tool, **args):
    return not blocked(tool, **args)


# 必須擋
assert blocked("terminal", command="rm -rf ~/.cache/demo-index")
assert blocked("terminal", command=f"rm -rf {H}/.cache")
assert blocked("terminal", command='rm -rf "$HOME/.config"')
assert blocked("terminal", command="rm -rf ~/dev")
assert blocked("terminal", command="rm -rf ~/.android")
assert blocked("terminal", command="rm -rf ~/.local/share")
assert blocked("terminal", command="mv ~/notes-mirror /tmp/x")
assert blocked("execute_code", code=f"python3 -c \"import shutil;shutil.rmtree('{H}/dev/demo-app')\"")
assert blocked("execute_code", code="from pathlib import Path; Path('~/notes-mirror').unlink()")
assert blocked("terminal", command="launchctl bootout gui/501/local.demo-daily")
assert blocked("terminal", command=f"launchctl unload {H}/Library/LaunchAgents/com.example.demo.plist")
assert blocked("terminal", command="avdmanager delete avd -n demo")
assert blocked("terminal", command="find ~/.local/share/demo-proxy -name '*.log' -delete")
assert blocked("terminal", command="mo clean --dry-run")
assert blocked("terminal", command=f"echo x > {H}/.android/avd/demo.ini")
assert blocked("write_file", path="~/.config/demo/x.yml")
assert blocked("write_file", path=f"{H}/dev/demo-app/run.sh")
assert blocked("write_file", path=f"{H}/Library/LaunchAgents/local.demo-daily.plist")
assert blocked("patch", path="~/.cache/demo-index/x.sqlite")
# 必須放行
assert ok("terminal", command="ls ~/.cache/demo-index")
assert ok("terminal", command="rm -rf /tmp/foo")
assert ok("terminal", command="cat ~/dev/demo-app/run.sh")
assert ok("terminal", command="du -sh ~/.cache/demo-index")
assert ok("terminal", command=f"rsync -a /tmp/kb/ {H}/notes-mirror.bak/")
assert ok("write_file", path=f"{H}/dev/other/x.py")
assert ok("terminal", command=f"ls {H}/.cachex")
assert ok("read_file", path="~/.cache/demo-index/x.sqlite")
assert ok("terminal", command="launchctl bootout gui/501/local.other")
# 訊息與記帳
msg = guard._on_pre_tool_call(tool_name="terminal", args={"command": "rm -rf ~/.cache/demo-index"})["message"]
assert msg == f"受保護：{H}/.cache/demo-index"
assert "\tterminal\t" in open(guard.LOG).read()

# 沒設定檔：路徑都不擋，只擋清理工具；訊息用預設
bare = load(None)
assert bare._on_pre_tool_call(tool_name="terminal", args={"command": "rm -rf ~/.cache/demo-index"}) is None
assert bare._on_pre_tool_call(tool_name="write_file", args={"path": f"{H}/Library/LaunchAgents/local.demo-x.plist"}) is None
assert bare._on_pre_tool_call(tool_name="terminal", args={"command": "mo clean"})["message"].startswith("受保護路徑不可刪除")
print("PATH_GUARD_OK")
