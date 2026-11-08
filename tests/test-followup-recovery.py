#!/usr/bin/env python3
"""P6 ③ 驗收：follow-up 直通的事件鍵收據與可恢復入列。
- rename 後、queued 收據前中斷 → 重跑恰好一次（不重複入列，回 dup）。
- 重啟對帳：dispatch-watch 先補標 queued，只派出一次。
- 同事件重播兩次只入列一次。
- 入列途中被取消（pending 後 generation 變了）→ 重跑不入列（舊 generation 不復活）。
全在 mktemp 沙箱：hermes／TG／claude 都是 stub；不連網。
用法：python3 tests/test-followup-recovery.py → 全過印 FOLLOWUP_RECOVERY_OK。"""
import atexit
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISPATCH_BG = os.path.join(ROOT, "bin", "dispatch-bg")
DISPATCH_WATCH = os.path.join(ROOT, "bin", "dispatch-watch")
FOLLOWUP = os.path.join(ROOT, "bin", "followup-direct")

TMP = tempfile.mkdtemp(prefix="followup-recovery.")
atexit.register(shutil.rmtree, TMP, True)
MD = os.path.join(TMP, "mythos")
ST = os.path.join(MD, "state")
BG = os.path.join(ST, "bg")
MB = os.path.join(ST, "mailbox")
TSV = os.path.join(ST, "dispatch-jobs.tsv")
MAP = os.path.join(ST, "tg-msg-thread.tsv")
RCPT = os.path.join(ST, "followup", "receipts.tsv")
BG_CALLS = os.path.join(TMP, "bg-calls.log")
THREAD = "t-rc01"
CHAT = 777
for d in (BG, MB, os.path.join(ST, "followup"), os.path.join(MD, "logs"), os.path.join(TMP, "worker"),
          os.path.join(TMP, "rt"), os.path.join(TMP, "projects"), os.path.join(TMP, "dcq"),
          os.path.join(TMP, "home"), os.path.join(TMP, "brief"), os.path.join(TMP, "bin")):
    os.makedirs(d, exist_ok=True)


def fail(msg):
    sys.exit("FAIL: " + msg)


def stub(name, body):
    p = os.path.join(TMP, "bin", name)
    with open(p, "w", encoding="utf-8") as f:
        f.write("#!/bin/sh\n" + body)
    os.chmod(p, 0o755)
    return p


NOOP = stub("noop", "exit 0\n")
TRIAGE = stub("triage", "echo mid\n")
BG_STUB = stub("bg-stub", 'echo "$*" >> "%s"\nexit 0\n' % BG_CALLS)


def env_for(**extra):
    e = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
        "HOME": os.path.join(TMP, "home"),
        "LANG": "C.UTF-8",
        "TMPDIR": TMP,
        "MYTHOS_DIR": MD,
        "MYTHOS_TEST_SANDBOX": TMP,
        "DISPATCH_BG_WORKER": "hermes",
        "DISPATCH_BG_BIN": DISPATCH_BG,
        "MYTHOS_WORKER_DIR": os.path.join(TMP, "worker"),
        "MYTHOS_WORKER_DB": os.path.join(TMP, "no-such.db"),
        "MYTHOS_TRANSCRIPT_DIR": os.path.join(TMP, "rt"),
        "CLAUDE_PROJECTS_DIR": os.path.join(TMP, "projects"),
        "CLAUDE_BIN": NOOP,
        "DCQ_BIN": NOOP,
        "DCQ_HOME": os.path.join(TMP, "dcq"),
        "BRIEF_LINES_DIR": os.path.join(TMP, "brief"),
        "DISPATCH_GATE_TRIAGE": TRIAGE,
        "TG_SEND_BIN": NOOP,
        "TMUX_BIN": NOOP,
        "DISPATCH_DEEP_RUN_BIN": NOOP,
        "DEEP_RUN_BIN": NOOP,
        "BG_AUTOHEAL": "0",
        "CTX_GUARD_OFF": "1",
        "DISPATCH_BG_NO_TRIGGER": "1",
        "MYTHOS_HERMES_SLOTS": "10",
        "DW_DEADLINE_ARMED": "1",
        "MYTHOS_FOLLOWUP_DIRECT": "auto",
    }
    e.update(extra)
    return e


def run(args, env, stdin=None):
    p = subprocess.run(args, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       text=True, env=env, timeout=90)
    return p.returncode, p.stdout, p.stderr


def read(p):
    try:
        with open(p, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def write_prompt(name, text):
    p = os.path.join(BG, f"{name}-{time.time_ns()}.md")
    with open(p, "w", encoding="utf-8") as f:
        f.write(text)
    return p


def receipts(event=None, fmid=None):
    rows = [l.split("\t") for l in read(RCPT).splitlines() if l.strip()]
    return [r for r in rows if (event is None or r[1] == event) and (fmid is None or r[3] == str(fmid))]


def fu_files(fmid):
    # os.walk 才會進隱藏目錄（.consumed／.batch）；glob 的 ** 不匹配 dot 目錄
    name = f"fu-{CHAT}-{fmid}.md"
    hits = []
    for root, _dirs, files in os.walk(os.path.join(MB, THREAD)):
        if name in files:
            hits.append(os.path.join(root, name))
    return hits


def dispatch_count():
    return sum(1 for l in read(BG_CALLS).splitlines() if THREAD in l)


def watch():
    rc, out, err = run(["bash", DISPATCH_WATCH], env_for(DISPATCH_BG_BIN=BG_STUB))
    if rc != 0:
        fail(f"dispatch-watch 非零：{err}")


def follow(fmid, rmid, text, **extra):
    return run([FOLLOWUP, str(CHAT), str(fmid), str(rmid)], env_for(**extra), stdin=text)


# ---- 基底：一張已完成的 job，rmid 100 綁到它 ----
P0 = write_prompt(THREAD, "repo=/example/project\nreadonly=1\n原需求：查 R 服務\n")
with open(TSV, "a", encoding="utf-8") as f:
    f.write("\t".join(["bg-rc1", "mid", P0, str(int(time.time())), "done", TMP, THREAD, "hermes"]) + "\n")
with open(MAP, "a", encoding="utf-8") as f:
    f.write(f"{CHAT}\t100\t{THREAD}\tbg-rc1\t{int(time.time())}\n")

# A：rename 後、queued 收據前中斷（模擬 kill）
rc, out, err = follow(3001, 100, "補充 A", FOLLOWUP_TEST_FAULT="after-rename")
if rc != 97:
    fail(f"模擬中斷應 exit 97，實際 {rc} err={err}")
if not receipts("pending", 3001) or receipts("queued", 3001):
    fail(f"中斷後應只有 pending 收據：{read(RCPT)}")
if len(fu_files(3001)) != 1:
    fail("中斷後信箱應已有 fu 檔（rename 已完成）")

# B：重啟（dispatch-watch）對帳：補標 queued、派出一次
watch()
if dispatch_count() != 1:
    fail(f"重啟後應恰好派出一次，實際 {dispatch_count()}：{read(BG_CALLS)}")
if len(receipts("queued", 3001)) != 1:
    fail(f"重啟對帳應補一筆 queued：{read(RCPT)}")
batch_prompt = read(os.path.join(MB, THREAD, ".batch", "prompt-path")).strip()
# 成功消費後 .batch 會清掉；由 stub argv 取實際批次 prompt。
if not batch_prompt:
    batch_prompt = read(BG_CALLS).splitlines()[0].split()[-1]
batch_meta = json.loads(read(batch_prompt + ".meta.json"))
if batch_meta.get("repo") != "/example/project" or not batch_meta.get("readonly"):
    fail(f"MAILBOX_LEGACY_META: 舊 job 正式標頭必須帶入批次 meta：{batch_meta}")
print("MAILBOX_LEGACY_META ok")
watch()  # 再跑一輪不得重派
if dispatch_count() != 1:
    fail("對帳後再跑 dispatch-watch 不得重派")
print("RESTART_RECONCILE ok: dispatched_once_after_restart")

# C：同一事件重跑 followup-direct → dup，不重新入列
rc, out, err = follow(3001, 100, "補充 A")
if rc != 0 or out.strip() != f"dup {THREAD}":
    fail(f"重跑已入列的事件應回 dup：rc={rc} out={out} err={err}")
if len(receipts("queued", 3001)) != 1 or len(receipts("pending", 3001)) != 1:
    fail(f"重跑不得再寫收據：{read(RCPT)}")
print("RETRY_ONCE ok: rerun_after_fault_returns_dup")

# D：同事件重播兩次只入列一次（不經過中斷）
rc, out, err = follow(3005, 100, "補充 D")
if rc != 0 or out.strip() != f"queued {THREAD}":
    fail(f"首次應入列：rc={rc} out={out} err={err}")
rc, out, err = follow(3005, 100, "補充 D")
if rc != 0 or out.strip() != f"dup {THREAD}":
    fail(f"重播應 dup：rc={rc} out={out} err={err}")
if len(fu_files(3005)) != 1 or len(receipts("queued", 3005)) != 1:
    fail("重播兩次只能有一個信箱檔與一筆 queued")
print("REPLAY_TWICE ok: queued_once")

# E：入列途中被取消：pending 後 generation 變了 → 重跑不入列
rc, out, err = follow(3006, 100, "補充 E", FOLLOWUP_TEST_FAULT="after-rename")
if rc != 97:
    fail(f"E 模擬中斷應 exit 97，實際 {rc}")
rc, out, err = run([DISPATCH_BG, "--cancel", THREAD], env_for())
if rc != 0:
    fail(f"cancel 失敗：{err}")
rc, out, err = follow(3006, 100, "補充 E")
if rc != 7:
    fail(f"取消後的 pending 重跑應 exit 7（舊 generation 不復活），實際 {rc} out={out} err={err}")
if receipts("queued", 3006) or fu_files(3006):
    fail("取消後不得補標 queued、不得留下信箱檔")
if not receipts("stale", 3006):
    fail("取消後應寫 stale 收據")
print("CANCEL_PENDING ok: cancelled_pending_not_revived")

# F：rename 後中斷，信箱檔已被消費（搬進 .consumed），還沒跑 dispatch-watch 就重跑 followup-direct
# → 必須 dup（followup-direct 自己的對帳），不得再寫一份信箱檔造成重派
rc, out, err = follow(3007, 100, "補充 F", FOLLOWUP_TEST_FAULT="after-rename")
if rc != 97:
    fail(f"F 模擬中斷應 exit 97，實際 {rc}")
consumed = os.path.join(MB, THREAD, ".consumed")
os.makedirs(consumed, exist_ok=True)
for p in fu_files(3007):
    os.replace(p, os.path.join(consumed, os.path.basename(p)))
rc, out, err = follow(3007, 100, "補充 F")
if rc != 0 or out.strip() != f"dup {THREAD}":
    fail(f"消費後重跑應 dup（不重新入列）：rc={rc} out={out} err={err}")
if len(fu_files(3007)) != 1 or len(receipts("queued", 3007)) != 1:
    fail(f"消費後重跑不得再寫信箱檔：files={fu_files(3007)} {read(RCPT)}")
print("CONSUMED_NO_REQUEUE ok: rerun_after_consume_returns_dup")

# G（P6c）：rename 後中斷，之後 thread 被取消／改派而 generation 變了（dispatch-bg 先 bump generation、再清信箱，
# 兩步之間或清信箱失敗時信箱檔還在）→ dispatch-watch 對帳不得補標 queued：補標會讓 --seen／dup 回「已直通」，
# 但信箱檔其實會因舊 generation 被丟進 .stale，追問就憑空消失。
rc, out, err = follow(3008, 100, "補充 G", FOLLOWUP_TEST_FAULT="after-rename")
if rc != 97:
    fail(f"G 模擬中斷應 exit 97，實際 {rc}")
if len(fu_files(3008)) != 1:
    fail("G 前提：中斷後信箱應已有 fu 檔")
gp = os.path.join(ST, "followup", f"gen-{THREAD}")
cur = int((read(gp).strip() or "0"))
with open(gp, "w", encoding="utf-8") as f:
    f.write(f"{cur + 1}\n")  # 只 bump、不清信箱：等同 dispatch-bg 取消到一半
watch()
if receipts("queued", 3008):
    fail(f"generation 已變的對帳不得補標 queued：{read(RCPT)}")
rc, out, err = run([FOLLOWUP, "--seen", str(CHAT), "3008"], env_for())
if rc == 0:
    fail(f"--seen 不得回已直通：{out}")
watch()
n_stale = len(receipts("stale", 3008))
watch()
if not n_stale or len(receipts("stale", 3008)) != n_stale or receipts("queued", 3008):
    fail(f"舊 generation 應有 stale 收據、重跑不再增加、且沒有 queued：{read(RCPT)}")
print("CANCEL_RECONCILE ok: stale_not_queued")

print("FOLLOWUP_RECOVERY_OK")
