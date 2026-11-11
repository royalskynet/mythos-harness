"""router-guard — Router 只聊天與派工，子代理才動手；hard 任務的子代理先拿規劃人的計畫才准動手。"""

from __future__ import annotations

import os
import subprocess
import tempfile
import time
from concurrent.futures import Future, ThreadPoolExecutor
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
# session_search 查的是 state.db（7 天就清），不當記憶用；記憶走 memory 與 mythos_recall（claude-mem）。
ALLOWED = frozenset({"delegate_task", "mythos_recall", "memory"})
CHILD_SESSIONS: set[str] = set()

# hard 任務：子代理先跑 bin/plan-hard（強模型唯讀規劃）才放行其他工具；mid 以下自己規劃自己做。
MYTHOS = os.environ.get("MYTHOS_HOME", os.path.expanduser("~/bots/mythos"))
PLAN_BIN = os.path.join(MYTHOS, "bin", "plan-hard")
TRIAGE = os.environ.get("MYTHOS_TRIAGE_BIN", os.path.expanduser("~/dev/dispatch-router/bin/triage"))
TIER_LOG = os.environ.get("MYTHOS_TIER_LOG", os.path.join(MYTHOS, "state", "router-tier.log"))
PLAN_MESSAGE = (f"這是 hard 任務：先用 terminal 跑 `{PLAN_BIN} '<任務原話＋需要的前文>'`（timeout 給 200 秒）拿計畫，"
                "照計畫做。規劃人失敗就照實回報 failed，不自己編計畫。")
PLAN_PENDING: set[str] = set()
# 分級在背景執行緒跑：subagent_start 是在 Router 的回合裡呼叫的，不能讓它等 triage；子代理第一次動工具時才取結果。
TIERS: Dict[str, Future] = {}
_POOL = ThreadPoolExecutor(max_workers=4, thread_name_prefix="router-guard-tier")
# 派工帳：dispatch＝Router 那次 delegate_task 花的毫秒（應是幾十毫秒，上千就是被卡住）；start／stop＝子代理起訖。
DISPATCH_LOG = os.environ.get("MYTHOS_DISPATCH_LOG", os.path.join(MYTHOS, "state", "dispatch.log"))

# 任務狀態：Router 只看得到對話文字，不知道哪幾件還在跑、哪幾件剛做完；每回合把實際狀態塞給它。
# 以 Router 的 session 分帳（多個聊天室各看各的），同時多件逐件列。行程重啟就清空（子代理也跟著沒了）。
TASKS: Dict[str, Dict[str, Any]] = {}
DONE_KEEP_S = 1800  # 做完的留 30 分鐘
DONE_SHOW = 5


def _ago(sec: float) -> str:
    sec = int(max(sec, 0))
    return f"{sec} 秒" if sec < 60 else f"{sec // 60} 分 {sec % 60:02d} 秒"


def task_status(parent_session_id: str, now: Optional[float] = None) -> str:
    now = time.time() if now is None else now
    for sid in [k for k, t in TASKS.items() if t.get("end") and now - t["end"] > DONE_KEEP_S]:
        TASKS.pop(sid, None)
    mine = [t for t in list(TASKS.values()) if t["parent"] == parent_session_id]
    running = sorted((t for t in mine if not t.get("end")), key=lambda t: t["start"])
    done = sorted((t for t in mine if t.get("end")), key=lambda t: t["end"], reverse=True)[:DONE_SHOW]
    if not running and not done:
        return ""
    lines = [f"[任務狀態] 進行中 {len(running)} 件" + ("：" if running else "（都做完了）。")]
    lines += [f"{i}. {t['goal']}（已跑 {_ago(now - t['start'])}）" for i, t in enumerate(running, 1)]
    if done:
        lines.append("剛做完（結果已在這段對話裡，或下一則就到）：")
        lines += [f"{i}. {t['goal']}（{_ago(now - t['end'])}前，{t['status']}）" for i, t in enumerate(done, 1)]
    lines.append("被問進度就照這份答、逐件講；不在「進行中」的就是做完了，指向已回報的結果，不說「沒進展」。")
    return "\n".join(lines)


def _on_pre_llm_call(session_id: str = "", **_: Any) -> Optional[Dict[str, str]]:
    if not session_id or session_id in CHILD_SESSIONS:
        return None
    text = task_status(session_id)
    return {"context": text} if text else None


def _log(path: str, *cols: Any) -> None:
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as f:
            f.write("\t".join(str(c) for c in (int(time.time()), *cols)) + "\n")
    except OSError:
        pass


def tier_of(goal: str) -> str:
    """easy／mid／hard；判定工具不在、失敗、逾時一律 mid（不擋派工）。"""
    if not goal or not os.access(TRIAGE, os.X_OK):
        return "mid"
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".md", encoding="utf-8") as f:
            f.write(goal)
            f.flush()
            out = subprocess.run([TRIAGE, f.name], capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "mid"
    return out if out in ("easy", "mid", "hard") else "mid"


def _classify(child_session_id: str, goal: str) -> str:
    tier = tier_of(goal)
    _log(TIER_LOG, tier, child_session_id)
    return tier


def _on_subagent_start(child_session_id: str = "", child_goal: str = "", parent_session_id: Any = "", **_: Any) -> None:
    if not child_session_id:
        return
    CHILD_SESSIONS.add(child_session_id)
    TIERS[child_session_id] = _POOL.submit(_classify, child_session_id, child_goal)
    TASKS[child_session_id] = {"parent": parent_session_id or "", "start": time.time(),
                               "goal": " ".join(str(child_goal or "").split())[:80]}
    _log(DISPATCH_LOG, "start", child_session_id)


def _on_subagent_stop(child_session_id: str = "", child_status: Any = "", duration_ms: int = 0, **_: Any) -> None:
    if not child_session_id:
        return
    for bag in (CHILD_SESSIONS, PLAN_PENDING):
        bag.discard(child_session_id)
    TIERS.pop(child_session_id, None)
    if child_session_id in TASKS:
        TASKS[child_session_id].update(end=time.time(), status={"completed": "完成"}.get(str(child_status), str(child_status) or "結束"))
    _log(DISPATCH_LOG, "stop", child_session_id, child_status, duration_ms)


def _on_post_tool_call(tool_name: str = "", duration_ms: int = 0, session_id: Any = "", **_: Any) -> None:
    if tool_name == "delegate_task" and session_id not in CHILD_SESSIONS:
        _log(DISPATCH_LOG, "dispatch", session_id or "", duration_ms)


def check(tool_name: str) -> bool:
    return tool_name in ALLOWED


def _on_pre_tool_call(tool_name: str = "", args: Optional[Dict[str, Any]] = None, session_id: str = "", **_: Any) -> Optional[dict]:
    pending = TIERS.pop(session_id, None)
    if pending is not None:  # 子代理第一次動工具：取分級結果（在子代理自己的執行緒等，不占 Router）
        try:
            tier = pending.result(timeout=15)
        except Exception:
            tier = "mid"
        if tier == "hard" and os.access(PLAN_BIN, os.X_OK):  # 沒有規劃人就不擋，照 mid 走
            PLAN_PENDING.add(session_id)
    if session_id in PLAN_PENDING:  # hard 子代理：跑過 plan-hard 才放行其他工具
        if tool_name == "terminal" and "plan-hard" in str((args or {}).get("command", "")):
            PLAN_PENDING.discard(session_id)
            return None
        if tool_name != "mythos_recall":
            return {"action": "block", "message": PLAN_MESSAGE}
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
    _log(LOG, tool_name)  # 記帳失敗也要擋
    return {"action": "block", "message": MESSAGE}


def register(ctx) -> None:
    ctx.register_hook("subagent_start", _on_subagent_start)
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
    ctx.register_hook("subagent_stop", _on_subagent_stop)
    ctx.register_hook("post_tool_call", _on_post_tool_call)
    ctx.register_hook("pre_llm_call", _on_pre_llm_call)
