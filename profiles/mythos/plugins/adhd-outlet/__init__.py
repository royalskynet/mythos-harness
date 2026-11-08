"""adhd-outlet — Router 的 Telegram 出口套 ADHD 格式（WO3b）。

舊 bash 出口在 bin/tg-send 裡截斷；切到 Hermes 後 Router 不經 tg-send，所以在 `transform_llm_output`
補一刀：回覆整段丟給 `bin/adhd-lint.mjs --truncate`（同一支 lint／截斷），回傳的跟原文不同＝被截斷，
原文先寫 state/tg-full/<epoch>.txt（給 mythos_full_text 取回），再回傳截斷版。

只在 platform=telegram（或 MYTHOS_ADHD_ALL=1）動；node 失敗／逾時／輸出空白回固定句（11-08 差距 #3：原本回 None＝原文照送）。
reasoning-only（content 空白、只有 reasoning、finish_reason=stop）由 post_api_request 記下企圖、這裡換成固定句（差距 #1）。
"""

from __future__ import annotations

import os
import re
import subprocess
import time
from collections import OrderedDict
from typing import Any, Optional

MYTHOS = os.environ.get("MYTHOS_DIR", os.path.expanduser("~/bots/mythos"))
FULL_DIR = os.path.join(MYTHOS, "state", "tg-full")
LOG = os.environ.get("MYTHOS_ADHD_LOG", os.path.join(MYTHOS, "state", "adhd-outlet.log"))
BIN = os.environ.get("MYTHOS_ADHD_BIN", "~/bots/mythos/bin/adhd-lint.mjs")
TIMEOUT = 5
RETRY_MSG = "剛剛那句我沒接好，你再說一次？"
# profile 的 state.db：由本檔位置（<profile>/plugins/<外掛>）往上推。不看 HERMES_HOME：多 profile 共用的 gateway 行程裡
# 它指向主機 profile（~/.hermes），讀到的是別人的庫（11-08 實測）。測試用 MYTHOS_STATE_DB 覆寫。
PROFILE_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STATE_DB = os.environ.get("MYTHOS_STATE_DB") or os.path.join(PROFILE_DIR, "state.db")
# ponytail: 每筆只留 (session_id, turn_id) → (content 有無、有無 tool_calls)，不存 reasoning 內文；
# 上限 200 筆，超出丟最舊（單一 gateway 行程、數秒內就會被 transform 讀走，200 筆遠夠）。
_ATTEMPTS: "OrderedDict[Any, tuple]" = OrderedDict()
ATTEMPT_MAX = 200


def _attempt_key(session_id: Any, turn_id: Any) -> Any:
    return (str(session_id or ""), str(turn_id or ""))


def _on_post_api_request(response: Any = None, session_id: str = "", turn_id: str = "", **_: Any) -> None:
    """每次模型嘗試後記下「這一輪最後一次」內容是否空白、有沒有 tool_calls。"""
    msg = (response.get("assistant_message") if isinstance(response, dict) else None) or {}
    if not isinstance(msg, dict):
        msg = {}
    content = msg.get("content")
    blank = content is None or (isinstance(content, str) and not content.strip())
    entries = msg.get("tool_calls") or []
    key = _attempt_key(session_id, turn_id)
    _ATTEMPTS[key] = (blank, len(entries) > 0)
    _ATTEMPTS.move_to_end(key)
    while len(_ATTEMPTS) > ATTEMPT_MAX:
        _ATTEMPTS.popitem(last=False)


def _log(msg: str) -> None:
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{int(time.time())}\t{msg}\n")
    except OSError:
        pass  # 記帳失敗不擋回覆


def _save_full(text: str) -> Optional[str]:
    try:
        os.makedirs(FULL_DIR, exist_ok=True)
        p = os.path.join(FULL_DIR, f"{time.time_ns()}.txt")
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
        return p
    except OSError as e:
        _log(f"write-full-failed\t{type(e).__name__}")
        return None


def _on_transform_llm_output(response_text: str = "", platform: str = "", session_id: str = "", turn_id: str = "", **_: Any) -> Optional[str]:
    # 11-08 差距 #1：這一輪最後一次嘗試 content 空白又沒 tool_calls＝模型只吐 reasoning，Hermes 會把 reasoning 當答案送出；換成固定句。
    # 查不到紀錄（別的外掛／舊版沒有 post_api_request）照舊流程。
    att = _ATTEMPTS.pop(_attempt_key(session_id, turn_id), None)
    if att == (True, False):
        _log(f"reasoning-only-blocked\t{platform!r}\t{session_id}\t{turn_id}")
        return RETRY_MSG
    text = str(response_text or "")
    # 11-08 診斷：TG 回覆從沒被改寫過，記下每次進來的 platform，確認 gateway 有沒有呼叫到這裡
    _log(f"enter\t{platform!r}\t{session_id}\t{len(text)}")
    if not text:
        return None
    if platform != "telegram" and os.environ.get("MYTHOS_ADHD_ALL") != "1":
        return None
    try:
        r = subprocess.run(
            ["node", BIN, "--truncate"],
            input=text, capture_output=True, text=True, timeout=TIMEOUT,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        _log(f"{type(e).__name__}\t{BIN}")
        return RETRY_MSG
    if r.returncode != 0:
        err = (r.stderr or "").strip()[:200]
        _log(f"exit-{r.returncode}\t{err}")
        return RETRY_MSG
    out = r.stdout
    if not out.strip():
        _log("lint-empty-output")
        return RETRY_MSG
    if out == text:
        return None
    _save_full(text)
    return out


def register(ctx) -> None:
    ctx.register_hook("post_api_request", _on_post_api_request)
    ctx.register_hook("transform_llm_output", _on_transform_llm_output)
