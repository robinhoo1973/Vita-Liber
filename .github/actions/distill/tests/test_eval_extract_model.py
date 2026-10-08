"""eval_extract_model.py 负测(2026-10-08 round5 E0)。

覆盖: identity 臂全格 F1=1(评分器+CLI 的自证链)、按行序回退的覆盖缺失记账、
coverage=0 判运行错误、--require-bands 缺标签 exit 1、baseline 逐格非劣与回归标注、
非法输出 JSON 计入硬零 H1。零第三方依赖。
"""
import json
import tempfile
import unittest
from pathlib import Path

from eval_extract_model import main


def _row(band: str, idx: int):
    gold = {"shared": [{"key": "hospital", "value": f"医院{idx}", "lineIndex": 0}],
            "rows": [[{"key": "drug_name", "value": "阿莫西林", "lineIndex": 1}]]}
    user = "\n".join([f"[0] 医院{idx}", "[1] 阿莫西林 1片"])
    return {"conversations": [
        {"role": "system", "content": "s"},
        {"role": "user", "content": user},
        {"role": "assistant", "content": json.dumps(gold, ensure_ascii=False)},
    ], "noise": {"band": band}, "kind": "prescription"}


class CliTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.eval_file = self.tmp / "extraction_eval.jsonl"
        rows = [_row("light", 1), _row("medium", 2)]
        self.eval_file.write_text(
            "\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n",
            encoding="utf-8")

    def tearDown(self):
        self._tmp.cleanup()

    def test_gold_only_identity_all_green(self):
        report_path = self.tmp / "report.json"
        rc = main(["--eval-file", str(self.eval_file), "--gold-only",
                   "--min-samples", "1", "--write-report", str(report_path)])
        self.assertEqual(rc, 0)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(report["status"], "report-only")
        for cell in report["cells"].values():
            self.assertEqual(cell["strict"]["f1"], 1.0)
        self.assertEqual(sum(report["hard_zero_totals"].values()), 0)

    def test_require_bands_fails_on_unlabeled(self):
        rows = [_row("light", 1)]
        rows[0]["noise"] = {}
        self.eval_file.write_text(
            json.dumps(rows[0], ensure_ascii=False) + "\n", encoding="utf-8")
        rc = main(["--eval-file", str(self.eval_file), "--gold-only", "--require-bands"])
        self.assertEqual(rc, 1)

    def test_coverage_zero_is_run_error(self):
        empty_output = self.tmp / "out.jsonl"
        empty_output.write_text("", encoding="utf-8")
        rc = main(["--eval-file", str(self.eval_file),
                   "--model-output", str(empty_output), "--min-samples", "1"])
        self.assertEqual(rc, 1)

    def test_missing_outputs_counted_and_h1(self):
        out = self.tmp / "out.jsonl"
        out.write_text(json.dumps({"text": "不是JSON"}) + "\n", encoding="utf-8")
        report_path = self.tmp / "report.json"
        rc = main(["--eval-file", str(self.eval_file), "--model-output", str(out),
                   "--min-samples", "1", "--write-report", str(report_path)])
        self.assertEqual(rc, 0)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(report["coverage"], 0.5)  # 2 行,1 条输出(按行序 __row0)
        self.assertEqual(report["hard_zero_totals"]["json_invalid"], 1)

    def test_baseline_regression_flagged(self):
        # 基线全 1.0 → 近形值预测达 partial,strict 掉 → 回归标注(不阻断报告)
        out = self.tmp / "out.jsonl"
        rows = [_row("light", 1)]
        wrong = {"shared": [{"key": "hospital", "value": "医院", "lineIndex": 0}],
                 "rows": [[{"key": "drug_name", "value": "阿莫西", "lineIndex": 1}]]}
        out.write_text(json.dumps({"text": json.dumps(wrong, ensure_ascii=False)},
                                  ensure_ascii=False) + "\n", encoding="utf-8")
        baseline = {"cells": {"light|prescription": {"strict": {"f1": 1.0}}}}
        baseline_path = self.tmp / "baseline.json"
        baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
        self.eval_file.write_text(json.dumps(rows[0], ensure_ascii=False) + "\n",
                                  encoding="utf-8")
        report_path = self.tmp / "report.json"
        rc = main(["--eval-file", str(self.eval_file), "--model-output", str(out),
                   "--baseline", str(baseline_path), "--tau", "0.03",
                   "--min-samples", "1", "--write-report", str(report_path)])
        self.assertEqual(rc, 0)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertTrue(report["regressions"])
        self.assertLess(report["regressions"][0]["delta"], 0)

    def test_kind_recovered_from_id_when_absent(self):
        # round2 D:eval 行缺 kind 字段时由 id 前缀复原(否则 band×kind 静默退化)
        from eval_extract_model import _kind_from_id, _row_gold_and_lines
        self.assertEqual(_kind_from_id("extract-claim_item-000123"), "claim_item")
        self.assertEqual(_kind_from_id(""), "unlabeled")
        row = _row("light", 1)
        del row["kind"]
        row["id"] = "extract-metric_sample-000007"
        _, _, _, kind = _row_gold_and_lines(row)
        self.assertEqual(kind, "metric_sample")
        row2 = _row("light", 1)
        del row2["kind"]
        _, _, _, kind2 = _row_gold_and_lines(row2)
        self.assertEqual(kind2, "unlabeled")


if __name__ == "__main__":
    unittest.main()
