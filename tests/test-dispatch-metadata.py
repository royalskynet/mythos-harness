#!/usr/bin/env python3
"""P6 ④ 驗收：repo／readonly 搬出正文，改放 <prompt>.meta.json。
- 正文中段的 repo=／readonly=1 一律當正文，不改變排程（bin/lib-ledger.sh 只讀 meta；沒 meta 才讀開頭 5 行）。
- 同 repo 寫入仍排隊；唯讀不擋。
- 追問（同 thread）沒宣告 repo 時繼承原 meta。
- mythos_dispatch（plugin）把 repo／readonly 寫進 meta、正文只有使用者原話。
全在 mktemp 沙箱：hermes／TG／claude 都是 stub；不連網、不碰 ~/.hermes。
用法：python3 tests/test-dispatch-metadata.py → 全過印 METADATA_OK。"""
import atexit
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISPATCH_BG = os.path.join(ROOT, "bin", "dispatch-bg")
PLUGIN_DIR = os.path.join(ROOT, "profiles", "mythos", "plugins", "mythos-tools")

TMP = tempfile.mkdtemp(prefix="dispatch-meta.")
atexit.register(shutil.rmtree, TMP, True)
MD = os.path.join(TMP, "mythos")
ST = os.path.join(MD, "state")
BG = os.path.join(ST, "bg")
TSV = os.path.join(ST, "dispatch-jobs.tsv")
MAP = os.path.join(ST, "tg-msg-thread.tsv")
HERMES_LOG = os.path.join(TMP, "hermes.log")
HOLD = os.path.join(TMP, "hold")
REPO_A = os.path.join(TMP, "repo-a")
REPO_B = os.path.join(TMP, "repo-b")
for d in (BG, HOLD, REPO_A, REPO_B, os.path.join(MD, "logs"), os.path.join(ST, "followup"),
          os.path.join(TMP, "worker"), os.path.join(TMP, "rt"), os.path.join(TMP, "projects"),
          os.path.join(TMP, "dcq"), os.path.join(TMP, "home"), os.path.join(TMP, "brief"),
          os.path.join(TMP, "bin")):
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
# hermes stub：記 start／end；執行時卡在 HOLD 直到測試放行（控制占用中的寫入任務）
HERMES = stub("hermes", r'''tag=$(printf '%s' "$*" | grep -o 'JOB-[A-Z0-9]*' | head -1)
echo "start $tag" >> "$HERMES_LOG"
n=0
while [ ! -f "$HOLD_DIR/release-$tag" ] && [ "$n" -lt 400 ]; do sleep 0.1; n=$((n+1)); done
echo "end $tag" >> "$HERMES_LOG"
echo "result $tag"
''')


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


def release(tag):
    open(os.path.join(HOLD, "release-" + tag), "w").close()


def write_prompt(name, text, repo=None, readonly=None):
    """repo=None 不寫 meta（模擬沒宣告）；否則寫 meta（repo 空字串＝明確沒宣告 repo）。"""
    p = os.path.join(BG, f"{name}-{time.time_ns()}.md")
    with open(p, "w", encoding="utf-8") as f:
        f.write(text)
    if repo is not None:
        with open(p + ".meta.json", "w", encoding="utf-8") as f:
            json.dump({"v": 1, "repo": repo, "readonly": bool(readonly)}, f)
    return p


def add_row(jid, prompt, status, thread, backend="hermes"):
    os.makedirs(os.path.dirname(TSV), exist_ok=True)
    with open(TSV, "a", encoding="utf-8") as f:
        f.write("\t".join([jid, "mid", prompt, str(int(time.time())), status, TMP, thread, backend]) + "\n")


def dispatch(thread, prompt):
    """回 (queued?, rc, out, err)。排隊時 stdout 為 queued-<檔名>；派出則否。"""
    rc, out, err = run([DISPATCH_BG, thread, prompt], env_for())
    return out.startswith("queued-"), rc, out, err


def expect_started(thread, prompt, tag, why):
    queued, rc, out, err = dispatch(thread, prompt)
    if rc != 0:
        fail(f"{why}：dispatch 失敗 rc={rc} err={err}")
    if queued:
        fail(f"{why}：應直接派出，卻排隊了：{err}")
    wait_log(f"start {tag}")


def expect_queued(thread, prompt, why):
    queued, rc, out, err = dispatch(thread, prompt)
    if rc != 0:
        fail(f"{why}：dispatch 失敗 rc={rc} err={err}")
    if not queued:
        fail(f"{why}：應排隊，卻直接派出了：{out}")


# ---- 占用中的寫入任務：repo A，meta 宣告、正文不含標頭 ----
P_A = write_prompt("t-ma01", "JOB-MA1 寫入 A\n", repo=REPO_A, readonly=False)
expect_started("t-ma01", P_A, "JOB-MA1", "基準：A 的寫入任務應派出")
if "repo=" in read(P_A):
    fail("正文不該含 repo= 標頭")

# M1：正文中段插入別的 repo=／readonly=1，不改變排程（meta 說沒宣告 repo，就不排隊）
mid = "JOB-MB1 補充\n" + "一般內容\n" * 8 + f"repo={REPO_A}\nreadonly=1\n"
P_B = write_prompt("t-mb01", mid, repo="", readonly=False)
expect_started("t-mb01", P_B, "JOB-MB1", "M1 正文中段 repo=/readonly=1 不得改變排程")

# M2：meta 宣告寫入 repo A、正文中段插入 readonly=1 → 仍是寫入，同 repo 要排隊
mid2 = "JOB-MC1 寫入\n" + "一般內容\n" * 8 + "readonly=1\n"
P_C = write_prompt("t-mc01", mid2, repo=REPO_A, readonly=False)
expect_queued("t-mc01", P_C, "M2 正文 readonly=1 不得讓同 repo 寫入變唯讀")

# M3：meta 宣告唯讀 → 不擋，即使 A 在寫
P_D = write_prompt("t-md01", "JOB-MD1 唯讀查\n", repo=REPO_A, readonly=True)
expect_started("t-md01", P_D, "JOB-MD1", "M3 唯讀不擋")

# M4a：舊檔（無 meta）開頭 5 行的 repo= 仍生效（相容）
P_E = write_prompt("t-me01", f"repo={REPO_A}\nJOB-ME1 舊格式\n")
expect_queued("t-me01", P_E, "M4a 舊檔開頭標頭仍排隊")

# M4b：舊檔第 7 行才出現 repo= → 當正文，不排隊
P_F = write_prompt("t-mf01", "一\n二\n三\n四\n五\n六\n" + f"repo={REPO_A}\nJOB-MF1 舊格式中段\n")
expect_started("t-mf01", P_F, "JOB-MF1", "M4b 舊檔中段 repo= 不得生效")

# M5：追問繼承：同 thread 上一張 done 的 job 宣告了 repo A，追問沒宣告 → 繼承 → 排隊
P_G0 = write_prompt("t-mi01", "原需求 MI\n", repo=REPO_A, readonly=False)
add_row("bg-mi0", P_G0, "done", "t-mi01")
P_G1 = write_prompt("t-mi01", "JOB-MI1 追問沒宣告 repo\n")  # 沒 meta
expect_queued("t-mi01", P_G1, "M5 追問應繼承原 repo 而排隊")
meta_g1 = json.load(open(P_G1 + ".meta.json"))
if meta_g1.get("repo") != REPO_A or meta_g1.get("readonly"):
    fail(f"M5 追問的 meta 應繼承原 repo（非唯讀）：{meta_g1}")

# M5b：追問自己宣告了別的 repo（B）→ 以新宣告為準，不排 A 的隊（B 沒人在寫）
P_G2 = write_prompt("t-mi01", "JOB-MI2 追問改 repo B\n", repo=REPO_B, readonly=False)
expect_started("t-mi01", P_G2, "JOB-MI2", "M5b 追問自己宣告的 repo 覆蓋繼承值")

# M5c：interrupt 的舊 job 無 meta 時，只繼承它的正式開頭標頭。
# 新指示的正文標頭沒有 meta，仍不得當成宣告覆蓋來源。
for suffix, readonly in (("W", False), ("R", True)):
    thread = "t-legacy-" + suffix
    legacy_repo = os.path.join(TMP, "legacy-repo-" + suffix)
    os.makedirs(legacy_repo)
    old = write_prompt(thread, f"repo={legacy_repo}\nreadonly={int(readonly)}\n舊需求\n")
    add_row("bg-legacy-" + suffix, old, "done", thread)
    tag = "JOB-LEGACY" + suffix
    new = write_prompt(thread, f"repo={REPO_A}\n{tag} 新指示\n")
    rc, out, err = run([DISPATCH_BG, "--interrupt", thread, new], env_for())
    if rc != 0:
        fail(f"M5c interrupt 失敗 rc={rc} err={err}")
    rows = [line.split("\t") for line in read(TSV).splitlines()]
    prompt = [row[2] for row in rows if row[6] == thread][-1]
    meta = json.loads(read(prompt + ".meta.json"))
    if meta.get("repo") != legacy_repo or meta.get("readonly") != readonly:
        fail(f"M5c interrupt 應繼承舊標頭 repo／readonly：{meta}")
    wait_log("start " + tag)
    release(tag)

# ---- plugin mythos_dispatch：meta 寫對、正文只有原話 ----
PL_MYTHOS = os.path.join(TMP, "plugin-mythos")
os.makedirs(os.path.join(PL_MYTHOS, "bin"), exist_ok=True)
os.makedirs(os.path.join(PL_MYTHOS, "state"), exist_ok=True)
ARGV_LOG = os.path.join(TMP, "pl-argv.log")
with open(os.path.join(PL_MYTHOS, "bin", "dispatch-bg"), "w", encoding="utf-8") as f:
    f.write('#!/bin/sh\nprintf "%s\\n" "$@" > "' + ARGV_LOG + '"\necho bg-fake\n')
os.chmod(os.path.join(PL_MYTHOS, "bin", "dispatch-bg"), 0o755)
os.environ.update(MYTHOS_DIR=PL_MYTHOS)
os.environ.pop("MYTHOS_DISPATCH_DRYRUN", None)
sys.path.insert(0, PLUGIN_DIR)
import __init__ as tools  # noqa: E402

req = "JOB-PL1 看一下\nrepo=/tmp/fake\nreadonly=1\n"
out = tools.mythos_dispatch({"request": req, "repo": REPO_A, "readonly": False})
if not out.startswith("已派 "):
    fail(f"plugin 派工失敗：{out}")
pl_prompt = [l for l in read(ARGV_LOG).splitlines() if l.endswith(".md")][0]
if read(pl_prompt) != req.strip() + "\n":
    fail(f"plugin 正文應只有原話，實際：{read(pl_prompt)!r}")
pm = json.load(open(pl_prompt + ".meta.json", encoding="utf-8"))
if pm != {"v": 1, "repo": REPO_A, "readonly": False}:
    fail(f"plugin meta 不對：{pm}")
out = tools.mythos_dispatch({"request": "唯讀", "repo": REPO_A, "readonly": True})
pl_prompt2 = [l for l in read(ARGV_LOG).splitlines() if l.endswith(".md")][0]
if json.load(open(pl_prompt2 + ".meta.json", encoding="utf-8")) != {"v": 1, "repo": REPO_A, "readonly": True}:
    fail("plugin 唯讀 meta 不對")
# 收尾：放行所有占用中的 hermes stub
for tag in ("JOB-MA1", "JOB-MB1", "JOB-MD1", "JOB-MF1", "JOB-MI2"):
    release(tag)
print("METADATA_OK")
