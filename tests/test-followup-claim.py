#!/usr/bin/env python3
"""共用 ledger 鎖決定唯一擁有者，含競爭、rename 中斷與停止請求；全離線。"""
import concurrent.futures
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]


class Claim(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="claim.")
        self.root = Path(self.tmp.name)
        st = self.root / "state"
        st.mkdir()
        (st / "tg-msg-thread.tsv").write_text("777\t41\tt-test\tbg-test\t1\n")
        (st / "dispatch-jobs.tsv").write_text("bg-test\tmid\t-\t1\tdone\t-\tt-test\thermes\n")
        self.env = dict(PATH=os.environ["PATH"], MYTHOS_DIR=str(self.root), MYTHOS_FOLLOWUP_DIRECT="auto")

    def tearDown(self):
        self.tmp.cleanup()

    def call(self, claim=False, mid="42", text="再補欄位", **env):
        args = ["--claim-router", "777", mid] if claim else ["777", mid, "41"]
        return subprocess.run([str(ROOT / "bin/followup-direct")] + args, input=text, text=True,
                              capture_output=True, env=dict(self.env, **env), timeout=15)

    def receipts(self):
        p = self.root / "state/followup/receipts.tsv"
        return [line.split("\t") for line in p.read_text().splitlines()] if p.exists() else []

    def test_claim_before_queue(self):
        self.assertEqual(self.call(True).returncode, 1)
        self.assertEqual(self.call().returncode, 8)
        self.assertEqual(list((self.root / "state/mailbox").glob("**/fu-*.md")), [])
        self.assertTrue(any(r[1] == "stale" and r[7] == "Router 已接手" for r in self.receipts()))

    def test_queue_before_claim(self):
        self.assertEqual(self.call().returncode, 0)
        r = self.call(True)
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "seen t-test"))
        self.assertFalse(any(r[1] == "routed" for r in self.receipts()))

    def test_claim_reconciles_rename(self):
        self.assertEqual(self.call(FOLLOWUP_TEST_FAULT="after-rename").returncode, 97)
        r = self.call(True)
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "seen t-test"))

    def test_concurrent_twenty(self):
        for n in range(20):
            mid = str(100 + n)
            with concurrent.futures.ThreadPoolExecutor(2) as pool:
                a = pool.submit(self.call, True, mid)
                b = pool.submit(self.call, False, mid)
                claim, queue = a.result(), b.result()
            files = list((self.root / "state/mailbox").glob("**/fu-777-" + mid + ".md"))
            routed = [r for r in self.receipts() if r[1] == "routed" and r[3] == mid]
            self.assertEqual(len(files) + len(routed), 1, (claim, queue))
            self.assertIn((claim.returncode, queue.returncode), ((0, 0), (1, 8)))

    def test_stop_not_queued(self):
        for i, text in enumerate(("/stop", "停止", "取消", "停", "不要繼續", "cancel", "stop")):
            r = self.call(mid=str(200 + i), text=text)
            self.assertEqual(r.returncode, 6, (text, r.stdout, r.stderr))
        self.assertEqual(list((self.root / "state/mailbox").glob("**/fu-*.md")), [])


if __name__ == "__main__":
    unittest.main()
