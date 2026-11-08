#!/usr/bin/env python3
"""Hermes 控制迴路驗收（11-08）。python3 標準庫，全部路徑走環境變數指到暫存沙箱，
不讀寫真的 ~/.hermes、真告警檔、真 TG；呼叫 bin 腳本用 subprocess。

案例：
  (a) 使用者訊息 15 分鐘前、之後無回覆 → router-silent 告警
  (a2) 使用者訊息 5 分鐘前（未超時）→ 不告警
  (b) 有回覆 → 不告警
  (c) 庫檔不存在 → unavailable（記 log＋告警），不是健康
  (d) schema 缺欄 → unavailable；(d2) 不是 sqlite 的檔 → unavailable
  (e) worker 連續 6 次同名同結果 → 產 review-judge 候選（judge 收到該工具名）；worker 活著、不殺
  (e2) rkey 對不到 session → UNKNOWN（記 log），不殺、不重派
  (f) 工具名持續變化 → 不產候選；(f2) 同名但結果不同 → 不產候選
  (g) idle-reset 在 hermes 模式不呼叫 tmux（對照：MYTHOS_RUNTIME=claude 會呼叫）
  (g2) ctx-guard 在 hermes 模式不送 /compact（對照：claude 模式會送）
"""
import atexit
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = tempfile.mkdtemp(prefix="hcl-test.")
atexit.register(lambda: shutil.rmtree(T, ignore_errors=True) if not os.environ.get("KEEP") else None)
NOW = int(time.time())
FAILS = []
SLEEPERS = []


def check(cond, msg):
    if not cond:
        FAILS.append(msg)
        print("FAIL:", msg, file=sys.stderr)


def read(p):
    try:
        with open(p, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


# ---- 假 bin（PATH 最前面）：出網守門、tmux 紀錄、claude agents 空清單 ----
STUBS = os.path.join(T, "stubs")
os.makedirs(STUBS)
TMUX_LOG = os.path.join(T, "tmux.log")
with open(os.path.join(STUBS, "curl"), "w") as f:
    f.write('#!/bin/sh\necho "curl $*" >> "$NET_LOG"\nexit 7\n')
with open(os.path.join(STUBS, "opencode"), "w") as f:
    f.write('#!/bin/sh\necho "opencode $*" >> "$NET_LOG"\nexit 7\n')
with open(os.path.join(STUBS, "tmux"), "w") as f:
    f.write('#!/bin/sh\necho "tmux $*" >> "$TMUX_LOG"\nexit 0\n')
with open(os.path.join(STUBS, "tmux-prompt"), "w") as f:  # ctx-guard 要看到輸入列 ❯ 才會送 /compact
    f.write('#!/bin/sh\necho "tmux $*" >> "$TMUX_LOG"\ncase "$*" in *capture-pane*) echo "❯";; esac\nexit 0\n')
with open(os.path.join(STUBS, "runner"), "w") as f:  # DISPATCH_DEEP_RUN_BIN 替身：測試不跑真 runner
    f.write('#!/bin/sh\necho "runner $*" >> "$NET_LOG"\nexit 0\n')
with open(os.path.join(STUBS, "claude"), "w") as f:
    f.write('#!/bin/sh\n[ "$1" = agents ] && { echo "[]"; exit 0; }\nexit 0\n')
with open(os.path.join(STUBS, "llm-none"), "w") as f:
    f.write('#!/bin/sh\ncat >/dev/null\necho "llm-none" >> "$NET_LOG"\nexit 1\n')
with open(os.path.join(STUBS, "tgsend.mjs"), "w") as f:
    f.write("process.stdin.resume(); process.exit(0);\n")
with open(os.path.join(STUBS, "judge"), "w") as f:  # review-judge 的替身：記下收到的工單與進度，回 ON_TRACK（不吵 Router）
    f.write('#!/bin/sh\nprintf "%s\\n---\\n" "$*" >> "$JUDGE_LOG"\necho ON_TRACK\n')
for n in ("curl", "opencode", "tmux", "tmux-prompt", "runner", "claude", "llm-none", "judge"):
    os.chmod(os.path.join(STUBS, n), 0o755)

BASE_ENV = {
    "PATH": STUBS + os.pathsep + "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME": os.path.join(T, "home"),
    "TMPDIR": os.path.join(T, "tmp"),
    "MYTHOS_TEST_SANDBOX": T,
    "MYTHOS_RUNTIME": "hermes",
    "NET_LOG": os.path.join(T, "net.log"),
    "TMUX_LOG": TMUX_LOG,
    "TMUX_BIN": os.path.join(STUBS, "tmux"),
    "CLAUDE_BIN": os.path.join(STUBS, "claude"),
    "WATCHDOG_CLAUDE_BIN": os.path.join(STUBS, "claude"),
    "TG_SEND_BIN": os.path.join(STUBS, "tgsend.mjs"),
    "WATCHDOG_LLM_LEGS": os.path.join(STUBS, "llm-none"),
    "WATCHDOG_LLM_TIMEOUT_S": "3",
    "CTX_GUARD_OFF": "1",
    "CLAUDE_PROJECTS_DIR": os.path.join(T, "projects"),
    "MYTHOS_TRANSCRIPT_DIR": os.path.join(T, "router-transcripts"),
    "BRIEF_LINES_DIR": os.path.join(T, "brief-lines"),
    "DCQ_HOME": os.path.join(T, "dcq"),
    "JUDGE_LOG": os.path.join(T, "judge.log"),
}
for d in ("home", "tmp", "projects", "router-transcripts", "brief-lines", "dcq"):
    os.makedirs(os.path.join(T, d), exist_ok=True)
os.makedirs(os.path.join(T, "home", ".hermes"), exist_ok=True)  # 沙箱的 HOME 底下沒有任何真的 hermes 資料


def run(cmd, env_extra, cwd=None, timeout=150):
    env = dict(BASE_ENV)
    env.update(env_extra)
    return subprocess.run(cmd, env=env, cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True,
                          text=True, timeout=timeout)


def new_mythos(case):
    d = os.path.join(T, "case-" + case, "mythos")
    for sub in ("state", "state/bg", "logs", "bots"):
        os.makedirs(os.path.join(d, sub), exist_ok=True)
    return d


def brief_path(mythos):
    return os.path.join(os.path.dirname(mythos), "brief", "mythos-watchdog.tsv")


# ======================= N11：Router 健康（bin/watchdog，hermes 模式） =======================
ROUTER_SCHEMA = """
CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, started_at REAL NOT NULL);
CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, role TEXT NOT NULL,
  content TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL NOT NULL, display_kind TEXT);
"""


def mk_db(path, messages, schema=ROUTER_SCHEMA, sessions=(("s1", "telegram", NOW - 3600),)):
    con = sqlite3.connect(path)
    con.executescript(schema)
    con.executemany("INSERT INTO sessions(id, source, started_at) VALUES (?,?,?)", sessions)
    if "display_kind" in schema:
        con.executemany("INSERT INTO messages(session_id, role, content, tool_calls, tool_name, timestamp, display_kind)"
                        " VALUES (?,?,?,?,?,?,?)", messages)
    else:  # schema 缺欄的案例：只插存在的欄
        con.executemany("INSERT INTO messages(session_id, role, content, tool_calls, tool_name, timestamp)"
                        " VALUES (?,?,?,?,?,?)", [m[:6] for m in messages])
    con.commit()
    con.close()


def watchdog(mythos, router_db, extra=None):
    env = {"MYTHOS_DIR": mythos, "MYTHOS_BRIEF_DIR": os.path.join(os.path.dirname(mythos), "brief"),
           "MYTHOS_ROUTER_DB": router_db, "MYTHOS_WORKER_DB": os.path.join(T, "no-worker.db")}
    env.update(extra or {})
    os.makedirs(os.path.join(os.path.dirname(mythos), "brief"), exist_ok=True)
    return run(["bash", os.path.join(ROOT, "bin", "watchdog")], env)


def wlog(mythos):
    return read(os.path.join(mythos, "logs", "watchdog.log"))


# (a) 15 分鐘前的使用者訊息，之後只有工具呼叫、沒有最終回覆
m = new_mythos("a")
db = os.path.join(T, "case-a", "router.db")
mk_db(db, [
    (("s1"), "user", "hi", None, None, NOW - 900, None),
    (("s1"), "assistant", None, '[{"name":"mythos_dispatch"}]', None, NOW - 800, None),
    (("s1"), "tool", "ok", None, "mythos_dispatch", NOW - 790, None),
])
r = watchdog(m, db)
check(r.returncode == 0, "(a) watchdog 非零退出：%s" % r.stderr[-300:])
check("router-silent" in wlog(m), "(a) 沒有 router-silent 告警記錄；log=%r" % wlog(m)[-300:])
check("Router 無回覆" in read(brief_path(m)), "(a) 告警沒寫進 brief：%r" % read(brief_path(m))[-300:])

# (a2) 5 分鐘前的使用者訊息：還沒超過 10 分鐘，不告警
m = new_mythos("a2")
db = os.path.join(T, "case-a2", "router.db")
mk_db(db, [(("s1"), "user", "hi", None, None, NOW - 300, None)])
watchdog(m, db)
check("router-silent" not in wlog(m), "(a2) 未超時卻告警")

# (b) 同一則之後有最終回覆 → 不告警
m = new_mythos("b")
db = os.path.join(T, "case-b", "router.db")
mk_db(db, [
    (("s1"), "user", "hi", None, None, NOW - 900, None),
    (("s1"), "assistant", "好的", None, None, NOW - 600, None),
])
r = watchdog(m, db)
check(r.returncode == 0, "(b) watchdog 非零退出：%s" % r.stderr[-300:])
check("router-silent" not in wlog(m) and "Router 無回覆" not in read(brief_path(m)), "(b) 已回覆卻告警")
check("UNAVAILABLE" not in wlog(m), "(b) 正常庫被判 unavailable")

# (c) 庫檔不存在 → unavailable，不是健康
m = new_mythos("c")
r = watchdog(m, os.path.join(T, "case-c", "no-such.db"))
check(r.returncode == 0, "(c) watchdog 非零退出：%s" % r.stderr[-300:])
check("UNAVAILABLE router-hermes missing" in wlog(m), "(c) 庫不存在沒有記 unavailable；log=%r" % wlog(m)[-300:])
check("判不了" in read(brief_path(m)), "(c) unavailable 沒有走告警出口")

# (d) schema 缺欄 → unavailable
m = new_mythos("d")
db = os.path.join(T, "case-d", "router.db")
os.makedirs(os.path.dirname(db), exist_ok=True)
mk_db(db, [(("s1"), "user", "hi", None, None, NOW - 900, None)],
      schema=ROUTER_SCHEMA.replace(", display_kind TEXT", ""))
r = watchdog(m, db)
check("UNAVAILABLE router-hermes schema" in wlog(m) and "display_kind" in wlog(m),
      "(d) schema 缺欄沒有判 unavailable；log=%r" % wlog(m)[-300:])
check("router-silent" not in wlog(m), "(d) schema 不符時不該判 router-silent")

# (d2) 不是 sqlite 的檔 → unavailable（查詢錯）
m = new_mythos("d2")
db = os.path.join(T, "case-d2", "router.db")
with open(db, "wb") as f:
    f.write(b"this is not a sqlite database at all" * 40)
watchdog(m, db)
check("UNAVAILABLE router-hermes query" in wlog(m), "(d2) 壞檔沒有判 unavailable；log=%r" % wlog(m)[-300:])


# ======================= N12：worker 進度（bin/dispatch-watch，hermes pending 分支） =======================
WORKER_SCHEMA = ROUTER_SCHEMA  # 同一組表與欄（真的 state.db 欄位更多，這裡只放本功能會讀的）


def start_sleeper():
    p = subprocess.Popen(["sleep", "600"])
    SLEEPERS.append(p)
    return p


def worker_case(case, names_results, rk, with_session=True, rkey_ok=True):
    """建一個 hermes pending job（pid 活著、rkey 有值）＋worker 庫。回 (mythos, sid, pid_proc, judge_log)。"""
    m = new_mythos(case)
    cdir = os.path.join(T, "case-" + case)
    sid = "%08x" % (abs(hash(case)) & 0xFFFFFFFF)
    p = start_sleeper()
    with open(os.path.join(m, "state", "bg", sid + ".pid"), "w") as f:
        f.write("%d\n" % p.pid)
    with open(os.path.join(m, "state", "bg", sid + ".rkey"), "w") as f:
        f.write(rk + "\n")
    prompt = os.path.join(cdir, "prompt.md")
    with open(prompt, "w", encoding="utf-8") as f:
        f.write("測試工單：修正某檔並驗收\n")
    epoch = NOW - 1200
    with open(os.path.join(m, "state", "dispatch-jobs.tsv"), "w") as f:
        f.write("\t".join(["bg-" + sid, "mid", prompt, str(epoch), "pending",
                           os.path.join(cdir, "worker"), "t-" + case, "hermes"]) + "\n")
    wdb = os.path.join(cdir, "worker.db")
    msgs = []
    if with_session:
        ts0 = NOW - 1100
        if rkey_ok:
            body = "結果檔：%s/state/bg/r-%s.result（本輪專用）\n測試工單" % (m, rk)
        else:
            body = "沒有結果檔路徑的 prompt"
        msgs.append(("w1", "user", body, None, None, ts0, None))
        for i, (name, res) in enumerate(names_results):
            msgs.append(("w1", "tool", res, None, name, ts0 + 10 * (i + 1), None))
    mk_db(wdb, msgs, schema=WORKER_SCHEMA,
          sessions=(("w1", "oneshot", NOW - 1100),) if with_session else ())
    return m, sid, p, wdb


def watch(m, wdb, judge=True):
    env = {"MYTHOS_DIR": m, "MYTHOS_WORKER_DB": wdb, "MYTHOS_WORKER_DIR": os.path.join(T, "worker-dir"),
           "BRIEF_LINES_DIR": os.path.join(T, "brief-lines"), "BG_STALL_MIN": "100000",
           "BG_PERM_MIN": "100000", "BG_NOSTART_MIN": "100000", "RESEND_SEC": "100000",
           "REVIEW_JUDGE": os.path.join(STUBS, "judge") if judge else os.path.join(T, "no-judge"),
           "MYTHOS_TRANSCRIPT_DIR": os.path.join(T, "router-transcripts"),
           # 測試守門要求 runner／tmux／claude 都在沙箱內（dispatch-watch 的 MYTHOS_TEST_SANDBOX 檢查）
           "DISPATCH_DEEP_RUN_BIN": os.path.join(STUBS, "runner"), "TMUX_BIN": os.path.join(STUBS, "tmux"),
           "CLAUDE_BIN": os.path.join(STUBS, "claude")}
    return run(["bash", os.path.join(ROOT, "bin", "dispatch-watch")], env, timeout=170)


SAME = [("terminal", "same output")] * 6
RK = str(NOW - 1200) + "-4242"

# (e) 連續 6 次同名同結果 → 候選，judge 收到工具名
m, sid, p, wdb = worker_case("e", SAME, RK)
r = watch(m, wdb)
wl = read(os.path.join(m, "logs", "dispatch-watch.log"))
check(r.returncode == 0, "(e) dispatch-watch 非零退出：%s" % r.stderr[-300:])
check("hermes-loop 候選 bg-" + sid in wl, "(e) 沒有產生候選；watch log=%r" % wl[-400:])
jl = read(os.path.join(T, "judge.log"))
check("terminal" in jl, "(e) judge 沒收到 terminal 進度；judge.log=%r" % jl[-300:])
check(p.poll() is None, "(e) 活著的 worker 被殺掉")
check("bg-" + sid in read(os.path.join(m, "state", "dispatch-jobs.tsv")) and
      "pending" in read(os.path.join(m, "state", "dispatch-jobs.tsv")), "(e) 候選不該改 ledger 狀態")
p.kill()

# (e2) rkey 對不到任何 session → UNKNOWN，不殺、不重派
m, sid, p, wdb = worker_case("e2", SAME, RK, with_session=False)
r = watch(m, wdb)
wl = read(os.path.join(m, "logs", "dispatch-watch.log"))
check("hermes-loop" in wl and "UNKNOWN" in wl, "(e2) 對不到 session 沒有記 UNKNOWN；watch log=%r" % wl[-300:])
check("hermes-loop 候選" not in wl, "(e2) 對不到 session 卻產生候選")
check(p.poll() is None, "(e2) 對不到 session 時 worker 被殺")
check("pending" in read(os.path.join(m, "state", "dispatch-jobs.tsv")), "(e2) 對不到 session 時 ledger 被改")
p.kill()

# (f) 工具名一直變 → 不產候選
VARY = [("terminal", "a"), ("read_file", "b"), ("terminal", "c"), ("patch", "d"),
        ("search_files", "e"), ("terminal", "f"), ("read_file", "g")]
if os.path.exists(os.path.join(T, "judge.log")):  # judge.log 跨案例共用，本案例要從零開始數
    os.remove(os.path.join(T, "judge.log"))
m, sid, p, wdb = worker_case("f", VARY, RK)
watch(m, wdb)
wl = read(os.path.join(m, "logs", "dispatch-watch.log"))
check("hermes-loop 候選" not in wl, "(f) 工具名持續變化卻產生候選")
check(not os.path.exists(os.path.join(T, "judge.log")), "(f) 工具名持續變化卻叫了 judge")
p.kill()

# (f2) 同名但結果每次不同 → 不算同結果，不產候選
DIFF = [("terminal", "out %d" % i) for i in range(6)]
m, sid, p, wdb = worker_case("f2", DIFF, RK)
watch(m, wdb)
wl = read(os.path.join(m, "logs", "dispatch-watch.log"))
check("hermes-loop 候選" not in wl, "(f2) 同名不同結果卻產生候選")
p.kill()


# ======================= N09：idle-reset／ctx-guard 在 hermes 模式不送鍵 =======================
def idle_case(case, runtime):
    d = os.path.join(T, "idle-" + case)
    proj = os.path.join(d, "proj")
    os.makedirs(proj, exist_ok=True)
    jl = os.path.join(proj, "old.jsonl")
    with open(jl, "w") as f:
        f.write('{"type":"user"}\n')
    old = NOW - 3 * 3600
    os.utime(jl, (old, old))
    tlog = os.path.join(d, "tmux.log")
    env = {"PROJ": proj, "STAMP": os.path.join(d, "stamp"), "IDLE_MIN": "0", "TMUX_BIN": os.path.join(STUBS, "tmux"),
           "TMUX_LOG": tlog, "MYTHOS_RUNTIME": runtime}
    r = run(["sh", os.path.join(ROOT, "bin", "idle-reset")], env)
    return r, read(tlog)


r, tlog = idle_case("hermes", "hermes")
check(r.returncode == 0, "(g) idle-reset 非零退出：%s" % r.stderr[-300:])
check(tlog == "", "(g) hermes 模式仍呼叫了 tmux：%r" % tlog[:200])
check("skip hermes" in r.stdout, "(g) hermes 模式沒有 log skip hermes；stdout=%r" % r.stdout[:200])
r, tlog = idle_case("claude", "claude")
check("send-keys" in tlog and "/clear" in tlog, "(g) 對照組：claude 模式應送 /clear，tmux.log=%r" % tlog[:300])


def ctx_case(case, runtime):
    d = os.path.join(T, "ctx-" + case)
    rd = os.path.join(d, "router")
    os.makedirs(rd, exist_ok=True)
    jl = os.path.join(rd, "rsess.jsonl")
    with open(jl, "w") as f:
        f.write('{"type":"assistant","message":{"model":"claude-x","usage":{"input_tokens":150000,'
                '"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":10}}}\n')
    old = NOW - 3600
    os.utime(jl, (old, old))
    tlog = os.path.join(d, "tmux.log")
    tsv = os.path.join(d, "jobs.tsv")
    open(tsv, "w").close()
    env = {"MYTHOS_DIR": os.path.join(d, "mythos"), "CTX_STATE_DIR": os.path.join(d, "state"),
           "CTX_LOG": os.path.join(d, "ctx.log"), "CTX_DIRS": rd, "CTX_ROUTER_DIR": rd,
           "CTX_TSV": tsv, "CTX_TMUX_BIN": os.path.join(STUBS, "tmux-prompt"), "CTX_CLAUDE_BIN": os.path.join(STUBS, "claude"),
           "TMUX_LOG": tlog, "CTX_ROUTER_IDLE": "140000", "CTX_ROUTER_QUIET_SEC": "180", "MYTHOS_RUNTIME": runtime}
    os.makedirs(os.path.join(d, "state"), exist_ok=True)
    r = run(["python3", os.path.join(ROOT, "bin", "ctx-guard"), "scan"], env)
    return r, read(os.path.join(d, "ctx.log")), read(tlog)


r, clog, tlog = ctx_case("hermes", "hermes")
check(r.returncode == 0, "(g2) ctx-guard 非零退出：%s" % r.stderr[-300:])
check("skip hermes" in clog, "(g2) hermes 模式沒有 log skip hermes；ctx.log=%r" % clog[-300:])
check("send-keys" not in tlog, "(g2) hermes 模式仍送了 tmux 鍵：%r" % tlog[:200])
r, clog, tlog = ctx_case("claude", "claude")
check("send-keys" in tlog and "/compact" in tlog, "(g2) 對照組：claude 模式應送 /compact，tmux.log=%r ctx.log=%r"
      % (tlog[:200], clog[-200:]))


# ======================= 收尾 =======================
for p in SLEEPERS:
    try:
        p.kill()
    except OSError:
        pass

if FAILS:
    print("CONTROL_LOOP_FAIL (%d)" % len(FAILS))
    sys.exit(1)
print("CONTROL_LOOP_OK")
