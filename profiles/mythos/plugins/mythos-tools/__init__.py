"""Mythos 唯讀記憶工具與 Genie context。派工使用 Hermes delegate_task。"""


from __future__ import annotations
import os
import re
import subprocess
import threading
import time
from collections import OrderedDict
from typing import Any, Dict, Optional


MYTHOS = os.environ.get("MYTHOS_DIR", os.path.expanduser("~/bots/mythos"))


STATE = os.path.join(MYTHOS, "state")


LOG = os.path.join(STATE, "router-dispatch.log")


def _logline(msg: str) -> None:
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(os.path.join(STATE, "mythos-inbox.log"), "a", encoding="utf-8") as f:
            f.write(f"{int(time.time())}\t{msg}\n")
    except OSError:
        pass


def _text(args: Dict[str, Any], key: str) -> str:
    return str(args.get(key) or "").strip()


def _log(epoch: int, thread: str, request: str, tool: str = "mythos_recall", mode: str = "", sid: str = "") -> None:
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{epoch}\t{thread}\t{tool}\t{request!r}\t{mode}\t{sid}\n")
    except OSError:
        pass  # 記帳失敗不擋派工


_RECALL_CAP = 200  # 只留最近 200 個 session 的計數


_recall_used: "OrderedDict[str, int]" = OrderedDict()  # session_id -> 本回合已查次數


_recall_lock = threading.Lock()


def _recall_count(sid: str) -> int:
    with _recall_lock:
        n = _recall_used.get(sid, 0)
        _recall_used[sid] = n + 1  # 更新順序＝最近使用，上限時丟最舊的
        _recall_used.move_to_end(sid)
        while len(_recall_used) > _RECALL_CAP:
            _recall_used.popitem(last=False)
        return n


def _genie_context() -> str:
    try:
        out = subprocess.run([os.environ.get("MYTHOS_GENIE_BIN") or os.path.join(MYTHOS, "bin", "genie-context")], capture_output=True,
                             text=True, timeout=8, stdin=subprocess.DEVNULL)
        return out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        return ""


_EXPLAIN_RE = re.compile(r"什麼|啥|目的|意思|聽不懂|看不懂|在說|解釋|說明")


_EXPLAIN_HINT = ("這句是在問你剛說過的話（剛轉過的［背景結果］或你上一句回覆），答案就在對話裡："
                 "直接用白話解釋你上一句說的那件事是什麼（它是什麼、為什麼做、對使用者有什麼影響），講到他懂為止。"
                 "不呼叫工具；不准回「還在跑／好了跟你說／我查一下」這類等待話術。")


_SHORT_EXPLAIN_RE = re.compile(r"^(這|那|它)*(是|指)?(什麼|啥|甚麼|哪個|何意|什麼意思)(意思)?(啊|呢|呀)?[？?。！!]*$")


def _msg_text(m: Any) -> str:
    c = m.get("content") if isinstance(m, dict) else None
    if isinstance(c, list):
        c = " ".join(p.get("text", "") for p in c if isinstance(p, dict) and isinstance(p.get("text"), str))
    return c if isinstance(c, str) else ""


_REQUEST_RE = re.compile(r"幫我|幫忙|幫|請你|查|找|修|跑|重跑|重啟|看一下|看看|處理|改|加|裝|派|試|部署|確認")


_FILLER_RE = re.compile(r"這個東西|這些|那些|這個|那個|一下|意思|為什麼|甚麼|什麼|說明|解釋|這|那|它|是|指|在|說|的|了|啥|呢|啊|呀|嗎|吧|[？?。！!，,、：:\s]")


def _is_new_request(msg: str) -> bool:
    """帶請求動作，且對象不是單指「這／那／它」（有新對象＝不是在問剛說過的話）。"""
    m = (msg or "").strip()
    if not _REQUEST_RE.search(m):
        return False
    # 拿掉請求動作、代名詞、問意思的字與語助詞後還剩內容＝有新對象（「幫我查資料庫為什麼掛了」剩「資料庫掛了」）；
    # 什麼都不剩＝在問剛說過的話（「幫我說明一下這個」）。
    # ponytail: 字表比對，不做斷詞；誤擋再出現就改成名詞實體抽取。
    rest = _REQUEST_RE.sub("", m)
    return bool(_FILLER_RE.sub("", rest))


def _asks_about_last_result(user_message: str, history: Any) -> bool:
    """問意思的短句，且近 8 則內有［背景結果］，或近 4 則內最後一則 assistant 回覆（在問 Router 自己剛說的話）。"""
    msg = (user_message or "").strip()
    if _is_new_request(msg):
        return False
    if len(msg) > 40 or not (_EXPLAIN_RE.search(msg) or _SHORT_EXPLAIN_RE.match(msg)):
        return False
    recent = [m for m in (history or []) if isinstance(m, dict) and _msg_text(m).strip()][-8:]
    for m in recent:
        if m.get("role") == "user" and _msg_text(m).lstrip().startswith("[背景結果]"):
            return True
    tail = recent[-4:]
    if any(m.get("role") == "user" and _msg_text(m).lstrip().startswith("[背景結果]") for m in tail):
        return True
    return any(m.get("role") == "assistant" for m in tail)


def _num(args: Dict[str, Any], key: str) -> Optional[int]:
    """非負整數參數：沒給＝None；給了不是整數＝-1（呼叫端報錯）。"""
    v = args.get(key)
    if v is None or str(v).strip() == "":
        return None
    v = str(v).strip()
    return int(v) if v.isdigit() else -1


def mythos_recall(args: Dict[str, Any], session_id: str = "", **_: Any) -> str:
    # P3：帶 id（thread／任務／訊息號；thread 也認 thread 欄）＝按 ID 查那件事，不查 keywords；帶 offset＝續讀全文。
    # 預算同一套：一回合一次，不分關鍵字或 ID 路。
    ident = _text(args, "id") or _text(args, "thread")
    keywords = _text(args, "keywords")
    rev, off = _num(args, "revision"), _num(args, "offset")
    if not keywords and not ident:
        return "缺 keywords"
    if rev == -1 or off == -1:
        return "revision／offset 要是非負整數"
    # 沒有 session_id：保守放行（不計數），記 log 供查
    if session_id and _recall_count(session_id) >= 1:
        return "這回合已查過一次，用剛剛的結果回答。"
    if not session_id:
        _logline("recall-no-session")
    _log(int(time.time()), ident or "recall", f"id:{ident}" if ident else keywords, "mythos_recall")
    if ident:
        cmd = [os.path.join(MYTHOS, "bin", "recall"), "--expand", ident, "--offset", str(off or 0)] if off is not None \
            else [os.path.join(MYTHOS, "bin", "recall"), "--id", ident]
        if rev is not None:
            cmd += ["--revision", str(rev)]
    else:
        cmd = [os.path.join(MYTHOS, "bin", "recall"), keywords]
    try:
        r = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE if ident else subprocess.DEVNULL, timeout=10, text=True,
                           env=dict(os.environ, MYTHOS_DIR=MYTHOS))
    except subprocess.TimeoutExpired:
        return "記憶查詢逾時，先說查不到，要更確定再 delegate_task。"
    except OSError as e:
        return f"查詢失敗：{e.strerror or type(e).__name__}"
    out = r.stdout.strip()
    if ident and r.returncode in (1, 2):
        return f"查不到或 ID 不合規（{r.returncode}）：{(r.stderr or '').strip()[:200]}"
    if r.returncode == 1:
        return "查不到相關紀錄。"
    if r.returncode == 6:
        return "記憶來源暫時不可用，要更確定再 delegate_task。"
    if r.returncode != 0:
        return f"查詢失敗（{r.returncode}）：{(r.stderr or out).strip()[:300]}"
    return out[:4000] if out else "查不到相關紀錄。"


_RECALL_SCHEMA = {
    "name": "mythos_recall",
    "description": "查以前的事（做過的事、定過的決定、偏好；本機唯讀，最多 10 秒）。一回合最多呼叫一次，拿到文字後自己用口語回答。",
    "parameters": {
        "type": "object",
        "properties": {
            "keywords": {"type": "string", "description": "兩三個關鍵字，中文沒中就換英文（沒有 id 時用）"},
            "id": {"type": "string", "description": "Telegram 訊息號或舊紀錄代號"},
            "revision": {"type": "integer", "description": "同一 thread 的第幾版（1 起算，預設最新）"},
            "offset": {"type": "integer", "description": "續讀全文的字元位置（取自上次 continuation.offset）"},
        },
    },
}


def _env_dirs() -> None:
    global MYTHOS, STATE, LOG
    MYTHOS = os.environ.get("MYTHOS_DIR") or os.path.expanduser("~/bots/mythos")
    STATE = os.path.join(MYTHOS, "state")
    LOG = os.path.join(STATE, "router-dispatch.log")


def _on_pre_llm_call(session_id: str = "", user_message: str = "", conversation_history: Any = None, **_: Any) -> Optional[Dict[str, str]]:
    _env_dirs()
    if session_id:
        with _recall_lock:
            _recall_used.pop(session_id, None)
    parts = [_genie_context()]
    if _asks_about_last_result(user_message, conversation_history):
        parts.append(_EXPLAIN_HINT)
    context = "\n\n".join(p for p in parts if p)
    return {"context": context} if context else None


def register(ctx) -> None:
    ctx.register_tool(name="mythos_recall", toolset="mythos", schema=_RECALL_SCHEMA,
                      handler=mythos_recall, emoji="🧠")
    ctx.register_hook("pre_llm_call", _on_pre_llm_call)
