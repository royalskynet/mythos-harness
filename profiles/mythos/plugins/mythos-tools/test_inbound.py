#!/usr/bin/env python3
"""入站歸屬離線驗收：真 asyncio、假 followup-direct；不依賴 session 鍵。"""
import asyncio
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time
import types
import unittest
from unittest import mock
sys.path.insert(0, str(Path(__file__).parent))
import __init__ as mt


def event(text="追加欄位", **kw):
    vals = dict(source=types.SimpleNamespace(platform="telegram", chat_id="777"),
                message_id="42", reply_to_message_id="41", text=text)
    vals.update(kw)
    return types.SimpleNamespace(**vals)


class Hook(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="inbound."))
        (self.tmp / "bin").mkdir()
        self.env = mock.patch.dict(os.environ, MYTHOS_DIR=str(self.tmp),
                                   MYTHOS_TG_CHAT_ID="777", MYTHOS_FOLLOWUP_DIRECT="auto")
        self.env.start()
        mt._env_dirs()
        self.prof = mock.patch.object(mt, "_profile_allow", return_value=[])
        self.prof.start()
        self.script()

    def script(self, direct='echo "queued t-test"', claim='exit 1'):
        p = self.tmp / "bin/followup-direct"
        p.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "' + str(self.tmp / "calls") + '"\n'
                     + 'if [ "$1" = --claim-router ]; then\n' + claim + '\nelse\ncat > "'
                     + str(self.tmp / "input") + '"\n' + direct + '\nfi\n')
        p.chmod(0o755)

    def calls(self):
        p = self.tmp / "calls"
        return p.read_text().splitlines() if p.exists() else []

    async def asyncTearDown(self):
        for t in mt._inflight:
            t.join(3)
        self.prof.stop()
        self.env.stop()
        mt._env_dirs()
        shutil.rmtree(self.tmp)

    async def test_auto_queued_and_dup_skip_once(self):
        for mode, output in (("auto", "queued"), ("1", "dup")):
            os.environ["MYTHOS_FOLLOWUP_DIRECT"] = mode
            self.script('echo "' + output + ' t-test"')
            self.assertEqual(await mt._on_pre_gateway_dispatch(event=event()), {"action": "skip"})
        self.assertEqual(self.calls(), ["777 42 41"] * 2)
        self.assertEqual((self.tmp / "input").read_text(), "追加欄位\n")

    async def test_decline_claims_router(self):
        for rc in (4, 6):
            self.script('exit ' + str(rc))
            self.assertIsNone(await mt._on_pre_gateway_dispatch(event=event()))
        self.assertEqual(self.calls(), ["777 42 41", "--claim-router 777 42"] * 2)

    async def test_timeout_kills_and_loop_progresses(self):
        for claim, expected in (("exit 1", None), ('echo "seen t-test"', {"action": "skip"})):
            self.script('echo $$ > "' + str(self.tmp / "pid") + '"; exec sleep 5', claim)
            progress = []
            async def tick():
                await asyncio.sleep(0.05)
                progress.append(True)
            task = asyncio.create_task(tick())
            start = time.monotonic()
            self.assertEqual(await mt._on_pre_gateway_dispatch(event=event()), expected)
            self.assertLess(time.monotonic() - start, 3)
            self.assertTrue(progress)
            await task
            with self.assertRaises(ProcessLookupError):
                os.kill(int((self.tmp / "pid").read_text()), 0)

    async def test_claim_timeout_and_exception_fall_through(self):
        self.script('exit 4', 'exec sleep 5')
        start = time.monotonic()
        self.assertIsNone(await mt._on_pre_gateway_dispatch(event=event()))
        self.assertLess(time.monotonic() - start, 2)
        (self.tmp / "bin/followup-direct").unlink()
        self.assertIsNone(await mt._on_pre_gateway_dispatch(event=event()))

    async def test_bad_output_cannot_skip(self):
        self.script('echo "queued garbage"', 'echo "seen garbage"')
        self.assertIsNone(await mt._on_pre_gateway_dispatch(event=event()))
        self.assertEqual(len(self.calls()), 2)

    async def test_observe_immediate_none(self):
        os.environ["MYTHOS_FOLLOWUP_DIRECT"] = "observe"
        self.script('exec sleep 0.3')
        start = time.monotonic()
        self.assertIsNone(await mt._on_pre_gateway_dispatch(event=event()))
        self.assertLess(time.monotonic() - start, 0.2)

    async def test_off_and_invalid_source_do_not_call(self):
        for mode in ("off", "", "yes"):
            os.environ["MYTHOS_FOLLOWUP_DIRECT"] = mode
            self.assertIsNone(await mt._on_pre_gateway_dispatch(event=event()))
        os.environ["MYTHOS_FOLLOWUP_DIRECT"] = "auto"
        for ev in (event(reply_to_message_id=None), event(source=types.SimpleNamespace(platform="discord", chat_id="777")),
                   event(source=types.SimpleNamespace(platform="telegram", chat_id="888"))):
            self.assertIsNone(await mt._on_pre_gateway_dispatch(event=ev))
        self.assertEqual(self.calls(), [])

    async def test_stop_handed_to_router(self):
        # 真 judge 的停止分類另由 claim 測試覆蓋；hook 必須接受該拒絕並 claim。
        self.script('exit 6')
        self.assertIsNone(await mt._on_pre_gateway_dispatch(event=event("/stop")))
        self.assertEqual(self.calls(), ["777 42 41", "--claim-router 777 42"])

    async def test_allowlist_expansion_and_group(self):
        with mock.patch.object(mt, "_profile_allow", return_value=[["${MYTHOS_TG_CHAT_ID}", "*", "alice", "-555", "-abc", "1-2"], []]):
            self.assertEqual(mt._allowed_chats(None), {"777", "-555"})

    async def test_observer_forces_shadow(self):
        with mock.patch.object(mt.subprocess, "run") as run:
            mt._run_observer(["followup-direct"], "內容", str(self.tmp))
        self.assertEqual(run.call_args.kwargs["env"]["MYTHOS_FOLLOWUP_DIRECT"], "observe")

    async def test_cancel_cleans_process_group(self):
        self.script('echo $$ > "' + str(self.tmp / "pid") + '"; sleep 5 & echo $! > "' + str(self.tmp / "child") + '"; wait')
        task = asyncio.create_task(mt._on_pre_gateway_dispatch(event=event()))
        for _ in range(100):
            if (self.tmp / "child").exists():
                break
            await asyncio.sleep(0.01)
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        for name in ("pid", "child"):
            with self.assertRaises(ProcessLookupError):
                os.kill(int((self.tmp / name).read_text()), 0)

    async def test_no_session_binding(self):
        for name in ("_InboundCtx", "_remember_session_chat", "_handled_elsewhere", "_chat_map", "_seen"):
            self.assertFalse(hasattr(mt, name), name)


if __name__ == "__main__":
    unittest.main()
