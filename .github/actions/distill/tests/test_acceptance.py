"""gate.acceptance 裁决器负测(2026-10-08;闸契约变更须附负测纪律)。

覆盖:必需绿缺失/失败、verdict 非 pass、记录面不阻断、main() 落盘与退出码。
零第三方依赖:CI tests job 实跑。
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from gate.acceptance import evaluate, main


def _all_green():
    return {"tests": "success", "prepare": "success", "eval": "success", "smoke": "success"}


class EvaluateTests(unittest.TestCase):
    def test_all_green_go(self):
        report = evaluate(results=_all_green(), records={"calibrate": "success"}, verdict="pass")
        self.assertTrue(report["go"])
        self.assertEqual(report["failures"], [])

    def test_smoke_failure_blocks(self):
        results = _all_green() | {"smoke": "failure"}
        report = evaluate(results=results, records={}, verdict="pass")
        self.assertFalse(report["go"])
        self.assertIn("smoke", " ".join(report["failures"]))

    def test_missing_required_blocks(self):
        results = _all_green()
        del results["prepare"]
        report = evaluate(results=results, records={}, verdict="pass")
        self.assertFalse(report["go"])
        self.assertIn("missing", " ".join(report["failures"]))

    def test_verdict_fail_blocks(self):
        report = evaluate(results=_all_green(), records={}, verdict="fail")
        self.assertFalse(report["go"])
        self.assertIn("verdict", " ".join(report["failures"]))

    def test_verdict_missing_blocks(self):
        report = evaluate(results=_all_green(), records={}, verdict="")
        self.assertFalse(report["go"])

    def test_calibrate_failure_recorded_not_blocking(self):
        report = evaluate(results=_all_green(),
                          records={"calibrate": "failure", "calibrate-macos": "cancelled"},
                          verdict="pass")
        self.assertTrue(report["go"])
        self.assertEqual(report["record"]["calibrate-macos"], "cancelled")

    def test_run_url_and_sha_recorded(self):
        with mock.patch.dict("os.environ", {
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "o/r",
                "GITHUB_RUN_ID": "42",
                "GITHUB_SHA": "abc123"}):
            report = evaluate(results=_all_green(), records={}, verdict="pass")
        self.assertEqual(report["run_url"], "https://github.com/o/r/actions/runs/42")
        self.assertEqual(report["git_sha"], "abc123")


class MainTests(unittest.TestCase):
    def test_main_writes_report_and_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "acceptance.json"
            argv = ["acceptance.py", "--result", "tests=success", "--result", "prepare=success",
                    "--result", "eval=success", "--result", "smoke=success",
                    "--verdict", "pass", "--out", str(out)]
            with mock.patch.object(sys, "argv", argv):
                self.assertEqual(main(), 0)
            report = json.loads(out.read_text(encoding="utf-8"))
            self.assertTrue(report["go"])

            argv[argv.index("smoke=success")] = "smoke=failure"
            with mock.patch.object(sys, "argv", argv):
                self.assertEqual(main(), 1)


if __name__ == "__main__":
    unittest.main()
