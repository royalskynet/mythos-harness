#!/usr/bin/env python3
"""adhd-outlet 差距 #1 自檢：python3 test_reasoning_only.py（假 MYTHOS_DIR、假 node，不送 TG、不派工）。
reasoning-only → 固定句；正常 content 不變；不同 turn_id 不影響本 turn；轉換不呼叫 dispatch-bg。"""
import os
import sys
import tempfile

T = tempfile.mkdtemp()

os.environ.update(MYTHOS_DIR=T, MYTHOS_DISPATCH_DRYRUN="1")
os.environ.pop("MYTHOS_ADHD_ALL", None)
FAKE = os.path.join(T, "fake-lint.mjs")
with open(FAKE, "w") as f:
    f.write('let b="";process.stdin.on("data",c=>b+=c).on("end",()=>process.stdout.write(b))')
os.environ["MYTHOS_ADHD_BIN"] = FAKE
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import __init__ as outlet  # noqa: E402

assert outlet.LOG.startswith(T), "env 沒生效"
RETRY = "剛剛那句我沒接好，你再說一次？"

def attempt(turn, content, tools=0):
    outlet._on_post_api_request(
        response={"finish_reason": "stop", "assistant_message": {"role": "assistant", "content": content,
                                                                  "tool_calls": [{"id": "x"}] * tools}},
        session_id="s1", turn_id=turn)

def transform(turn, text=""):
    return outlet._on_transform_llm_output(response_text=text, platform="telegram", session_id="s1", turn_id=turn)

def main():
    assert outlet.RETRY_MSG == RETRY
    # 1) reasoning-only（content 空、無 tool_calls）→ 固定句，且不因長度／狀態庫去派工
    attempt("t1", None)
    assert transform("t1") == RETRY
    attempt("t1b", "   ", tools=0)
    assert transform("t1b") == RETRY
    # 2) 正常 content → 照舊（假 node 原樣輸出＝None，不被改寫）
    attempt("t2", "早安，Ether。")
    assert transform("t2", "早安，Ether。") is None
    # 3) 不同 turn_id 的 reasoning-only 紀錄不影響本 turn
    attempt("t3", None)
    assert transform("t4", "早安，Ether。") is None
    assert transform("t3") == RETRY  # 本 turn 才吃到
    # 4) 同 turn 先空後有 content：以最後一次為準
    attempt("t5", None)
    attempt("t5", "好。")
    assert transform("t5", "好。") is None
    # 5) 有 tool_calls 的空 content（繼續跑工具）不算 reasoning-only
    attempt("t6", None, tools=2)
    assert transform("t6", "工具結果。") is None
    # 6) 沒紀錄 → 照舊流程（不誤攔）
    assert transform("nope", "早安。") is None
    # 7) 字典有上限
    for i in range(outlet.ATTEMPT_MAX + 50):
        attempt(f"bulk{i}", None)
    assert len(outlet._ATTEMPTS) <= outlet.ATTEMPT_MAX, len(outlet._ATTEMPTS)
    # 8) 沒有 dispatch-bg 路徑：轉換與掛鉤都不碰 tools／派工
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "__init__.py"), encoding="utf-8").read()
    assert "_guard_dispatch" not in src and "mythos_dispatch" not in src and "dispatch-bg" not in src

    assert not os.path.exists(os.path.join(T, "state", "router-dispatch.log")), "不該有派工記帳"
    assert "reasoning-only-blocked" in open(outlet.LOG, encoding="utf-8").read()
    print("REASONING_ONLY_OK")

main()
