"""mythos-tools — Router 的手：派工、查記憶、取回被截斷的全文。

Router（flash）不自己做事：要做事＝mythos_dispatch（原話寫成 prompt 檔，交 bin/dispatch-bg，
難度由它裡面的 triage 判、記帳、起 worker）；問過去＝mythos_recall（bin/recall，不帶 --ask，
讀完由 Router 自己答）。回使用者「詳細」＝mythos_full_text（取 adhd-outlet 存的全文，交 bin/tg-send #full）。
每次呼叫都記一行 state/router-dispatch.log（epoch\tthread\t工具名\t原話）。
"""

from __future__ import annotations

import asyncio
import errno
import fcntl
import json
import os
import random
import re
import signal
import string
import subprocess
import threading
import time
from collections import OrderedDict
from typing import Any, Dict, Optional

try:  # profile config 是 YAML；Hermes 一定有 PyYAML，離線自檢沒有時就只認環境變數
    import yaml
except Exception:  # pragma: no cover
    yaml = None

# 11-08 差距 #6：thread 會被拼進 state/bg/<thread>-<epoch>.md 與 bin/dispatch-bg 的 argv，先驗再寫檔。
# 比 dispatch-bg 的 `*[!A-Za-z0-9-]*` 更嚴（只收 t- 小寫代號）；gate 產生的 t-abc123 都合規。
# 允許連字號：ledger 既有 t-backlog-daily、t-all-status 這類 thread 要能取消（11-08 收件時放寬）。
THREAD_RE = re.compile(r"t-[a-z0-9][a-z0-9-]{3,30}")

MYTHOS = os.environ.get("MYTHOS_DIR", os.path.expanduser("~/bots/mythos"))
STATE = os.path.join(MYTHOS, "state")
LOG = os.path.join(STATE, "router-dispatch.log")
INBOX = os.path.join(STATE, "inbox")
SESSION_KEY_FILE = os.path.join(STATE, "hermes-session-key")
WARN_TSV = os.path.join(os.path.expanduser("~/.cache/brief-lines"), "mythos-inbox.tsv")
FALLBACK_AFTER = 60  # 秒：注入沒成功／注入後 state.db 查不到落地就等這麼久再退回直送
SENT = os.path.join(INBOX, "sent")
# profile 的 state.db：由本檔位置（<profile>/plugins/<外掛>）往上推。不看 HERMES_HOME：多 profile 共用的 gateway 行程裡
# 它指向主機 profile（~/.hermes），讀到的是別人的庫（11-08 實測）。測試用 MYTHOS_STATE_DB 覆寫。
PROFILE_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STATE_DB = os.environ.get("MYTHOS_STATE_DB") or os.path.join(PROFILE_DIR, "state.db")
_inbox_lock_fd = None


def _logline(msg: str) -> None:
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(os.path.join(STATE, "mythos-inbox.log"), "a", encoding="utf-8") as f:
            f.write(f"{int(time.time())}\t{msg}\n")
    except OSError:
        pass


def _remember_session_key() -> None:
    """記下目前這輪對話的 session key，供背景執行緒注入 Router 原對話用。"""
    try:
        from tools.approval_context import get_current_session_key
        key = get_current_session_key("") or ""
    except Exception:
        return
    if not key:
        return
    try:
        os.makedirs(STATE, exist_ok=True)
        tmp = SESSION_KEY_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(key)
        os.replace(tmp, SESSION_KEY_FILE)
    except OSError as e:
        _logline(f"session key 寫入失敗 {e}")


_HOOK_TIMEOUT = 2.0  # 秒：pre_gateway_dispatch 子行程上限（hook 在入站路徑上，不能拖住訊息）
_MYTHOS_ENV = ""


def _env_dirs() -> None:
    """餘下的位置：MYTHOS 照模組常數（import 時讀 MYTHOS_DIR），只有同一個行程切了 MYTHOS_DIR 才重讀目錄。"""
    global MYTHOS, STATE, LOG, INBOX, SESSION_KEY_FILE, WARN_TSV, _MYTHOS_ENV
    cur = os.environ.get("MYTHOS_DIR") or os.path.expanduser("~/bots/mythos")
    if cur == _MYTHOS_ENV:
        return
    _MYTHOS_ENV = MYTHOS = cur
    STATE = os.path.join(MYTHOS, "state")
    LOG = os.path.join(STATE, "router-dispatch.log")
    INBOX = os.path.join(STATE, "inbox")
    SESSION_KEY_FILE = os.path.join(STATE, "hermes-session-key")
    WARN_TSV = os.path.join(os.path.expanduser("~/.cache/brief-lines"), "mythos-inbox.tsv")




# ---- P6c：入站歸屬（pre_gateway_dispatch）----
# 這個 hook 在 auth 之前跑：只認 allowlist 內的 Telegram chat（profile config 的
# gateway.platforms.telegram.extra.allow_from，'${MYTHOS_TG_CHAT_ID}' 先展開；再併環境變數 MYTHOS_TG_CHAT_ID），
# 不在名單一律回 None 且不記錄。判定交子行程 bin/followup-direct（同一份規則）；原文不進 observation、不入 argv。
def _profile_allow() -> list:
    """Mythos profile 的 config.yaml：telegram extra 的 allow_from／group_allow_from（${VAR} 寫法原樣回傳，
    由 _allowed_chats 展開）。放生的環境沒設變數時＝名單空＝不記錄，比放寬安全。"""
    prof = os.environ.get("HERMES_PROFILE") or "mythos"
    try:
        with open(os.path.join(os.path.dirname(PROFILE_DIR), prof, "config.yaml"), encoding="utf-8") as f:
            c = yaml.safe_load(f) or {}
        entry = c.get("gateway", {}).get("platforms", {}).get("telegram", {}).get("extra", {}) or {}
        return [entry.get("allow_from"), entry.get("group_allow_from")]
    except Exception:
        return []


def _allowed_chats(gateway: Any) -> set:
    """allowlist：環境變數 MYTHOS_TG_CHAT_ID（逗號分隔）＋ profile config 的 allow_from／group_allow_from。"""
    vals = list(_profile_allow()) + [os.environ.get("MYTHOS_TG_CHAT_ID", "")]
    out = set()
    for v in vals:
        for x in ([v] if isinstance(v, str) else (v or [])):
            x = str(x).strip().strip("'\"")
            m = re.fullmatch(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", x)
            if m:
                x = os.environ.get(m.group(1)) or ""
            if re.fullmatch(r"-?[0-9]+", x):  # 只收數字 chat id（群組是負數）；'*'、暱稱一律不放行
                out.add(x)
    return out


_inflight: list = []


def _followup_mode() -> str:
    m = os.environ.get("MYTHOS_FOLLOWUP_DIRECT", "")
    return m if m in ("observe", "auto", "1") else ""


def _run_observer(cmd: list, text: str, mythos: str) -> None:
    try:
        subprocess.run(cmd, input=text, text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=_HOOK_TIMEOUT, env=dict(os.environ, MYTHOS_DIR=mythos, MYTHOS_FOLLOWUP_DIRECT="observe"))
    except Exception:
        pass  # 逾時／找不到腳本／任何錯：吞掉


async def _followup_exec(cmd: list, text: str, timeout: float) -> tuple:
    """await 子行程；逾時、取消或例外都收掉整個子行程群組並 wait，避免孤兒。"""
    proc = await asyncio.create_subprocess_exec(
        *cmd, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL, start_new_session=True,
        env=dict(os.environ, MYTHOS_DIR=MYTHOS))
    completed = False
    try:
        out, _ = await asyncio.wait_for(proc.communicate(text.encode()), timeout)
        completed = True
        return proc.returncode, out.decode(errors="replace").strip()
    finally:
        if not completed:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            await proc.wait()


async def _on_pre_gateway_dispatch(event: Any = None, gateway: Any = None, **_: Any) -> Optional[dict]:
    """入站即定擁有者：worker 入列成功就 skip；其餘以持鎖收據交回 Router。
    Hermes ainvoke_hook await 此 callback；pre_gateway_dispatch 不套 callback timeout。
    我們自己限制入列 2 秒、claim 1 秒；observe 維持背景影子觀察，預設 off。
    """
    mode = _followup_mode()
    if not mode:
        return None
    try:
        src = getattr(event, "source", None)
        plat = getattr(src, "platform", None)
        if str(getattr(plat, "value", plat) or "") != "telegram":
            return None
        chat = str(getattr(src, "chat_id", "") or "")
        mid = str(getattr(event, "message_id", "") or "")
        rmid = str(getattr(event, "reply_to_message_id", "") or "")
        if chat not in _allowed_chats(gateway) or not mid.isdigit() or not rmid.isdigit():
            return None
        cmd = [os.path.join(MYTHOS, "bin", "followup-direct"), chat, mid, rmid]
        text = str(getattr(event, "text", "") or "") + "\n"
        if mode == "observe":
            t = threading.Thread(target=_run_observer, name="mythos-observe", daemon=True,
                                 args=(cmd, text, MYTHOS))
            _inflight[:] = [x for x in _inflight if x.is_alive()][-31:] + [t]
            t.start()
            return None
        try:
            rc, out = await _followup_exec(cmd, text, _HOOK_TIMEOUT)
            if rc == 0 and re.fullmatch(r"(?:queued|dup) t-[a-z0-9][a-z0-9-]{3,30}", out):
                _logline("pre_gateway_dispatch: worker " + out)
                return {"action": "skip"}
        except Exception:
            pass
        try:
            rc, out = await _followup_exec([cmd[0], "--claim-router", chat, mid], "", 1.0)
            if rc == 0 and re.fullmatch(r"seen t-[a-z0-9][a-z0-9-]{3,30}", out):
                _logline("pre_gateway_dispatch: worker " + out)
                return {"action": "skip"}
        except Exception:
            pass  # claim 失敗：安全側交 Router，最多重複，不漏訊息
    except Exception:
        pass
    return None


def _text(args: Dict[str, Any], key: str) -> str:
    return str(args.get(key) or "").strip()


def _log(epoch: int, thread: str, request: str, tool: str = "mythos_dispatch") -> None:
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{epoch}\t{thread}\t{tool}\t{request!r}\n")
    except OSError:
        pass  # 記帳失敗不擋派工


def _cancel(thread: str) -> str:
    """mode=cancel：bin/dispatch-bg --cancel <thread>（停整個行程樹、ledger 記 cancelled，結果不再送回）。"""
    epoch = int(time.time())
    _log(epoch, thread, "(cancel)")
    if os.environ.get("MYTHOS_DISPATCH_DRYRUN") == "1":
        return f"已停 {thread}"
    cmd = [os.path.join(MYTHOS, "bin", "dispatch-bg"), "--cancel", thread]
    env = dict(os.environ, DISPATCH_BG_WORKER=os.environ.get("MYTHOS_BG_WORKER") or "hermes")
    try:
        r = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, env=env,
                           stderr=subprocess.PIPE, timeout=30, text=True)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"停止失敗：{type(e).__name__}"
    if r.returncode != 0:
        return f"停止失敗（{r.returncode}）：{(r.stderr or r.stdout).strip()[:300]}"
    if "沒有進行中" in (r.stdout or ""):
        return f"{thread} 沒有進行中的事，不用停"
    return f"已停 {thread}"


def mythos_dispatch(args: Dict[str, Any], **_: Any) -> str:
    _env_dirs()
    request = _text(args, "request")
    _remember_session_key()
    mode = _text(args, "mode") or "queue"
    if mode not in ("queue", "cancel", "interrupt"):
        return f"mode 只認 queue／cancel／interrupt：{mode}"
    th = _text(args, "thread")
    # 先驗再動：不合規的 thread 一個字都不寫（記帳、prompt 檔、dispatch-bg）
    if th and not THREAD_RE.fullmatch(th):
        return f"thread 格式不對（只收 t- 加小寫英數與連字號，4～31 字）：{th[:40]}"
    if mode in ("cancel", "interrupt") and not th:
        return f"{mode} 必帶 thread：用要{'停' if mode == 'cancel' else '改'}的那件事的代號"
    if mode == "cancel":
        return _cancel(th)
    if not request:
        return "缺 request：把使用者原話放進來"
    # P4 N03：宣告目標 repo（絕對路徑）；唯讀另標 readonly。先驗再動，不合規一個字都不寫。
    repo = _text(args, "repo")
    if repo and (not os.path.isabs(repo) or "\n" in repo or "\r" in repo):
        return f"repo 要絕對路徑、單行：{repo[:80]}"
    readonly = args.get("readonly") in (True, "true", "1", 1)
    thread = th or "t-" + "".join(random.choices(string.ascii_lowercase + string.digits, k=6))
    epoch = int(time.time())
    if os.environ.get("MYTHOS_DISPATCH_DRYRUN") == "1":
        _log(epoch, thread, request)
        return f"已派 {thread}"
    os.makedirs(os.path.join(STATE, "bg"), exist_ok=True)
    prompt = os.path.join(STATE, "bg", f"{thread}-{epoch}.md")
    with open(prompt, "w", encoding="utf-8") as f:
        f.write(request + "\n")
    # P6：repo／readonly 不進正文，寫進與 prompt 同名的 <prompt>.meta.json（bin/lib-ledger.sh 排程只讀這份）
    meta = {"v": 1, "repo": repo or "", "readonly": bool(repo and readonly)}
    with open(prompt + ".meta.json.tmp", "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False)
    os.replace(prompt + ".meta.json.tmp", prompt + ".meta.json")
    _log(epoch, thread, request)
    cmd = [os.path.join(MYTHOS, "bin", "dispatch-bg")]
    if mode == "interrupt":
        cmd += ["--interrupt", thread, prompt]  # 停舊 worker，以「原需求＋這段新指示」重派同 thread
    elif th:
        cmd += ["--thread", thread, thread, prompt]  # 續派：--thread 與位置參數兩個代號都要給且一致
    else:
        cmd += [thread, prompt]
    # ponytail: 30s 上限——dispatch-bg 偶爾同步等 triage（~3s）與 claude 起頭；再久就當失敗回報。
    # WO3-v3：worker 後端開關透傳（MYTHOS_BG_WORKER，預設 hermes）；DRYRUN 已在上面回掉，這裡不呼叫。
    env = dict(os.environ, DISPATCH_BG_WORKER=os.environ.get("MYTHOS_BG_WORKER") or "hermes")
    try:
        r = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, env=env,
                           stderr=subprocess.PIPE, timeout=30, text=True)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"派工失敗：{type(e).__name__}"
    if r.returncode != 0:
        return f"派工失敗（{r.returncode}）：{(r.stderr or r.stdout).strip()[:300]}"
    return f"已派 {thread}"


def _full_for_thread(thread: str) -> Optional[str]:
    """該 thread 最新一份全文的路徑。對照 bin/tg-send 記的 state/tg-msg-thread.tsv（chat\\tmid\\tthread\\tjob\\tepoch），
    全文檔名是 state/tg-full/<mid>.txt：取該 thread 最後一筆、且檔案還在的。對不到回 None，不退回全域最新。"""
    try:
        with open(os.path.join(STATE, "tg-msg-thread.tsv"), encoding="utf-8") as f:
            rows = [l.rstrip("\n").split("\t") for l in f if l.strip()]
    except OSError:
        return None
    for r in reversed(rows):  # 檔案是 append，倒著找就是最新
        if len(r) >= 3 and r[2] == thread:
            p = os.path.join(STATE, "tg-full", f"{r[1]}.txt")
            if os.path.isfile(p):
                return p
    return None


def _full_newest() -> Optional[str]:
    full = os.path.join(STATE, "tg-full")
    try:
        names = [n for n in os.listdir(full) if n.endswith(".txt")]
    except OSError:
        return None
    if not names:
        return None
    return os.path.join(full, max(names, key=lambda n: os.stat(os.path.join(full, n)).st_mtime_ns))


def mythos_full_text(args: Dict[str, Any], **_: Any) -> str:
    # ponytail: Router 呼叫不帶 thread、adhd-outlet 的 <epoch>.txt 也不在 tg-msg-thread.tsv，
    # 對不到就退回全域最新（舊行為），否則線上「詳細」全壞。要精準對到被回覆的那則，留給 P3 讓 outlet 記 mid 對照。
    thread = _text(args, "thread")
    path = _full_for_thread(thread) if thread else None
    if path is None:
        path = _full_newest()
    if path is None:
        return "沒有可取的全文"
    thread = thread or "t-full"
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return "讀不到全文"
    _log(int(time.time()), thread, os.path.basename(path), "mythos_full_text")
    env = dict(os.environ, MYTHOS_DIR=MYTHOS)
    try:
        r = subprocess.run([os.path.join(MYTHOS, "bin", "tg-send"), "--thread", thread, "--job", "bg-full"],
                           input="#full\n" + text, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=20, text=True, env=env)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"送全文失敗：{type(e).__name__}"
    if r.returncode != 0:
        return f"送全文失敗（{r.returncode}）：{(r.stderr or r.stdout).strip()[:300]}"
    return "已送全文"


# 11-08 G10：一回合只准查一次（Router 曾連打 50 次記憶查詢佔住對話）。按 session 計數：
# pre_llm_call（每使用者回合開始一次）把該 session 歸零；拿不到 session_id 時用 pre_tool_call 記「目前 session」。
_RECALL_CAP = 200  # 只留最近 200 個 session 的計數
_recall_used: "OrderedDict[str, int]" = OrderedDict()  # session_id -> 本回合已查次數
_recall_current = ""  # pre_tool_call 看到 mythos_recall 時的 session_id；handler 優先讀 kwargs 的
_recall_lock = threading.Lock()


def _recall_count(sid: str) -> int:
    with _recall_lock:
        n = _recall_used.get(sid, 0)
        _recall_used[sid] = n + 1  # 更新順序＝最近使用，上限時丟最舊的
        _recall_used.move_to_end(sid)
        while len(_recall_used) > _RECALL_CAP:
            _recall_used.popitem(last=False)
        return n


# 11-08：Router 說話規則直接套 Genie 本體（不複製）：每回合注入 bin/genie-context 的輸出（跟著 Claude Code
# 裝的版本走，找法見該檔）。偏好檔 state/genie-prefs.json。找不到 Genie 或跑失敗就不注入。
# ponytail: 每回合跑一次約 0.2 秒，不快取；回合變多或嫌慢再按 installed_plugins.json／偏好檔 mtime 快取。


def _genie_context() -> str:
    try:
        out = subprocess.run([os.environ.get("MYTHOS_GENIE_BIN") or os.path.join(MYTHOS, "bin", "genie-context")], capture_output=True,
                             text=True, timeout=8, stdin=subprocess.DEVNULL)
        return out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        return ""


# 11-08：Ether 追問剛轉過的結果「那是什麼／目的／聽不懂」，免費模型照「系統問題一律派工」回「我查一下」。
# 近幾則有［背景結果］且這句是在問意思，就加一行提醒：答案在對話裡，直接白話答。
_EXPLAIN_RE = re.compile(r"什麼|啥|目的|意思|聽不懂|看不懂|在說|解釋|說明")
_EXPLAIN_HINT = ("這句是在問上面剛轉過的［背景結果］，答案就在對話裡：直接用白話答兩三句"
                 "（它是什麼、為什麼做、對 Ether 有什麼影響），不呼叫工具、不說「我查一下」。")


def _asks_about_last_result(user_message: str, history: Any) -> bool:
    if not _EXPLAIN_RE.search(user_message or "") or len(user_message) > 40:
        return False
    for m in (history or [])[-8:]:
        c = m.get("content") if isinstance(m, dict) else None
        if isinstance(c, list):
            c = " ".join(p.get("text", "") for p in c if isinstance(p, dict))
        if isinstance(c, str) and m.get("role") == "user" and c.lstrip().startswith("[背景結果]"):
            return True
    return False


def _on_pre_llm_call(session_id: str = "", user_message: str = "", conversation_history: Any = None,
                     **_: Any) -> Optional[Dict[str, str]]:
    global _recall_current
    if session_id:
        with _recall_lock:
            _recall_used.pop(session_id, None)
            _recall_current = session_id
    parts = [_genie_context()]
    if _asks_about_last_result(user_message, conversation_history):
        parts.append(_EXPLAIN_HINT)
    ctx = "\n\n".join(p for p in parts if p)
    return {"context": ctx} if ctx else None


def _on_pre_tool_call(tool_name: str = "", session_id: str = "", **_: Any) -> None:
    global _recall_current
    if tool_name == "mythos_recall" and session_id:
        _recall_current = session_id


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
    sid = session_id or _recall_current
    # 兩條路都拿不到 session：保守放行（不計數），記 log 供查
    if sid and _recall_count(sid) >= 1:
        return "這回合已查過一次，用剛剛的結果回答。"
    if not sid:
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
        return "記憶查詢逾時，先說查不到，要更確定再 mythos_dispatch。"
    except OSError as e:
        return f"查詢失敗：{e.strerror or type(e).__name__}"
    out = r.stdout.strip()
    if ident and r.returncode in (1, 2):
        return f"查不到或 ID 不合規（{r.returncode}）：{(r.stderr or '').strip()[:200]}"
    if r.returncode == 1:
        return "查不到相關紀錄。"
    if r.returncode == 6:
        return "記憶來源暫時不可用，要更確定再 mythos_dispatch。"
    if r.returncode != 0:
        return f"查詢失敗（{r.returncode}）：{(r.stderr or out).strip()[:300]}"
    return out[:4000] if out else "查不到相關紀錄。"


_DISPATCH_SCHEMA = {
    "name": "mythos_dispatch",
    "description": "把使用者原話派給背景工作者（難度自動判，結果直接送給使用者）。要做事就呼叫這支，"
                   "呼叫後只回「收到」。同一件事的追問帶同一個 thread。",
    "parameters": {
        "type": "object",
        "properties": {
            "request": {"type": "string", "description": "使用者原話，可附一兩句必要脈絡"},
            "thread": {"type": "string", "description": "同一件事續派用的代號；新題目留空"},
            "repo": {"type": "string", "description": "這件事要寫入的 repo 絕對路徑（同一 repo 的寫入一次只跑一件）；不改檔就留空"},
            "readonly": {"type": "boolean", "description": "true＝只讀 repo、不寫（唯讀不排隊）；預設 false"},
            "mode": {"type": "string", "enum": ["queue", "cancel", "interrupt"],
                     "description": "queue（預設）＝照舊；cancel＝Ether 說算了／不用了／停，停掉還在跑的事（必帶 thread）；"
                                    "interrupt＝Ether 改方向（改成…／不對，要…），停掉舊的、帶原需求加新指示重做（必帶 thread，request 放新指示）"},
        },
        # 不列 required：cancel 不需要 request；queue／interrupt 缺 request 由 handler 回錯誤
    },
}

_FULL_SCHEMA = {
    "name": "mythos_full_text",
    "description": "使用者回「詳細」時呼叫：把上一則被截斷的回覆全文直接送到 Telegram。呼叫後只回「已送全文」。",
    "parameters": {"type": "object", "properties": {}},
}

_RECALL_SCHEMA = {
    "name": "mythos_recall",
    "description": "查以前的事（做過的事、定過的決定、偏好；本機唯讀，約 5 秒）。一回合最多呼叫一次，拿到文字後自己用口語回答。"
                   "知道那件事的代號（thread 的 t-…、任務 bg-…）就帶 id：回需求、驗收、最新結果；要看被截斷的全文，"
                   "用同一 id 加 offset（取自上次 continuation.offset）續讀。",
    "parameters": {
        "type": "object",
        "properties": {
            "keywords": {"type": "string", "description": "兩三個關鍵字，中文沒中就換英文（沒有 id 時用）"},
            "id": {"type": "string", "description": "thread 代號 t-…、任務代號 bg-…、或 Telegram 訊息號；有它就不查 keywords"},
            "revision": {"type": "integer", "description": "同一 thread 的第幾版（1 起算，預設最新）"},
            "offset": {"type": "integer", "description": "續讀全文的字元位置（取自上次 continuation.offset）"},
        },
    },
}


def _unique(dst_dir: str, name: str) -> str:
    """搬檔目的地撞名時加時間戳，不蓋掉別人的檔（inbox 檔名是 epoch-pid，但 pid 會重複用）。"""
    dst = os.path.join(dst_dir, name)
    if os.path.exists(dst):
        dst = os.path.join(dst_dir, f"{int(time.time() * 1000)}-{name}")
    return dst


def _session_key() -> str:
    try:
        with open(SESSION_KEY_FILE, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def _fallback_tg(item: Dict[str, Any], text: str) -> bool:
    env = dict(os.environ, MYTHOS_DIR=MYTHOS, MYTHOS_DELIVER="tg")
    try:
        r = subprocess.run(
            [os.path.join(MYTHOS, "bin", "tg-send"), "--thread", str(item.get("thread") or ""),
             "--job", str(item.get("job") or "")],
            input=text + "\n", stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, text=True, env=env)
        ok = r.returncode == 0
        if not ok:
            err = (r.stderr or r.stdout).strip()[:300]
    except (OSError, subprocess.TimeoutExpired) as e:
        ok, err = False, f"{type(e).__name__}: {e}"
    if not ok:
        try:
            os.makedirs(os.path.dirname(WARN_TSV), exist_ok=True)
            with open(WARN_TSV, "a", encoding="utf-8") as f:
                f.write(f"{int(time.time())}\t⚠ 背景結果直送也失敗 {item.get('job')}: {err}\n")
        except OSError:
            pass
        _logline(f"直送失敗 {item.get('job')} {err}")
    return ok


def _landed(text: str, since: float) -> bool:
    """state.db 裡有沒有 telegram session 的 user 訊息含完整 text、時間 ≥ since（唯讀連線）。
    11-08 G05：只比前 40 字會把別 session／共同前綴誤判成已落地。查不到庫／查詢失敗＝當作未落地。"""
    if not text or not os.path.exists(STATE_DB):
        return False
    try:
        import sqlite3
        con = sqlite3.connect(f"file:{STATE_DB}?mode=ro", uri=True, timeout=2)
        try:
            row = con.execute(
                "SELECT 1 FROM messages m JOIN sessions s ON s.id = m.session_id"
                " WHERE m.role='user' AND s.source='telegram' AND m.timestamp >= ? AND instr(m.content, ?) > 0"
                " LIMIT 1", (since, text)).fetchone()
        finally:
            con.close()
        return row is not None
    except Exception as e:
        _logline(f"state.db 查詢失敗 {e}")
        return False


def _move(src: str, sub: str, name: str) -> None:
    os.makedirs(os.path.join(INBOX, sub), exist_ok=True)
    os.rename(src, _unique(os.path.join(INBOX, sub), name))


def _drain_sent(now: float) -> None:
    """inject True 只代表「已排程」：Hermes 排程後查無 session 只寫 warning、結果就丟了（11-08 審查 #3）。
    Hermes 沒有回執 API，改查 state.db 有沒有落地：有→done；逾 FALLBACK_AFTER 秒沒有→退回直送。"""
    try:
        names = sorted(n for n in os.listdir(SENT) if n.endswith(".json"))
    except OSError:
        return
    for name in names:
        src = os.path.join(SENT, name)
        try:
            with open(src, encoding="utf-8") as f:
                item = json.load(f)
            text = str(item.get("text") or "")
            sent_ts = float(item.get("sent_ts") or 0)
            if _landed(text, sent_ts):
                _move(src, "done", name)
                continue
            if now - sent_ts < FALLBACK_AFTER:
                continue
            _logline(f"注入後未落地，退回直送 {item.get('job')}")
            _move(src, "done" if _fallback_tg(item, text) else "failed", name)
        except Exception as e:
            _logline(f"sent 處理失敗 {name}: {e}")


def drain_inbox(ctx, now: float) -> None:
    """掃一次收件匣：注入 Router→sent/（等落地確認）；沒 key／注入失敗且滿 60 秒 → 退回直送。例外全吞，只記 log。"""
    _drain_sent(now)
    try:
        names = sorted(n for n in os.listdir(INBOX) if n.endswith(".json"))
    except OSError:
        return
    if not names:
        return
    key = _session_key()
    for name in names:
        src = os.path.join(INBOX, name)
        try:
            with open(src, encoding="utf-8") as f:
                item = json.load(f)
            text = str(item.get("text") or "")
            if not text:
                raise ValueError("缺 text")
            if key:
                try:
                    ok = ctx.inject_message("[背景結果]\n" + text, session_key=key) is True
                except Exception as e:
                    _logline(f"注入例外 {name}: {e}")
                    ok = False
                if ok:
                    item["sent_ts"] = now
                    tmp = src + ".tmp"
                    with open(tmp, "w", encoding="utf-8") as f:
                        json.dump(item, f, ensure_ascii=False)
                    os.replace(tmp, src)
                    _move(src, "sent", name)
                    continue
            age = now - float(item.get("ts") or 0) / 1000.0
            if age < FALLBACK_AFTER:
                continue
            ok = _fallback_tg(item, text)
            _move(src, "done" if ok else "failed", name)
        except Exception as e:  # 壞檔／rename 失敗：記 log，別讓整條執行緒死掉
            _logline(f"收件匣處理失敗 {name}: {e}")


def _acquire_single_instance() -> bool:
    global _inbox_lock_fd
    try:
        os.makedirs(INBOX, exist_ok=True)
        fd = os.open(os.path.join(INBOX, ".lock"), os.O_CREAT | os.O_RDWR, 0o644)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        os.close(fd)
        if e.errno in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK):
            return False  # 另一個 gateway 行程已經在掃
        raise
    _inbox_lock_fd = fd  # 綁到模組層，fd 不能被 GC 關掉（關掉＝鎖沒了）
    return True


def _gateway_ready(ctx) -> bool:
    """只在 gateway 行程掃：CLI（hermes -z 冒煙等）的 inject_message 會進 CLI 佇列回 True，訊息被吞（11-07 審查）。"""
    m = getattr(ctx, "_manager", None)
    return (m is not None and getattr(m, "_cli_ref", None) is None
            and bool(getattr(m, "has_gateway_message_injector", False)))


def _inbox_loop(ctx) -> None:
    # 鎖延到 gateway 就緒才搶、每輪重試：CLI 不搶鎖，gateway 重啟後也接得回來
    while True:
        try:
            if _inbox_lock_fd is not None or (_gateway_ready(ctx) and _acquire_single_instance()):
                drain_inbox(ctx, time.time())
        except Exception as e:
            _logline(f"輪詢例外 {e}")
        time.sleep(1)  # 11-08b：5→1 秒，結果進對話少等幾秒


def register(ctx) -> None:
    ctx.register_tool(name="mythos_dispatch", toolset="mythos", schema=_DISPATCH_SCHEMA,
                      handler=mythos_dispatch, emoji="📮")
    # 11-08b：記憶互通屬聊天（使用者定）。recall＝單次唯讀 HTTP 查 claude-mem 服務、10s 上限，不是 MCP 迴圈
    ctx.register_tool(name="mythos_recall", toolset="mythos", schema=_RECALL_SCHEMA,
                      handler=mythos_recall, emoji="🧠")
    ctx.register_hook("pre_llm_call", _on_pre_llm_call)
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
    ctx.register_hook("pre_gateway_dispatch", _on_pre_gateway_dispatch)
    ctx.register_tool(name="mythos_full_text", toolset="mythos", schema=_FULL_SCHEMA,
                      handler=mythos_full_text, emoji="📜")
    try:
        threading.Thread(target=_inbox_loop, args=(ctx,), daemon=True, name="mythos-inbox").start()
    except Exception as e:
        _logline(f"收件匣執行緒起不來 {e}")
