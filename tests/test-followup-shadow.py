#!/usr/bin/env python3
"""P6 ② 驗收：follow-up 直通三值模式與影子判定。
- observe：跑同一份判定，只寫 observations.jsonl；不入列、不派 worker、不呼叫 Telegram；exit 3。
- off（未設定／其他值）：完全不寫任何東西，exit 3。
- auto（與舊值 1 同義）：同事件重播只入列一次；--seen 查得到。
- bin/followup-report：候選數、would_queue 數、reason 計數、與 Router 的 thread 一致率。
全在 mktemp 沙箱：hermes／TG／claude 都是 stub；不連網。
用法：python3 tests/test-followup-shadow.py → 全過印 FOLLOWUP_SHADOW_OK。"""
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
REPORT = os.path.join(ROOT, "bin", "followup-report")

TMP = tempfile.mkdtemp(prefix="followup-shadow.")
atexit.register(shutil.rmtree, TMP, True)
MD = os.path.join(TMP, "mythos")
ST = os.path.join(MD, "state")
BG = os.path.join(ST, "bg")
MB = os.path.join(ST, "mailbox")
TSV = os.path.join(ST, "dispatch-jobs.tsv")
MAP = os.path.join(ST, "tg-msg-thread.tsv")
RCPT = os.path.join(ST, "followup", "receipts.tsv")
OBS = os.path.join(ST, "followup", "observations.jsonl")
BG_CALLS = os.path.join(TMP, "bg-calls.log")
TG_CALLS = os.path.join(TMP, "tg-calls.log")
THREAD = "t-sh01"
CHAT = 555
SECRET_TEXT = "SECRET-原文-不得出現在觀察檔"
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
TG_STUB = stub("tg-stub", 'echo "$*" >> "%s"\nexit 0\n' % TG_CALLS)


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
        "TG_SEND_BIN": TG_STUB,
        "TMUX_BIN": NOOP,
        "DISPATCH_DEEP_RUN_BIN": NOOP,
        "DEEP_RUN_BIN": NOOP,
        "BG_AUTOHEAL": "0",
        "CTX_GUARD_OFF": "1",
        "DISPATCH_BG_NO_TRIGGER": "1",
        "MYTHOS_HERMES_SLOTS": "10",
        "DW_DEADLINE_ARMED": "1",
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


def obs_lines():
    return [json.loads(l) for l in read(OBS).splitlines() if l.strip()]


def follow(mode, fmid, rmid, text, **extra):
    e = env_for(**extra)
    if mode is None:
        e.pop("MYTHOS_FOLLOWUP_DIRECT", None)
    else:
        e["MYTHOS_FOLLOWUP_DIRECT"] = mode
    return run([FOLLOWUP, str(CHAT), str(fmid), str(rmid)], e, stdin=text)


def mailbox_files():
    return glob.glob(os.path.join(MB, "**", "fu-*.md"), recursive=True)


def receipts_all():
    return [l.split("\t") for l in read(RCPT).splitlines() if l.strip()]


# ---- 基底 ----
P0 = write_prompt(THREAD, "原需求：查 S 服務\n")
with open(TSV, "a", encoding="utf-8") as f:
    f.write("\t".join(["bg-sh1", "mid", P0, str(int(time.time())), "done", TMP, THREAD, "hermes"]) + "\n")
with open(MAP, "a", encoding="utf-8") as f:
    f.write(f"{CHAT}\t100\t{THREAD}\tbg-sh1\t{int(time.time())}\n")

# ---- off：未設定與其他值都完全不碰檔 ----
for mode in (None, "0", "yes", "OBSERVE"):
    rc, out, err = follow(mode, 4000, 100, SECRET_TEXT)
    if rc != 3:
        fail(f"模式 {mode!r} 應 exit 3，實際 {rc}")
if os.path.exists(OBS) or mailbox_files() or os.path.exists(RCPT):
    fail("off 模式不得寫任何觀察、信箱或收據")
print("OFF ok: unset_or_unknown_touches_nothing")

# ---- observe：判定照跑，但不入列、不派、不 TG，exit 3 ----
rc, out, err = follow("observe", 4001, 100, f"補充 S1 {SECRET_TEXT}")
if rc != 3:
    fail(f"observe 應 exit 3，實際 {rc} err={err}")
if mailbox_files() or receipts_all() or os.path.exists(os.path.join(MB, THREAD)):
    fail("observe 不得入列、不得建信箱或收據")
watch_rc, _, werr = run(["bash", DISPATCH_WATCH], env_for(DISPATCH_BG_BIN=BG_STUB))
if watch_rc != 0:
    fail(f"dispatch-watch 非零：{werr}")
if THREAD in read(BG_CALLS):
    fail("observe 之後 worker 不得被派出")
if os.path.exists(TG_CALLS):
    fail("observe 不得呼叫 Telegram")
obs = obs_lines()
if len(obs) != 1:
    fail(f"observe 應寫一筆觀察：{obs}")
o = obs[0]
want_keys = {"v", "ts", "event_key", "chat_id", "message_id", "reply_to", "thread", "job",
             "generation", "policy_version", "would_queue", "reason"}
if set(o.keys()) != want_keys:
    fail(f"觀察欄位不對：{sorted(o.keys())}")
if (o["v"], o["event_key"], o["thread"], o["job"], o["generation"], o["would_queue"], o["reason"]) != \
        (1, f"{CHAT}:4001", THREAD, "bg-sh1", 0, True, "ok"):
    fail(f"觀察內容不對：{o}")
if len(o["policy_version"]) != 8 or any(c not in "0123456789abcdef" for c in o["policy_version"]):
    fail(f"policy_version 應為 sha1 前 8 碼：{o['policy_version']!r}")
if SECRET_TEXT in read(OBS):
    fail("觀察檔不得含使用者原文")
print("OBSERVE ok: judged_no_queue_no_worker_no_tg exit3 observation_written")

# 同事件再觀察一次：觀察檔可以有兩行，報表以最後一筆為準
follow("observe", 4001, 100, "again")
# 其他判定理由：未綁定、新話題
follow("observe", 4007, 9999, "未綁定的")
follow("observe", 4008, 100, "新題：查別的")
obs = obs_lines()
reasons = {x["event_key"]: (x["would_queue"], x["reason"], x["thread"]) for x in obs}
if reasons.get(f"{CHAT}:4007") != (False, "unbound", ""):
    fail(f"未綁定應記 unbound 且 thread 空：{reasons}")
if reasons.get(f"{CHAT}:4008") != (False, "new_topic", THREAD):
    fail(f"新話題應記 new_topic：{reasons}")
print("REASONS ok: unbound_and_new_topic_recorded")

# ---- 報表 ----
routed = os.path.join(TMP, "routed.tsv")
with open(routed, "w", encoding="utf-8") as f:
    f.write(f"{CHAT}:4001\t{THREAD}\n")     # 一致
    f.write(f"{CHAT}:4008\tt-other1\n")     # 不一致
    f.write(f"{CHAT}:4007\t\n")             # Router 沒綁 thread：不比對
rp = run([REPORT, "--routed", routed], env_for())
if rp[0] != 0:
    fail(f"report 失敗：{rp[2]}")
lines = rp[1].splitlines()
for want in ("候選數 candidates=3", "would_queue=1", "reason ok=1", "reason new_topic=1",
             "reason unbound=1", "routed_compared=2 thread_agree=1 agree_rate=50.0%"):
    if want not in lines:
        fail(f"報表缺 {want!r}：{lines}")
if SECRET_TEXT in rp[1]:
    fail("報表不得含原文")
print("REPORT ok: counts_and_agreement")

# ---- auto：同事件重播只入列一次；舊值 1 同 auto；--seen ----
rc, out, err = follow("auto", 4002, 100, "補充 A2")
if rc != 0 or out.strip() != f"queued {THREAD}":
    fail(f"auto 首次應入列：rc={rc} out={out} err={err}")
rc, out, err = follow("auto", 4002, 100, "補充 A2")
if rc != 0 or out.strip() != f"dup {THREAD}":
    fail(f"auto 重播應 dup：rc={rc} out={out} err={err}")
rc, out, err = follow("1", 4003, 100, "補充 A3")
if rc != 0 or out.strip() != f"queued {THREAD}":
    fail(f"舊值 1 應同 auto 入列：rc={rc} out={out} err={err}")
if len(glob.glob(os.path.join(MB, THREAD, "**", "fu-555-4002.md"), recursive=True)) != 1:
    fail("auto 重播不得多建信箱檔")
queued_4002 = [r for r in receipts_all() if r[1] == "queued" and r[3] == "4002"]
if len(queued_4002) != 1:
    fail(f"auto 同事件應只有一筆 queued：{queued_4002}")
seen = run([FOLLOWUP, "--seen", str(CHAT), "4002"], env_for())
if seen[0] != 0 or seen[1].strip() != f"seen {THREAD}":
    fail(f"--seen 已入列的事件應 exit 0：rc={seen[0]} out={seen[1]}")
seen2 = run([FOLLOWUP, "--seen", str(CHAT), "4999"], env_for())
if seen2[0] != 1:
    fail(f"--seen 沒入列的事件應 exit 1，實際 {seen2[0]}")
# observe 模式下 --seen 不看模式，照樣查得到
seen3 = run([FOLLOWUP, "--seen", str(CHAT), "4002"], env_for(MYTHOS_FOLLOWUP_DIRECT="observe"))
if seen3[0] != 0:
    fail("--seen 不應受模式影響")
print("AUTO ok: replay_queued_once legacy_1_is_auto seen_query")

print("FOLLOWUP_SHADOW_OK")
