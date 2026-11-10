"""誤操作防線：字串比對擋常見刪除／搬移／截斷，不是安全邊界。受保護清單在 profile 根目錄 path-guard.json（本機，不進 repo）"""

from __future__ import annotations

import json
import os
import re
import time
from typing import Any, Dict, Optional

HOME = os.path.expanduser("~")
LOG = os.environ.get("MYTHOS_PATH_GUARD_LOG", os.path.expanduser("~/bots/mythos/state/path-guard.log"))
# profiles/<name>/plugins/path-guard/__init__.py → profiles/<name>/path-guard.json；格式見 path-guard.example.json
CONF = os.environ.get("MYTHOS_PATH_GUARD_CONF",
                      os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "path-guard.json"))


def _load(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}  # 沒設定＝只擋清理工具，不擋路徑


_C = _load(CONF)
MESSAGE = _C.get("message", "受保護路徑不可刪除、搬移或覆寫：{path}。確實要動請回報使用者。")
# (相對 HOME 的路徑, 是否連子路徑一起保護)
PRESETS = [(p, bool(s)) for p, s in _C.get("presets", [])]
PATHS = [os.path.join(HOME, p) for p, _ in PRESETS]
# 父目錄被整個刪也算命中（rm -rf ~/.cache …）：每個受保護路徑往上到 HOME 的每一層
PARENTS = {os.path.join(HOME, *p.split("/")[:i]) for p, _ in PRESETS for i in range(p.count("/") + 1)}
LAUNCHD = _C.get("launchd")  # launchctl bootout/unload 要擋的 label（regex）
PLIST_GLOB = re.compile(re.escape(HOME) + r"/Library/LaunchAgents/" + _C["plist_glob"]) if _C.get("plist_glob") else None
AVD = _C.get("avd")  # avdmanager delete 要擋的 AVD 名稱（regex）

# 破壞動詞（regex）。前後有界，避免誤中 cat/du 之類的子字串。
DESTRUCTIVE = "|".join([
    r"rm\b", r"rmdir\b", r"\bmv\b", r"\btrash\b", r"\bunlink\b",
    r"shutil\.rmtree", r"os\.remove", r"os\.unlink", r"\.unlink\(", r"\.rmdir\(",
    r"-delete\b", r"\bmo\s+clean", r"\bmole\s+clean",
    r"launchctl\s+(bootout|unload)", r"avdmanager\s+delete",
    r">\s*(?=[^\s>&])",  # 截斷覆寫
])
DESTRUCTIVE_RE = re.compile(DESTRUCTIVE)


def _norm(s: str) -> str:
    return s.replace("${HOME}", HOME).replace("$HOME", HOME).replace("~", HOME)


def _hits_text(text: str) -> Optional[str]:
    t = _norm(text)
    if not DESTRUCTIVE_RE.search(t):
        return None
    for path in PATHS:
        if re.search(re.escape(path) + r"(?![\w.-])", t):
            return path
    if LAUNCHD and re.search(r"launchctl\s+(bootout|unload)\b", t):
        m = re.search(LAUNCHD, t)
        if m:
            return f"launchd：{m.group(0)}"
    if AVD and re.search(r"avdmanager\s+delete\b", t):
        m = re.search(rf"\b(?:{AVD})\b", t)
        if m:
            return f"{HOME}/.android/avd/{m.group(0)}.avd"
    if re.search(r"(?m)^\s*(?:\S*/)?(?:mo|mole)\s+clean\b", t):  # 清理工具會掃 ~/.cache 等處
        return HOME + "/.cache（mo/mole clean）"
    for parent in PARENTS:
        # 父目錄後面只能接引號/空白/結尾/斜線以外的「非子路徑」字元，避免 ~/foo 被視為 ~ 命中
        if re.search(re.escape(parent) + r"(?![\w.-/])", t):
            return parent
    m = PLIST_GLOB.search(t) if PLIST_GLOB else None
    return m.group(0) if m else None


def _hits_path(path: str) -> Optional[str]:
    if not isinstance(path, str) or not path:
        return None
    p = _norm(path).rstrip("/") or "/"
    for full, subtree in zip(PATHS, (s for _, s in PRESETS)):
        if p == full or (subtree and p.startswith(full + "/")):
            return full
    m = PLIST_GLOB.match(p) if PLIST_GLOB else None
    return m.group(0) if m else None


def check(tool_name: str, args: Optional[Dict[str, Any]]) -> Optional[str]:
    """回傳命中的受保護路徑，或 None。"""
    args = args or {}
    if tool_name in ("terminal", "execute_code"):
        for key in ("command", "code"):
            hit = _hits_text(str(args.get(key) or ""))
            if hit:
                return hit
        return None
    if tool_name in ("write_file", "patch"):
        hit = _hits_path(str(args.get("path") or ""))
        if hit:
            return hit
        return _hits_text(str(args.get("patch") or "")) if tool_name == "patch" else None
    return None


def _on_pre_tool_call(tool_name: str = "", args: Optional[Dict[str, Any]] = None, **_: Any) -> Optional[dict]:
    hit = check(tool_name, args)
    if not hit:
        return None
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{int(time.time())}\t{tool_name}\t{hit}\n")
    except OSError:
        pass  # 記帳失敗也要擋
    return {"action": "block", "message": MESSAGE.format(path=hit)}


def register(ctx) -> None:
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
