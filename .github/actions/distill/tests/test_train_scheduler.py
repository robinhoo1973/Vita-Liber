"""train_scheduler 决策表负测(2026-10-09 业主四规则)。stdlib 可跑。

四规则逐一钉:①未更新 skip ②窗口调度由 maintenance cron 承载(此处验决策面)
③未完成 continue 优先 ④预算在 policy/workflow 层(policy 测试覆盖)。
"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

DISTILL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DISTILL))

from gen.train_scheduler import DECISIONS, decide, decide_with_corpus  # noqa: E402

CLI = DISTILL / "gen" / "train_scheduler.py"


class SchedulerTests(unittest.TestCase):
    def test_no_state_starts(self):
        self.assertEqual(decide(sqlite_data_version="DV2", state=None), "start")

    def test_running_preempts_everything(self):
        st = {"status": "running", "trained_data_version": "DV1"}
        self.assertEqual(decide(sqlite_data_version="DV1", state=st), "continue")
        self.assertEqual(decide(sqlite_data_version="DV9", state=st), "continue")

    def test_unchanged_skips(self):
        st = {"status": "done", "trained_data_version": "DV2"}
        self.assertEqual(decide(sqlite_data_version="DV2", state=st), "skip")

    def test_changed_new_lineage_starts(self):
        st = {"status": "done", "trained_data_version": "DV1"}
        self.assertEqual(decide(sqlite_data_version="DV2", state=st), "start")

    def test_corpus_stale_rebuilds(self):
        st = {"status": "done", "trained_data_version": "DV1"}
        self.assertEqual(decide_with_corpus(sqlite_data_version="DV3",
                                            corpus_data_version="DV2", state=st),
                         "rebuild-corpus")

    def test_corpus_synced_starts(self):
        st = {"status": "done", "trained_data_version": "DV1"}
        self.assertEqual(decide_with_corpus(sqlite_data_version="DV2",
                                            corpus_data_version="DV2", state=st),
                         "start")

    def test_first_training_with_stale_corpus_rebuilds(self):
        self.assertEqual(decide_with_corpus(sqlite_data_version="DV2",
                                            corpus_data_version="DV1", state=None),
                         "rebuild-corpus")

    def test_stopped_state_resumes_via_start(self):
        # stopped(失败/maxChunks)非 running:若数据未变 → skip 会丢链;按谱系规则
        # stopped+数据已变 → start(新谱系),数据未变 → skip 需人工裁决(登记语义)
        st = {"status": "stopped", "trained_data_version": "DV1", "stop_reason": "failed"}
        self.assertEqual(decide_with_corpus(sqlite_data_version="DV2",
                                            corpus_data_version="DV2", state=st), "start")

    def test_cli_writes_decision(self):
        tmp = Path(tempfile.mkdtemp())
        stf = tmp / "s.json"
        stf.write_text(json.dumps({"status": "done", "trained_data_version": "DV1"}), encoding="utf-8")
        out = tmp / "d.txt"
        r = subprocess.run([sys.executable, str(CLI), "--sqlite-data-version", "DV2",
                            "--corpus-data-version", "DV2", "--state", str(stf), "--out", str(out)],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(out.read_text().strip(), "start")
        self.assertIn("start", DECISIONS)


if __name__ == "__main__":
    unittest.main()
