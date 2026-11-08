#!/usr/bin/env python3
"""P4 驗收：N03 同 repo 寫入序列化、N02 follow-up 直通（flag）、G08 interrupt 前情與 mailbox 留存 .consumed/。
全在 mktemp 沙箱：MYTHOS_DIR 指暫存目錄；hermes／claude／TG／triage／DCQ 都是 stub；不打真 TG、不起真 hermes、不碰 ~/.hermes（HOME 也指沙箱）。
用法：python3 tests/test-thread-routing.py → 全過印 THREAD_ROUTING_OK。"""
import atexit
import glob
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

TMP = tempfile.mkdtemp(prefix="thread-routing.")
atexit.register(shutil.rmtree, TMP, True)
MD = os.path.join(TMP, "mythos")
ST = os.path.join(MD, "state")
BG = os.path.join(ST, "bg")
MB = os.path.join(ST, "mailbox")
QD = os.path.join(ST, "hermes-queue")
TSV = os.path.join(ST, "dispatch-jobs.tsv")
MAP = os.path.join(ST, "tg-msg-thread.tsv")
RCPT = os.path.join(ST, "followup", "receipts.tsv")
HERMES_LOG = os.path.join(TMP, "hermes.log")
HOLD = os.path.join(TMP, "hold")
BG_CALLS = os.path.join(TMP, "bg-calls.log")
REPO_A = os.path.join(TMP, "repo-a")
REPO_B = os.path.join(TMP, "repo-b")
for d in (BG, MB, QD, HOLD, REPO_A, REPO_B, os.path.join(MD, "logs"), os.path.join(ST, "followup"),
          os.path.join(TMP, "worker"), os.path.join(TMP, "rt"), os.path.join(TMP, "projects"),
          os.path.join(TMP, "dcq"), os.path.join(TMP, "home"), os.path.join(TMP, "brief")):
    os.makedirs(d, exist_ok=True)


def fail(msg):
    sys.exit("FAIL: " + msg)


def stub(name, body):
    p = os.path.join(TMP, name)
    with open(p, "w", encoding="utf-8") as f:
        f.write("#!/bin/sh\n" + body)
    os.chmod(p, 0o755)
    return p


NOOP = stub("noop", "exit 0\n")
TRIAGE = stub("triage", "echo mid\n")
# hermes stub：記 start／end；執行時卡住直到測試建立 HOLD_DIR/release-<標記>（確定性控制並行時序）
HERMES = stub("hermes", r'''tag=$(printf '%s' "$*" | grep -o 'JOB-[A-Z0-9]*' | head -1)
echo "start $tag" >> "$HERMES_LOG"
n=0
while [ ! -f "$HOLD_DIR/release-$tag" ] && [ "$n" -lt 400 ]; do sleep 0.1; n=$((n+1)); done
echo "end $tag" >> "$HERMES_LOG"
echo "result $tag"
''')
# dispatch-watch 信箱測試用：只記呼叫參數
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
        "DISPATCH_BG_HERMES_BIN": HERMES,
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
        "HERMES_LOG": HERMES_LOG,
        "HOLD_DIR": HOLD,
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


def log_lines():
    return read(HERMES_LOG).splitlines()


def wait_log(line, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        if line in log_lines():
            return
        time.sleep(0.1)
    fail(f"等不到 hermes 紀錄 {line!r}；目前：{log_lines()}")


def wait_rc(n, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        if len(glob.glob(os.path.join(BG, "r-*.result.rc"))) >= n:
            return
        time.sleep(0.1)
    fail(f"結果 rc 檔不足 {n} 個")


def release(tag):
    open(os.path.join(HOLD, "release-" + tag), "w").close()


def write_prompt(name, text):
    p = os.path.join(BG, f"{name}-{time.time_ns()}.md")
    with open(p, "w", encoding="utf-8") as f:
        f.write(text)
    return p


def dispatch(thread, text, env=None):
    p = write_prompt(thread, text)
    return run([DISPATCH_BG, thread, p], env or env_for())


def ledger():
    if not os.path.exists(TSV):
        return []
    with open(TSV, encoding="utf-8") as f:
        return [l.rstrip("\n").split("\t") for l in f if l.strip()]


def add_row(jid, prompt, status, thread, backend="hermes"):
    # 欄：id、tier、prompt、epoch、status、cwd、thread、backend（與 dispatch-bg 寫入順序一致）
    os.makedirs(os.path.dirname(TSV), exist_ok=True)
    with open(TSV, "a", encoding="utf-8") as f:
        f.write("\t".join([jid, "mid", prompt, str(int(time.time())), status, TMP, thread, backend]) + "\n")


def set_status(jid, status):
    rows = ledger()
    with open(TSV, "w", encoding="utf-8") as f:
        for r in rows:
            if r[0] == jid:
                r[4] = status
            f.write("\t".join(r) + "\n")


def finish_tag(tag):
    # 把 prompt 內含此標記的 pending 列改成 done（模擬 dispatch-watch 收尾）
    rows = ledger()
    for r in rows:
        if r[4] == "pending" and tag in read(r[2]):
            set_status(r[0], "done")


def add_map(chat, mid, thread, job):
    with open(MAP, "a", encoding="utf-8") as f:
        f.write(f"{chat}\t{mid}\t{thread}\t{job}\t{int(time.time())}\n")


def receipts(event=None):
    lines = [l.split("\t") for l in read(RCPT).splitlines() if l.strip()]
    return [l for l in lines if event is None or l[1] == event]


def watch(env=None):
    rc, out, err = run(["bash", DISPATCH_WATCH], env or env_for())
    if rc != 0:
        fail(f"dispatch-watch 非零：{err}")


# ---------------- N03：同 repo 寫入序列化 ----------------
WRITERS_A = {"JOB-A1", "JOB-A2"}
REPO_OF = {"JOB-A1": "A", "JOB-A2": "A", "JOB-B1": "B", "JOB-R1": "A", "JOB-N1": None}

# A1 寫 repo A，先起來並卡住
rc, out, err = dispatch("t-alpha1", f"repo={REPO_A}\nJOB-A1 寫檔\n")
if rc != 0 or "queued" in out:
    fail(f"A1 應直接起 worker：rc={rc} out={out} err={err}")
wait_log("start JOB-A1")

# A2 同 repo 寫入 → 排隊，ledger 不多列
rows0 = len(ledger())
rc, out, err = dispatch("t-alpha2", f"repo={REPO_A}\nJOB-A2 寫檔\n")
if rc != 0 or "queued-" not in out:
    fail(f"A2 應排隊：rc={rc} out={out} err={err}")
if len(ledger()) != rows0:
    fail("A2 排隊時不該登錄 ledger")
if len(glob.glob(os.path.join(QD, "*"))) != 1:
    fail("A2 沒進 hermes-queue")

# 不同 repo（B1）、唯讀（R1，同 repo A）、沒宣告 repo（N1）都照常起
for thread, tag, body in (
    ("t-beta1", "JOB-B1", f"repo={REPO_B}\nJOB-B1 寫檔\n"),
    ("t-alpha3", "JOB-R1", f"repo={REPO_A}\nreadonly=1\nJOB-R1 只讀\n"),
    ("t-free1", "JOB-N1", "JOB-N1 沒宣告 repo\n"),
):
    rc, out, err = dispatch(thread, body)
    if rc != 0 or "queued" in out:
        fail(f"{tag} 不該被排隊：rc={rc} out={out} err={err}")
    wait_log("start " + tag)

# A1 收尾 → dispatch-watch 把 A2 派出（同 repo 的下一件）
release("JOB-A1")
wait_log("end JOB-A1")
wait_rc(1)
finish_tag("JOB-A1")
watch()
wait_log("start JOB-A2")

# 全部放行、等收尾
for tag in ("JOB-A2", "JOB-B1", "JOB-R1", "JOB-N1"):
    release(tag)
for tag in ("JOB-A2", "JOB-B1", "JOB-R1", "JOB-N1"):
    wait_log("end " + tag)

# 峰值：同一 repo 的寫入任務同時跑的最大數
running, peak_a, idx = set(), 0, 0
lines = log_lines()
for ln in lines:
    kind, tag = ln.split(" ", 1)
    if REPO_OF.get(tag) == "A" and tag in WRITERS_A:
        if kind == "start":
            running.add(tag)
            peak_a = max(peak_a, len(running))
        else:
            running.discard(tag)
if peak_a != 1:
    fail(f"同 repo 寫入峰值應為 1，實際 {peak_a}：{lines}")
if lines.index("start JOB-R1") > lines.index("end JOB-A1"):
    fail("唯讀 R1 應在 A1 還跑時就起（不被擋）")
if lines.index("start JOB-B1") > lines.index("end JOB-A1"):
    fail("不同 repo 的 B1 應與 A1 並行")
if lines.index("start JOB-N1") > lines.index("end JOB-A1"):
    fail("沒宣告 repo 的 N1 應照現行行為照起")
print("N03 ok: peak_same_repo=1 parallel_diff_repo readonly_not_blocked no_repo_unchanged")

# ---------------- N02：follow-up 直通 ----------------
P_FU1 = write_prompt("t-fu01", "原需求：查 A 服務\n")
add_row("bg-fu1", P_FU1, "done", "t-fu01")
add_map(555, 1000, "t-fu01", "bg-fu1")

# flag 關：完全不動任何檔
rc, out, err = run([FOLLOWUP, "555", "2001", "1000"], env_for(), stdin="補充一句")
if rc != 3:
    fail(f"flag 關應 exit 3，實際 {rc}")
if os.path.exists(os.path.join(MB, "t-fu01")) or os.path.exists(RCPT):
    fail("flag 關時不該建 mailbox 或收據")

FU_ON = env_for(MYTHOS_FOLLOWUP_DIRECT="1")
# 首次：入列
rc, out, err = run([FOLLOWUP, "555", "2001", "1000"], FU_ON, stdin="補充一句")
if rc != 0 or out.strip() != "queued t-fu01":
    fail(f"首次應入列：rc={rc} out={out} err={err}")
fu_file = os.path.join(MB, "t-fu01", "fu-555-2001.md")
if "補充一句" not in read(fu_file) or "bg-fu1" not in read(fu_file):
    fail("follow-up 檔內容不對")
if len(receipts("queued")) != 1:
    fail("首次應寫一筆 queued 收據")

# 同 chat+mid 重播：只入列一次
rc, out, err = run([FOLLOWUP, "555", "2001", "1000"], FU_ON, stdin="補充一句")
if rc != 0 or out.strip() != "dup t-fu01":
    fail(f"重播應回 dup：rc={rc} out={out} err={err}")
if len(receipts("queued")) != 1 or len(glob.glob(os.path.join(MB, "t-fu01", "fu-*.md"))) != 1:
    fail("重播不得再入列")

# 來源偽造（rmid 不在對照表）→ Router
rc, out, err = run([FOLLOWUP, "555", "2003", "9999"], FU_ON, stdin="假的")
if rc != 4:
    fail(f"未綁定應 exit 4，實際 {rc}")

# 歧義（同 chat+mid 對到兩個 thread）→ Router
add_row("bg-fu2", write_prompt("t-fu02", "另一件\n"), "done", "t-fu02")
add_map(555, 3000, "t-fu01", "bg-fu1")
add_map(555, 3000, "t-fu02", "bg-fu2")
rc, out, err = run([FOLLOWUP, "555", "2004", "3000"], FU_ON, stdin="補充")
if rc != 5:
    fail(f"歧義應 exit 5，實際 {rc}")

# 新話題（自定規則：以「新題」開頭）→ Router
rc, out, err = run([FOLLOWUP, "555", "2005", "1000"], FU_ON, stdin="新題：幫我查天氣")
if rc != 6:
    fail(f"新話題應 exit 6，實際 {rc}")
if any(r[3] in ("2003", "2004", "2005") for r in receipts("queued")):
    fail("被交 Router 的訊息不該有 queued 收據")
print("N02 ok: flag_off_untouched dedupe forged_to_router ambiguous_to_router new_topic_to_router")

# 取消後舊 generation 不消費：cancel 換 generation、清信箱；之後仍留著的舊 generation 項要進 .stale/
rc, out, err = run([DISPATCH_BG, "--cancel", "t-fu01"], env_for())
if rc != 0:
    fail(f"cancel 失敗：{err}")
stale_src = os.path.join(MB, "t-fu01", "fu-555-2002.md")
os.makedirs(os.path.dirname(stale_src), exist_ok=True)
with open(stale_src, "w", encoding="utf-8") as f:
    f.write("（回覆的是 bg-fu1 的結果）\n取消前送出的\n")
with open(RCPT, "a", encoding="utf-8") as f:
    f.write("1\tqueued\t555\t2002\tt-fu01\t0\tbg-fu1\t\n")  # gen 0：取消前入列
watch(env_for(DISPATCH_BG_BIN=BG_STUB))
if not os.path.exists(os.path.join(MB, "t-fu01", ".stale", "fu-555-2002.md")):
    fail("舊 generation 的 follow-up 應移到 .stale/")
if "t-fu01" in read(BG_CALLS):
    fail("舊 generation 的 follow-up 不得被派出")
if not any(r[3] == "2002" for r in receipts("stale")):
    fail("舊 generation 應寫 stale 收據")
print("GEN ok: cancelled_generation_not_consumed")

# ---------------- G08：interrupt 前情＋mailbox 留存 .consumed/ ----------------
P_IP0 = write_prompt("t-ip01", "ORIG-IP 原需求：寫週報\n")
os.makedirs(BG, exist_ok=True)
with open(os.path.join(BG, "ip1.result"), "w", encoding="utf-8") as f:
    f.write("PREV-RESULT-IP 上一輪已寫好的週報前段內容")
add_row("bg-ip1", P_IP0, "done", "t-ip01")
P_IP1 = write_prompt("t-ip01-new", "JOB-IP2 改成只寫三點\n")
release("JOB-IP2")
rc, out, err = run([DISPATCH_BG, "--interrupt", "t-ip01", P_IP1], env_for())
if rc != 0:
    fail(f"interrupt 失敗：{err}")
ipfs = glob.glob(os.path.join(BG, "t-ip01-interrupt-*.md"))
if len(ipfs) != 1:
    fail("interrupt 應產生一份新 prompt")
ip = read(ipfs[0])
for needle in ("ORIG-IP", "上一輪結果摘要", "PREV-RESULT-IP", "JOB-IP2"):
    if needle not in ip:
        fail(f"interrupt 新 prompt 缺 {needle!r}：{ip}")
wait_log("end JOB-IP2")
print("G08a ok: interrupt_prompt_carries_prior_summary")

# 信箱：同 thread 無在跑 → 派出後批次移到 .consumed/，不直接刪
add_row("bg-mb1", write_prompt("t-mb01", "原需求 MB\n"), "done", "t-mb01")
os.makedirs(os.path.join(MB, "t-mb01"), exist_ok=True)
with open(os.path.join(MB, "t-mb01", "msg-1.md"), "w", encoding="utf-8") as f:
    f.write("補充 MB-MSG\n")
watch(env_for(DISPATCH_BG_BIN=BG_STUB))
if "--thread t-mb01" not in read(BG_CALLS):
    fail("信箱批次應派出")
kept = glob.glob(os.path.join(MB, "t-mb01", ".consumed", "*", "msg-1.md"))
if len(kept) != 1 or "MB-MSG" not in read(kept[0]):
    fail("消費後的訊息應保留在 .consumed/")
if os.path.exists(os.path.join(MB, "t-mb01", ".batch")):
    fail("批次目錄應已移走，不留 .batch")
print("G08b ok: mailbox_consumed_kept")

# 收尾：放行殘留 hermes stub，讓背景子行程結束
for tag in ("JOB-IP2",):
    release(tag)
print("THREAD_ROUTING_OK")
