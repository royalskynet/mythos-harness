#!/usr/bin/env python3
"""P3 可展開脈絡驗收：bin/recall --id／--expand、mythos_recall 的 id 路。
全在 mktemp 沙箱：MYTHOS_DIR 指到暫存目錄；不讀真 ~/.hermes、不打 TG、不呼叫真模型。
用法：python3 tests/test-recall-links.py → 全過印 RECALL_LINKS_OK。"""
import atexit
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RECALL = os.path.join(ROOT, "bin", "recall")
TOOLS = os.path.join(ROOT, "profiles", "mythos", "plugins", "mythos-tools")

TMP = tempfile.mkdtemp(prefix="recall-links.")
atexit.register(shutil.rmtree, TMP, True)
MD = os.path.join(TMP, "mythos")
ST = os.path.join(MD, "state")
BG = os.path.join(ST, "bg")
TGF = os.path.join(ST, "tg-full")
for d in (BG, TGF, os.path.join(MD, "bin")):
    os.makedirs(d)

FILLER_LIMIT = "關鍵限制：只准用 Python 標準庫，不准加依賴"
TG_LIMIT = "全文關鍵：TG-LIMIT-42"


def fail(msg):
    sys.exit("FAIL: " + msg)


def write(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)


# ---- 假資料：兩日、兩 thread 同標題、長結果（限制在 4000 字之後）、循環、缺物件、路徑毒列 ----
P = lambda name: os.path.join(BG, name)
CWD = os.path.join(TMP, "cwd")
write(P("p-a1.md"), "# 備份\n需求：每天 03:00 跑 A 機器備份\n驗收：rc=0\n")
write(P("p-a2.md"), "# 備份（改版）\n需求：A 改成每天 04:00\n驗收：rc=0 且備份檔存在\n")
write(P("p-b1.md"), "# 備份\n需求：B 機器備份，每天 05:00\n驗收：B 的 rc=0\n")
write(P("p-c1.md"), "需求：C 待辦\n")
write(P("p-d1.md"), "需求：循環測試 D1\n")
write(P("p-d2.md"), "需求：循環測試 D2\n")
ledger = [
    ("bg-0000a001", "2026-11-07 10:00:00", P("p-a1.md"), "mid", "done", CWD, "t-aaaa", "hermes"),
    ("bg-0000a002", "2026-11-08 10:00:00", P("p-a2.md"), "mid", "done", CWD, "t-aaaa", "hermes"),
    ("bg-0000b001", "2026-11-08 09:00:00", P("p-b1.md"), "mid", "done", CWD, "t-bbbb", "hermes"),
    ("bg-0000c001", "2026-11-08 11:00:00", P("p-c1.md"), "mid", "pending", CWD, "t-cccc", "hermes"),
    ("bg-0000m001", "2026-11-08 12:00:00", P("gone.md"), "mid", "done", CWD, "t-mmmm", "hermes"),
    ("bg-0000d001", "2026-11-08 13:00:00", P("p-d1.md"), "mid", "done", CWD, "t-cyc", "hermes"),
    ("bg-0000d002", "2026-11-08 13:30:00", P("p-d2.md"), "mid", "pending", CWD, "t-cyc", "hermes"),
    # 毒列：id 含 ../，若沒有 ID 檢查，會讀到 TMP/leak.result（樹外）
    ("bg-../../../leak", "2026-11-08 14:00:00", P("p-c1.md"), "mid", "done", CWD, "t-leak", "hermes"),
]
write(os.path.join(ST, "dispatch-jobs.tsv"), "".join("\t".join(r) + "\n" for r in ledger))
write(os.path.join(ST, "tg-msg-thread.tsv"), "".join("\t".join(r) + "\n" for r in [
    ("42", "101", "t-aaaa", "bg-0000a001", "1"),
    ("42", "102", "t-bbbb", "bg-0000b001", "2"),
    ("42", "103", "t-aaaa", "bg-0000a002", "3"),
    ("42", "104", "t-aaaa", "bg-0000a002", "4"),  # 短回覆：沒有 tg-full
    ("42", "900", "t-cyc", "bg-0000d001", "5"),
    ("42", "901", "t-cyc", "bg-0000d002", "6"),
    ("42", "902", "t-cyc", "bg-0000d001", "7"),
]))
A2_RESULT = "摘要：A 新版結果，驗收 rc=0 通過\n---細節---\n" + "填" * 4200 + "\n" + FILLER_LIMIT + "\n"
write(P("0000a001.result"), "摘要：A 舊版結果\n---細節---\n細節 A1\n")
write(P("0000a002.result"), A2_RESULT)
write(P("0000b001.result"), "摘要：B 結果\n---細節---\nB 細節\n")
write(P("0000d001.result"), "摘要：D 結果\n")
write(os.path.join(TMP, "leak.result"), "LEAK-SECRET\n")
write(os.path.join(TGF, "103.txt"), "全文 A 新版\n" + "填" * 4200 + "\n" + TG_LIMIT + "\n")
assert A2_RESULT.index(FILLER_LIMIT) >= 4000, "夾具：限制要在 4000 字之後"

ENV = dict(os.environ, MYTHOS_DIR=MD, RECALL_MEM_URL="http://127.0.0.1:9",
           MYTHOS_STATE_DB=os.path.join(TMP, "state.db"))
for k in ("MYTHOS_REQUEST_ID", "REVIEW_JUDGE_TASK_CHARS", "REVIEW_JUDGE_LLM"):
    ENV.pop(k, None)


def recall(*args, timeout=20):
    return subprocess.run([RECALL, *args], env=ENV, capture_output=True, text=True, timeout=timeout)


def jrecall(*args):
    r = recall(*args)
    if r.returncode != 0:
        fail(f"bin/recall {args} rc={r.returncode}: {r.stderr}")
    return json.loads(r.stdout)


def read_all(ident, part="result", revision=None):
    """照 continuation 一段段讀完，回 (全文, total, 段數)。"""
    off, text, pages, total = 0, "", 0, None
    while off is not None:
        pages += 1
        if pages > 20:
            fail(f"{ident} 續讀超過 20 段仍沒讀完")
        args = ["--expand", ident, "--offset", str(off), "--part", part]
        if revision is not None:
            args += ["--revision", str(revision)]
        r = recall(*args)
        if r.returncode != 0:
            fail(f"expand {ident} off={off} rc={r.returncode}: {r.stderr}")
        j = json.loads(r.stdout)
        text += j["text"]
        total = j["total"]
        off = j["continuation"]["offset"] if j["continuation"] else None
    return text, total, pages


# 1. 跨兩日、同標題兩 thread 不混、預設最新一版
j = jrecall("--id", "t-aaaa")
assert j["kind"] == "thread" and j["revision"] == 2 and j["revisions"] == 2 and j["job"] == "bg-0000a002", j
assert set(["id", "kind", "summary", "related_ids", "revision", "continuation"]) <= set(j), j
assert "A 新版結果" in j["summary"] and "B 結果" not in j["summary"] and "關鍵限制" not in j["summary"], j["summary"]
assert "bg-0000a001" in j["related_ids"] and "101" in j["related_ids"] and "103" in j["related_ids"], j["related_ids"]
assert not {"bg-0000b001", "t-bbbb", "102"} & set(j["related_ids"]), f"不同 thread 混進來：{j['related_ids']}"
assert j["continuation"] == {"expand": "bg-0000a002", "part": "result", "offset": 0}, j["continuation"]
print("ok 1 thread 預設最新、同標題不混")

# 2. 舊 revision 可指定；超出範圍明確報錯
j = jrecall("--id", "t-aaaa", "--revision", "1")
assert j["revision"] == 1 and j["job"] == "bg-0000a001" and "A 舊版結果" in j["summary"] and "A 新版" not in j["summary"], j
r = recall("--id", "t-aaaa", "--revision", "9")
assert r.returncode == 1 and "沒有第 9 版" in r.stderr, (r.returncode, r.stderr)
print("ok 2 舊 revision")

# 3. 另一 thread 只看到自己的
j = jrecall("--id", "t-bbbb")
assert j["job"] == "bg-0000b001" and "B 結果" in j["summary"], j
assert "bg-0000a002" not in j["related_ids"] and "103" not in j["related_ids"], j["related_ids"]
print("ok 3 thread 互不混")

# 4. 任務 ID 跨兩日：自己那版、關聯到 thread
j = jrecall("--id", "bg-0000a001")
assert j["kind"] == "job" and j["thread"] == "t-aaaa" and j["revision"] == 1, j
assert "t-aaaa" in j["related_ids"] and "bg-0000a002" in j["related_ids"], j["related_ids"]
print("ok 4 job id 跨日")

# 5. 訊息號：對到 job；沒有全文檔的短回覆 continuation 為 null
j = jrecall("--id", "103")
assert j["kind"] == "message" and j["job"] == "bg-0000a002" and j["thread"] == "t-aaaa", j
assert j["continuation"] == {"expand": "103", "part": "result", "offset": 0}, j["continuation"]
j = jrecall("--id", "104")
assert j["continuation"] is None and j["job"] == "bg-0000a002", j
print("ok 5 訊息號")

# 6. 循環引用：t→j→m→t 要有限結束、無重複
for ident in ("t-cyc", "900", "bg-0000d001"):
    r = recall("--id", ident, timeout=10)  # 逾時會拋 TimeoutExpired → 測試失敗
    assert r.returncode == 0, (ident, r.stderr)
    rel = json.loads(r.stdout)["related_ids"]
    assert len(rel) == len(set(rel)) and len(rel) <= 50, (ident, rel)
    assert "bg-0000d002" in rel and ("900" in rel or ident == "900"), (ident, rel)  # 起點本身不列進關聯
print("ok 6 循環引用有限")

# 7. 缺物件：明確報缺、不崩潰（沒有 Traceback）
j = jrecall("--id", "bg-0000c001")
assert "尚無結果" in j["summary"] and j["status"] == "pending", j
j = jrecall("--id", "bg-0000m001")
assert "需求檔不存在" in j["summary"], j
r = recall("--id", "999999")
assert r.returncode == 1 and "查不到" in r.stderr and "Traceback" not in r.stderr, (r.returncode, r.stderr)
r = recall("--expand", "104")
assert r.returncode == 1 and "沒有可展開" in r.stderr and "Traceback" not in r.stderr, (r.returncode, r.stderr)
r = recall("--expand", "bg-0000c001")
assert r.returncode == 1 and "沒有可展開" in r.stderr, (r.returncode, r.stderr)
print("ok 7 缺物件明確報缺")

# 8. 長文外存：4000 字之後的限制要靠 expand 續讀才讀到，且讀完＝檔案全文
first = recall("--expand", "bg-0000a002")
assert first.returncode == 0 and FILLER_LIMIT not in json.loads(first.stdout)["text"], "第一段不該已經有限制"
text, total, pages = read_all("bg-0000a002")
assert FILLER_LIMIT in text and pages >= 3, (pages, FILLER_LIMIT in text)
assert text == A2_RESULT and total == len(A2_RESULT), "續讀拼起來要等於全文"
text, total, pages = read_all("103")
assert TG_LIMIT in text and pages >= 3 and text.startswith("全文 A 新版"), (pages, text[:20])
print(f"ok 8 expand 續讀（result {pages} 段讀到限制）")

# 9. 路徑拒絕：ID 含 / 或 .. 、毒列 ID 一律非零、不讀樹外檔
for args in (("--id", "../../etc/passwd"), ("--expand", "bg-0000a002/../../x"), ("--expand", "/etc/passwd"),
             ("--expand", "../leak"), ("--id", "bg-../../../leak"), ("--expand", "bg-../../../leak")):
    r = recall(*args)
    assert r.returncode == 2, (args, r.returncode, r.stderr)
    assert "不合規" in r.stderr and "LEAK-SECRET" not in r.stdout and r.stdout == "", (args, r.stdout, r.stderr)
print("ok 9 路徑拒絕")

# 10. 用法錯誤
for args in (("--id",), ("--expand", "t-aaaa", "--offset", "abc"), ("--id", "t-aaaa", "--offset", "5"),
             ("--expand", "bg-0000a002", "--part", "bogus")):
    assert recall(*args).returncode == 2, args
print("ok 10 用法")

# 11. mythos_recall：帶 id 走新查詢、預算不變（一回合一次）
os.environ["MYTHOS_DIR"] = MD
os.environ["MYTHOS_STATE_DB"] = os.path.join(TMP, "state.db")
shutil.copy(RECALL, os.path.join(MD, "bin", "recall"))  # 工具呼叫 MYTHOS/bin/recall：沙箱裡放同一份（不是假版）
os.chmod(os.path.join(MD, "bin", "recall"), 0o755)
sys.path.insert(0, TOOLS)
import __init__ as tools  # noqa: E402

out = tools.mythos_recall({"id": "t-aaaa"}, session_id="s-links-1")
assert '"revision": 2' in out and '"job": "bg-0000a002"' in out, out
again = tools.mythos_recall({"id": "bg-0000a002"}, session_id="s-links-1")
assert again.startswith("這回合已查過一次"), again  # 同回合第二次擋住，不分 keywords／id
out = tools.mythos_recall({"thread": "t-aaaa", "offset": 4000}, session_id="s-links-2")
assert '"offset": 4000' in out and FILLER_LIMIT in out, out[:300]
assert "查不到" in tools.mythos_recall({"id": "nope-zz"}, session_id="s-links-3")
assert "不合規" in tools.mythos_recall({"id": "../x"}, session_id="s-links-4")
assert tools.mythos_recall({}, session_id="s-links-5") == "缺 keywords"
print("ok 11 mythos_recall id 路")

print("RECALL_LINKS_OK")
