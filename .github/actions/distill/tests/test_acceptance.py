"""gate.acceptance 裁决器负测(2026-10-08;闸契约变更须附负测纪律)。

job 细分版契约:必需绿=10 作业(含 build-*/smoke-*/eval-*);
必需裁决=entlink/corpora 双 verdict;calibrate 记录面不阻断;main 落盘与退出码。
零第三方依赖:CI tests job 实跑。
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from gate.acceptance import evaluate, main

REQUIRED = ("tests", "tests-torch", "export-prompts", "fetch-catalog",
            "materialize-catalog", "build-extraction", "build-entlink",
            "build-dialogue", "smoke-encoder", "smoke-extraction", "smoke-dialogue",
            "eval-entlink", "eval-corpora")
PASS_VERDICTS = {"entlink": "pass", "corpora": "pass"}


def _all_green():
    return {name: "success" for name in REQUIRED}


class EvaluateTests(unittest.TestCase):
    def test_all_green_go(self):
        report = evaluate(results=_all_green(), records={"calibrate": "success"},
                          verdicts=PASS_VERDICTS)
        self.assertTrue(report["go"])
        self.assertEqual(report["failures"], [])

    def test_smoke_encoder_failure_blocks(self):
        results = _all_green() | {"smoke-encoder": "failure"}
        report = evaluate(results=results, records={}, verdicts=PASS_VERDICTS)
        self.assertFalse(report["go"])
        self.assertIn("smoke-encoder", " ".join(report["failures"]))

    def test_missing_build_job_blocks(self):
        results = _all_green()
        del results["build-entlink"]
        report = evaluate(results=results, records={}, verdicts=PASS_VERDICTS)
        self.assertFalse(report["go"])
        self.assertIn("missing", " ".join(report["failures"]))

    def test_skipped_required_blocks(self):
        # 未预期 skip=实测噪声(ERR#30 族):非 success 一律不通过
        results = _all_green() | {"eval-corpora": "skipped"}
        report = evaluate(results=results, records={}, verdicts=PASS_VERDICTS)
        self.assertFalse(report["go"])

    def test_verdict_fail_blocks(self):
        report = evaluate(results=_all_green(), records={},
                          verdicts={"entlink": "fail", "corpora": "pass"})
        self.assertFalse(report["go"])
        self.assertIn("entlink=fail", " ".join(report["failures"]))

    def test_verdict_missing_blocks(self):
        report = evaluate(results=_all_green(), records={}, verdicts={})
        self.assertFalse(report["go"])

    def test_calibrate_failure_recorded_not_blocking(self):
        report = evaluate(results=_all_green(),
                          records={"calibrate": "failure", "calibrate-macos": "cancelled"},
                          verdicts=PASS_VERDICTS)
        self.assertTrue(report["go"])
        self.assertEqual(report["record"]["calibrate-macos"], "cancelled")

    def test_run_url_and_sha_recorded(self):
        with mock.patch.dict("os.environ", {
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "o/r",
                "GITHUB_RUN_ID": "42",
                "GITHUB_SHA": "abc123"}):
            report = evaluate(results=_all_green(), records={}, verdicts=PASS_VERDICTS)
        self.assertEqual(report["run_url"], "https://github.com/o/r/actions/runs/42")
        self.assertEqual(report["git_sha"], "abc123")


class MainTests(unittest.TestCase):
    def _argv(self, smoke_result="success"):
        argv = ["acceptance.py"]
        for name in REQUIRED:
            value = smoke_result if name == "smoke-encoder" else "success"
            argv += ["--result", f"{name}={value}"]
        argv += ["--verdict", "entlink=pass", "--verdict", "corpora=pass"]
        return argv

    def test_main_writes_report_and_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "acceptance.json"
            argv = self._argv() + ["--out", str(out)]
            with mock.patch.object(sys, "argv", argv):
                self.assertEqual(main(), 0)
            report = json.loads(out.read_text(encoding="utf-8"))
            self.assertTrue(report["go"])
            self.assertEqual(len(report["required"]), len(REQUIRED))

            argv = self._argv(smoke_result="failure") + ["--out", str(out)]
            with mock.patch.object(sys, "argv", argv):
                self.assertEqual(main(), 1)


if __name__ == "__main__":
    unittest.main()
