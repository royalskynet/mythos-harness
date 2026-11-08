#!/usr/bin/env python3
"""adhd-outlet 自檢：python3 test_outlet.py（純 python3、假 node、不送 TG）。"""
import os
import sys
import tempfile
import time

T = tempfile.mkdtemp()
os.environ["MYTHOS_DIR"] = T
os.environ.pop("MYTHOS_ADHD_ALL", None)
FAKE = os.path.join(T, "fake-lint.mjs")
os.environ["MYTHOS_ADHD_BIN"] = FAKE
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import __init__ as outlet  # noqa: E402

assert outlet.FULL_DIR.startswith(T) and outlet.LOG.startswith(T), "env 沒生效"
FULLS = lambda: sorted(os.listdir(outlet.FULL_DIR)) if os.path.isdir(outlet.FULL_DIR) else []


def fake(body):
    with open(FAKE, "w") as f:
        f.write(body)


LONG = "結論\n1. 甲\n2. 乙\n" + "細節說明。" * 200


def main():
    # 1) 長文 → 截斷版、tg-full 多一個檔（內容是原文）
    fake('let b="";process.stdin.on("data",c=>b+=c).on("end",()=>process.stdout.write(b.slice(0,10)+"\\n回「詳細」看全文\\n"))')
    out = outlet._on_transform_llm_output(response_text=LONG, platform="telegram")
    assert out is not None and out != LONG and "詳細" in out, out
    files = FULLS()
    assert len(files) == 1, files
    assert open(os.path.join(outlet.FULL_DIR, files[0])).read() == LONG
    # MYTHOS_ADHD_ALL=1 時非 telegram 也處理
    os.environ["MYTHOS_ADHD_ALL"] = "1"
    n = len(FULLS())
    assert outlet._on_transform_llm_output(response_text=LONG, platform="cli") is not None
    assert len(FULLS()) == n + 1
    os.environ.pop("MYTHOS_ADHD_ALL")

    # 2) 短文 → None、不多檔案
    fake('let b="";process.stdin.on("data",c=>b+=c).on("end",()=>process.stdout.write(b))')
    n = len(FULLS())
    assert outlet._on_transform_llm_output(response_text="收到", platform="telegram") is None
    assert len(FULLS()) == n

    # 3) 非 telegram 且沒設 env → None（連 node 都不跑）
    fake('process.exit(9)')
    assert outlet._on_transform_llm_output(response_text=LONG, platform="cli") is None
    assert outlet._on_transform_llm_output(response_text=LONG, platform="") is None
    assert len(FULLS()) == n

    RETRY = "剛剛那句我沒接好，你再說一次？"
    # 4) node 逾時（5 秒）→ 固定句（不把原文放出去），log 多一行
    fake('setTimeout(()=>{},20000)')
    t0 = time.time()
    assert outlet._on_transform_llm_output(response_text=LONG, platform="telegram") == RETRY
    dt = time.time() - t0
    assert dt < 8, f"逾時沒在 5 秒收掉：{dt:.1f}s"
    log = open(outlet.LOG).read().splitlines()
    assert log and "TimeoutExpired" in log[-1], log
    assert len(FULLS()) == n

    # 5) node 失敗（非 0）→ 固定句，log 記結束碼
    fake('process.exit(3)')
    assert outlet._on_transform_llm_output(response_text=LONG, platform="telegram") == RETRY
    assert "exit-3" in open(outlet.LOG).read()
    # 6) node 輸出空白 → 固定句（不送空白）
    fake('process.exit(0)')
    assert outlet._on_transform_llm_output(response_text=LONG, platform="telegram") == RETRY
    assert "lint-empty-output" in open(outlet.LOG).read()

    print("ADHD_OUTLET_OK")


main()
