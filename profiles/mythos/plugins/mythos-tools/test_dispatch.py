#!/usr/bin/env python3
"""mythos-tools 自檢：python3 test_dispatch.py（純 python3、假 dispatch-bg 記 env）。"""
import os
import stat
import sys
import tempfile

for k in ("MYTHOS_BG_WORKER", "MYTHOS_DISPATCH_DRYRUN"):
    os.environ.pop(k, None)  # 外層環境不能蓋掉預設值檢查

TMP = tempfile.mkdtemp()
os.makedirs(os.path.join(TMP, "bin"))
CALL_ENV = os.path.join(TMP, "call.env")
BG = os.path.join(TMP, "bin", "dispatch-bg")
with open(BG, "w") as f:
    f.write('#!/bin/sh\nenv > "$CALL_ENV"\nprintf "%s\\n" "$@" > "$CALL_ARGV"\necho bg-fake\n')
os.chmod(BG, os.stat(BG).st_mode | stat.S_IXUSR)
CALL_ARGV = os.path.join(TMP, "call.argv")
os.environ.update(MYTHOS_DIR=TMP, CALL_ENV=CALL_ENV, CALL_ARGV=CALL_ARGV)
os.environ.pop("MYTHOS_DISPATCH_DRYRUN", None)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import __init__ as tools  # noqa: E402


def call(**extra):
    for k in ("MYTHOS_BG_WORKER", "MYTHOS_DISPATCH_DRYRUN"):
        os.environ.pop(k, None)
    os.environ.update(extra)
    try:
        assert tools.mythos_dispatch({"request": "做這個"}).startswith("已派 ")
        env = dict(l.split("=", 1) for l in open(CALL_ENV).read().splitlines() if "=" in l and not l.startswith("_="))
    finally:
        for k in ("MYTHOS_BG_WORKER", "MYTHOS_DISPATCH_DRYRUN"):
            os.environ.pop(k, None)
    os.unlink(CALL_ENV)
    return env


assert call()["DISPATCH_BG_WORKER"] == "hermes", "預設應帶 hermes"
assert call(MYTHOS_BG_WORKER="claude")["DISPATCH_BG_WORKER"] == "claude", "MYTHOS_BG_WORKER 應透傳"
os.environ.update(MYTHOS_DISPATCH_DRYRUN="1", MYTHOS_BG_WORKER="claude")
assert tools.mythos_dispatch({"request": "做這個"}).startswith("已派 ")
os.environ.pop("MYTHOS_DISPATCH_DRYRUN")
os.environ.pop("MYTHOS_BG_WORKER")
assert not os.path.exists(CALL_ENV), "DRYRUN 不應呼叫 dispatch-bg"

# 11-08b #2：mode=cancel／interrupt（假 dispatch-bg 記 argv）
def argv_of(**a):
    for f in (CALL_ARGV, CALL_ENV):
        if os.path.exists(f):
            os.unlink(f)
    out = tools.mythos_dispatch(a)
    return out, (open(CALL_ARGV).read().split("\n")[:-1] if os.path.exists(CALL_ARGV) else None)


out, argv = argv_of(mode="cancel", thread="t-zzzz")
assert argv == ["--cancel", "t-zzzz"], f"cancel 應呼叫 dispatch-bg --cancel t-zzzz：{argv}"
assert out.startswith("已停"), out
out, argv = argv_of(mode="cancel")
assert argv is None and "thread" in out, f"cancel 沒 thread 要拒絕且不呼叫 dispatch-bg：{out} {argv}"
out, argv = argv_of(mode="interrupt", request="改成 NEWINSTR")
assert argv is None and "thread" in out, f"interrupt 沒 thread 要拒絕且不呼叫 dispatch-bg：{out} {argv}"
out, argv = argv_of(mode="interrupt", thread="t-zzzz", request="改成 NEWINSTR")
assert argv[:2] == ["--interrupt", "t-zzzz"] and len(argv) == 3, f"interrupt argv：{argv}"
assert "NEWINSTR" in open(argv[2]).read(), "interrupt 的 prompt 檔要含新指示"
assert out.startswith("已派 "), out
out, argv = argv_of(mode="bogus", thread="t-zzzz", request="x")
assert argv is None, "未知 mode 不應呼叫 dispatch-bg"
out, argv = argv_of(request="一般追加")
assert argv is not None and "--cancel" not in argv and "--interrupt" not in argv, f"預設 queue 不應帶 cancel／interrupt：{argv}"

assert tools.mythos_full_text({}) == "沒有可取的全文", "沒有全文檔時應明說"
# mythos_full_text：讀 tg-full 最新一個檔、以 #full 開頭交假 tg-send（不送真 TG）
TG_IN = os.path.join(TMP, "tg.in")
with open(os.path.join(TMP, "bin", "tg-send"), "w") as f:
    f.write('#!/bin/sh\ncat > "$TG_IN"\necho 777\n')
os.chmod(os.path.join(TMP, "bin", "tg-send"), 0o755)
os.environ["TG_IN"] = TG_IN
os.makedirs(os.path.join(TMP, "state", "tg-full"))
# 檔名是 epoch 時間戳：故意讓舊檔名數字較大，驗的是 mtime 不是檔名排序
for name, body, t in (("999.txt", "舊", 1_000_000_000), ("1.txt", "最新全文", 2_000_000_000)):
    with open(os.path.join(TMP, "state", "tg-full", name), "w") as f:
        f.write(body)
    os.utime(os.path.join(TMP, "state", "tg-full", name), (t, t))
assert tools.mythos_full_text({}) == "已送全文"
assert open(TG_IN).read() == "#full\n最新全文", repr(open(TG_IN).read())
os.unlink(TG_IN)
with open(os.path.join(TMP, "bin", "tg-send"), "w") as f:
    f.write("#!/bin/sh\nexit 1\n")
assert "失敗" in tools.mythos_full_text({}), "tg-send 非 0 應回失敗"
print("DISPATCH_TOOL_OK")
