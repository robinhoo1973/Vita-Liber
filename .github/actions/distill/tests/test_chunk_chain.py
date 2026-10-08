"""chunk_chain 状态机负测(2026-10-09 CPU 训练链)。stdlib 可跑。

覆盖:推进→next、达标→done、失败→stop(failed)、达 max_chunks→stop、
零进度→stop(no_progress)、终态幂等、坏状态 fail-closed、CLI init/decide 往返。
"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

DISTILL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DISTILL))

from gen.chunk_chain import decide, load_state, new_state  # noqa: E402

CLI = DISTILL / "gen" / "chunk_chain.py"


class ChunkChainTests(unittest.TestCase):
    def test_progress_next(self):
        s = new_state("train-sft", 100, 10)
        s, d = decide(s, chunk_failed=False, chunk_steps=25, last_loss=1.2)
        self.assertEqual(d, "next")
        self.assertEqual(s["done_steps"], 25)
        self.assertEqual(s["chunks_done"], 1)
        self.assertEqual(s["last_loss"], 1.2)
        self.assertEqual(s["status"], "running")

    def test_complete_done(self):
        s = new_state("t", 50, 10)
        s, d = decide(s, chunk_failed=False, chunk_steps=60)
        self.assertEqual(d, "done")
        self.assertEqual(s["status"], "done")
        self.assertEqual(s["done_steps"], 50)   # 截断到 total

    def test_failure_stops(self):
        s = new_state("t", 100, 10)
        s, d = decide(s, chunk_failed=True, chunk_steps=10)
        self.assertEqual((d, s["status"], s["stop_reason"]), ("stop", "stopped", "failed"))

    def test_max_chunks_stops(self):
        s = new_state("t", 1000, 2)
        s, d = decide(s, chunk_failed=False, chunk_steps=10)
        self.assertEqual(d, "next")
        s, d = decide(s, chunk_failed=False, chunk_steps=10)
        self.assertEqual((d, s["stop_reason"]), ("stop", "max_chunks"))

    def test_zero_progress_stops(self):
        s = new_state("t", 100, 10)
        s, d = decide(s, chunk_failed=False, chunk_steps=0)
        self.assertEqual((d, s["stop_reason"]), ("stop", "no_progress"))

    def test_terminal_idempotent(self):
        s = new_state("t", 10, 5)
        s, _ = decide(s, chunk_failed=False, chunk_steps=10)   # done
        s2, d = decide(s, chunk_failed=False, chunk_steps=10)
        self.assertEqual(d, "stop")
        self.assertEqual(s2["done_steps"], 10)                 # 不再推进

    def test_corrupt_state_fails_loud(self):
        tmp = Path(tempfile.mkdtemp()) / "s.json"
        tmp.write_text(json.dumps({"task": "t", "done_steps": 99, "total_steps": 10,
                                   "chunks_done": 0, "max_chunks": 1, "status": "running"}),
                       encoding="utf-8")
        with self.assertRaises(ValueError):
            load_state(tmp)

    def test_cli_roundtrip(self):
        tmp = Path(tempfile.mkdtemp())
        s1, s2 = tmp / "s1.json", tmp / "s2.json"
        r = subprocess.run([sys.executable, str(CLI), "init", "--out", str(s1),
                            "--task", "train-sft", "--total-steps", "100", "--max-chunks", "5"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        r = subprocess.run([sys.executable, str(CLI), "decide", "--state", str(s1),
                            "--out", str(s2), "--chunk-steps", "40", "--last-loss", "0.9"],
                           capture_output=True, text=True)
        self.assertEqual(r.stdout.strip(), "next")
        self.assertEqual(load_state(s2)["done_steps"], 40)


if __name__ == "__main__":
    unittest.main()
