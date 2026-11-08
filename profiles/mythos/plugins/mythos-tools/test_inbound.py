#!/usr/bin/env python3
"""P6 ③ 入站影子觀察自檢（unittest）：python3 -m unittest discover -s profiles/mythos/plugins/mythos-tools -p 'test_*.py'。
假 event／假 gateway、假 bin/followup-direct、mktemp 目錄；不連網、不碰真的 Hermes。

- off（未設定）：不呼叫子行程、回 None。
- observe：allowlist 內的 Telegram 回覆 → 呼叫一次（argv 只有 chat／message／reply_to，原文走 stdin）、回 None。
- 非名單 chat／非 Telegram／沒有 reply_to：不呼叫。
- 子行程逾時或丟例外：仍回 None。
- --seen 命中時 mythos_dispatch 不派工，回「已接續原工作」；拿不到事件鍵照常派。
"""
import os
import stat
import subprocess as _sp
import shutil
import sys
import tempfile
import types
import unittest
from unittest import mock

# MYTHOS_DIR 只在還沒設時才給暫存值（discover 會同時載入其他自檢模組，不能亂改它們的環境）
_TMP = tempfile.mkdtemp(prefix="mythos-inbound.")
os.environ.setdefault("MYTHOS_DIR", _TMP)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.modules.pop("__init__", None)  # discover 時其他自檢可能已快取另一份 MYTHOS_DIR
import __init__ as mt  # noqa: E402
try:
    import test_inbound  # noqa: F401
except Exception:
    pass

_REAL_RUN = _sp.run  # 其他自檢會改 subprocess.run（同一個模組物件），先存真的
CHAT = "1234567"
OTHER = "7654321"
TEXT = "把欄位改成中文"


class _Ev:
    def __init__(self, chat, mid, reply, platform, text):
        self.source = types.SimpleNamespace(platform=types.SimpleNamespace(value=platform), chat_id=chat)
        self.message_id, self.reply_to_message_id, self.text = mid, reply, text


def event(chat=CHAT, mid="42", reply="41", platform="telegram", text=TEXT):
    # 具名類別（不用 SimpleNamespace：unittest 執行時的 repr 會印出它，mock 認領時會出事）
    return _Ev(chat, mid, reply, platform, text)


def drain():
    for t in list(mt._inflight):
        t.join(5)


class Hook(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mythos-inbound-case.")
        self.log = os.path.join(self.tmp, "calls")
        bd = os.path.join(self.tmp, "bin")
        os.makedirs(bd)
        fd = os.path.join(bd, "followup-direct")
        with open(fd, "w", encoding="utf-8") as f:
            f.write(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{self.log}"\ncat >/dev/null\nexit 3\n')
        os.chmod(fd, os.stat(fd).st_mode | stat.S_IXUSR)
        self.env = mock.patch.dict(os.environ, {"MYTHOS_TG_CHAT_ID": CHAT})
        self.env.start()
        self.mythos = mock.patch.multiple(
            mt, MYTHOS=self.tmp, STATE=os.path.join(self.tmp, "state"), LOG=os.path.join(self.tmp, "state", "l"))
        self.mythos.start()
        self.prof = mock.patch.object(mt, "_profile_allow", return_value=[])
        self.prof.start()
        self.runp = mock.patch.object(mt.subprocess, "run", _REAL_RUN)
        self.runp.start()
        mt._inbound_ctx.chat = ""
        mt._inbound_ctx.saved = ""

    def tearDown(self):
        shutil.rmtree(os.path.join(self.tmp, "state"), ignore_errors=True)
        self.runp.stop()
        self.prof.stop()
        self.mythos.stop()
        self.env.stop()
        os.environ.pop("MYTHOS_FOLLOWUP_DIRECT", None)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def calls(self):
        drain()
        try:
            with open(self.log, encoding="utf-8") as f:
                return f.read().splitlines()
        except OSError:
            return []

    def test_off_does_not_call(self):
        for v in (None, "", "off", "yes"):
            if v is None:
                os.environ.pop("MYTHOS_FOLLOWUP_DIRECT", None)
            else:
                os.environ["MYTHOS_FOLLOWUP_DIRECT"] = v
            self.assertIsNone(mt._on_pre_gateway_dispatch(event=event(), gateway=None))
        self.assertEqual(self.calls(), [])

    def test_observe_calls_once_returns_none(self):
        os.environ["MYTHOS_FOLLOWUP_DIRECT"] = "observe"
        self.assertIsNone(mt._on_pre_gateway_dispatch(event=event(), gateway=None))
        self.assertEqual(self.calls(), [f"{CHAT} 42 41"])  # 原文不進 argv
        self.assertEqual(mt._inbound_ctx.chat, CHAT)

    def test_auto_logs_not_wired_and_still_returns_none(self):
        os.environ["MYTHOS_FOLLOWUP_DIRECT"] = "auto"
        logp = os.path.join(self.tmp, "state", "mythos-inbox.log")
        if os.path.exists(logp):
            os.unlink(logp)
        self.assertIsNone(mt._on_pre_gateway_dispatch(event=event(), gateway=None))
        self.assertEqual(self.calls(), [f"{CHAT} 42 41"])
        with open(logp, encoding="utf-8") as f:
            self.assertIn("auto 尚未接線", f.read())

    def test_observer_forces_shadow_mode(self):
        for mode in ("observe", "auto", "1"):
            with self.subTest(mode=mode), mock.patch.dict(os.environ, MYTHOS_FOLLOWUP_DIRECT=mode):
                with mock.patch.object(mt.subprocess, "run") as run:
                    mt._run_observer(["followup-direct"], TEXT, self.tmp)
                self.assertEqual(run.call_args.kwargs["env"]["MYTHOS_FOLLOWUP_DIRECT"], "observe")

    def test_non_allowlisted_chat_not_called(self):
        os.environ["MYTHOS_FOLLOWUP_DIRECT"] = "observe"
        self.assertIsNone(mt._on_pre_gateway_dispatch(event=event(chat=OTHER), gateway=None))
        self.assertEqual(self.calls(), [])
        self.assertEqual(mt._inbound_ctx.chat, "")

    def test_non_telegram_not_called(self):
        os.environ["MYTHOS_FOLLOWUP_DIRECT"] = "observe"
        self.assertIsNone(mt._on_pre_gateway_dispatch(event=event(platform="discord"), gateway=None))
        self.assertEqual(self.calls(), [])

    def test_no_reply_to_not_called(self):
        os.environ["MYTHOS_FOLLOWUP_DIRECT"] = "observe"
        for r in (None, "", "0x"):
            self.assertIsNone(mt._on_pre_gateway_dispatch(event=event(reply=r), gateway=None))
        self.assertEqual(self.calls(), [])

    def test_timeout_and_exception_still_return_none(self):
        os.environ["MYTHOS_FOLLOWUP_DIRECT"] = "observe"
        import subprocess
        for exc in (subprocess.TimeoutExpired(["followup-direct"], 2), OSError("boom"), RuntimeError("x")):
            with mock.patch.object(mt.subprocess, "run", side_effect=exc):
                self.assertIsNone(mt._on_pre_gateway_dispatch(event=event(), gateway=None))

    def test_hook_does_not_block_caller(self):
        # P6c：Hermes 在事件迴圈上直接呼叫同步 callback；子行程慢也要立刻回
        import time
        os.environ["MYTHOS_FOLLOWUP_DIRECT"] = "observe"
        with open(os.path.join(self.tmp, "bin", "followup-direct"), "w", encoding="utf-8") as f:
            f.write("#!/bin/sh\nsleep 1.5\n")
        t0 = time.time()
        self.assertIsNone(mt._on_pre_gateway_dispatch(event=event(), gateway=None))
        self.assertLess(time.time() - t0, 0.5)
        drain()

    def test_subprocess_timeout_really_kills(self):
        # P6c：timeout 要真的生效（不是只有 mock 例外）：慢到 3 秒的子行程在 0.3 秒上限下必須被收掉
        import time
        os.environ["MYTHOS_FOLLOWUP_DIRECT"] = "observe"
        with open(os.path.join(self.tmp, "bin", "followup-direct"), "w", encoding="utf-8") as f:
            f.write("#!/bin/sh\nexec sleep 3\n")
        with mock.patch.object(mt, "_HOOK_TIMEOUT", 0.3):
            self.assertIsNone(mt._on_pre_gateway_dispatch(event=event(), gateway=None))
            t0 = time.time()
            drain()
        self.assertLess(time.time() - t0, 1.5)

    def test_ctx_visible_from_other_thread(self):
        # P6c：hook 在事件迴圈執行緒、mythos_dispatch 在工具執行緒；入站鍵要跨執行緒看得到
        import threading
        os.environ["MYTHOS_FOLLOWUP_DIRECT"] = "observe"
        th = threading.Thread(target=lambda: mt._on_pre_gateway_dispatch(event=event(), gateway=None))
        th.start(); th.join()
        self.assertEqual(mt._inbound_ctx.chat, CHAT)
        self.assertEqual(mt._inbound_ctx.msg, "42")

    def test_allowlisted_non_reply_clears_stale_ctx(self):
        # P6c：名單內的新訊息不是追問時要清掉上一則殘留，否則後面的派工會對到舊事件
        os.environ["MYTHOS_FOLLOWUP_DIRECT"] = "observe"
        mt._on_pre_gateway_dispatch(event=event(), gateway=None)
        self.assertEqual(mt._inbound_ctx.msg, "42")
        mt._on_pre_gateway_dispatch(event=event(mid="43", reply=None), gateway=None)
        self.assertEqual(mt._inbound_ctx.chat, "")
        # 非名單 chat 不動 ctx（也不記錄）
        mt._on_pre_gateway_dispatch(event=event(), gateway=None)
        mt._on_pre_gateway_dispatch(event=event(chat=OTHER, mid="44", reply=None), gateway=None)
        self.assertEqual(mt._inbound_ctx.msg, "42")

    def test_profile_allowlist_env_expansion(self):
        # profile 檔寫 '${MYTHOS_TG_CHAT_ID}'：展開後才比對；'*'、暱稱不放行
        self.prof.stop()
        self.prof = mock.patch.object(mt, "_profile_allow",
                                      return_value=[["${MYTHOS_TG_CHAT_ID}", "*", "alice"], []])
        self.prof.start()
        self.assertEqual(mt._allowed_chats(None), {CHAT})


    def test_group_chat_negative_id_allowed(self):
        # P6c：群組 chat id 是負數；followup-direct 也收 -?\d+，名單不能只認正整數
        self.prof.stop()
        self.prof = mock.patch.object(mt, "_profile_allow", return_value=[["-555", "-abc", "1-2"], []])
        self.prof.start()
        self.assertEqual(mt._allowed_chats(None), {"-555", CHAT})


class Seen(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="mythos-seen.")
        self.env = mock.patch.dict(os.environ, {"MYTHOS_DIR": self.tmp})
        self.p_at = mock.patch.multiple(mt, MYTHOS=self.tmp, STATE=os.path.join(self.tmp, "state"),
                                        LOG=os.path.join(self.tmp, "l"))
        self.p_at.start()
        self.runp = mock.patch.object(mt.subprocess, "run", _REAL_RUN)
        self.runp.start()
        self.bg_calls = os.path.join(self.tmp, "bg-calls")
        os.makedirs(os.path.join(self.tmp, "bin"))
        with open(os.path.join(self.tmp, "bin", "dispatch-bg"), "w", encoding="utf-8") as f:
            f.write(f'#!/bin/sh\necho "$*" >> "{self.bg_calls}"\necho bg-fake\n')
        os.chmod(os.path.join(self.tmp, "bin", "dispatch-bg"), 0o755)
        # --seen 結果由檔案決定：有=回 thread、沒有 exit 1
        self.seen_file = os.path.join(self.tmp, "seen")
        with open(os.path.join(self.tmp, "bin", "followup-direct"), "w", encoding="utf-8") as f:
            f.write(f'#!/bin/sh\n[ "$1" = --seen ] || exit 3\ncat "{self.seen_file}" 2>/dev/null || exit 1\n'
                    f'echo seen t-abc123\nexit 0\n')
        os.chmod(os.path.join(self.tmp, "bin", "followup-direct"), 0o755)
        self.mapf = os.path.join(self.tmp, "state", "tg-chat-session.json")
        os.makedirs(os.path.dirname(self.mapf))
        self.env.start()
        os.environ.pop("MYTHOS_DISPATCH_DRYRUN", None)
        os.environ.pop("MYTHOS_FOLLOWUP_DIRECT", None)
        mt._recall_current = ""
        mt._inbound_ctx.chat = ""
        mt._inbound_ctx.saved = ""

    def tearDown(self):
        self.runp.stop()
        self.p_at.stop()
        self.env.stop()
        mt._recall_current = ""
        mt._inbound_ctx.chat = ""
        mt._inbound_ctx.saved = ""
        shutil.rmtree(self.tmp, ignore_errors=True)

    def bg(self):
        try:
            with open(self.bg_calls, encoding="utf-8") as f:
                return f.read().splitlines()
        except OSError:
            return []

    def note(self, msg, session="sess-1"):
        mt._inbound_ctx.chat, mt._inbound_ctx.msg = CHAT, msg
        mt._remember_session_chat(session)
        mt._inbound_ctx.chat = ""
        mt._inbound_ctx.saved = ""

    def test_seen_hit_skips_dispatch(self):
        os.environ["MYTHOS_FOLLOWUP_DIRECT"] = "auto"
        open(self.seen_file, "w").close()
        self.note("57")
        mt._recall_current = "sess-1"
        out = mt.mythos_dispatch({"request": "再改一下"})
        self.assertEqual(out, "已接續原工作")
        self.assertEqual(self.bg(), [])
        # 同一事件只擋一次：第二次照常派
        self.assertTrue(mt.mythos_dispatch({"request": "再改一下"}).startswith("已派 "))
        self.assertEqual(len(self.bg()), 1)

    def test_off_mode_ignores_stale_map_and_never_calls_seen(self):
        # P6c：MYTHOS_FOLLOWUP_DIRECT 未啟用＝與 main 一致：殘留對照檔不能讓 --seen 擋掉派工，也不呼叫子行程
        os.environ.pop("MYTHOS_FOLLOWUP_DIRECT", None)
        open(self.seen_file, "w").close()
        self.note("57")
        mt._recall_current = "sess-1"
        out = mt.mythos_dispatch({"request": "再改一下"})
        self.assertTrue(out.startswith("已派 "), out)
        self.assertEqual(len(self.bg()), 1)

    def test_seen_miss_dispatches(self):
        os.environ["MYTHOS_FOLLOWUP_DIRECT"] = "auto"
        self.note("58")
        mt._recall_current = "sess-1"
        self.assertTrue(mt.mythos_dispatch({"request": "再改一下"}).startswith("已派 "))
        self.assertEqual(len(self.bg()), 1)

    def test_no_event_key_dispatches(self):
        os.environ["MYTHOS_FOLLOWUP_DIRECT"] = "auto"
        open(self.seen_file, "w").close()
        mt._recall_current = "sess-unknown"
        self.assertTrue(mt.mythos_dispatch({"request": "一般追加"}).startswith("已派 "))
        self.assertEqual(len(self.bg()), 1)


if __name__ == "__main__":
    unittest.main()
