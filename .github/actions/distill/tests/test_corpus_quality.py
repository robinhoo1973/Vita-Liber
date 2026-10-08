"""语料质量闸负测(round5 E0;X2 裁决消费)。stdlib 可跑。

覆盖:健康语料 pass;span 损伤偏离/CER 偏离/kind 缺单元/kind deficit/
SFT 泄漏 holdout/eval 无 holdout/forced=0 各自判红;underpowered 只登记不阻断。
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

DISTILL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DISTILL))

from gate.corpus_quality import check  # noqa: E402

POL = {
    "noise": {
        "bandTargets": {"clean": 0.0, "light": 0.02, "medium": 0.05, "heavy": 0.10, "extreme": 0.18},
        "spanDamageTargets": {"clean": 0.0, "light": 0.11, "medium": 0.26, "heavy": 0.47, "extreme": 0.70},
        "spanDamageTolerance": {"clean": 0.0, "light": 0.03, "medium": 0.04, "heavy": 0.05, "extreme": 0.05},
        "spanDamageMinSpans": 1000,
    },
    "gates": {"extraction": {"evalPerCell": 60, "minSamplesPerCell": 50, "evalQuotaUnit": "kind"}},
    "corpus": {"requiredKinds": ["prescription"], "deferredKinds": {}},
}


def _manifest(**over):
    m = {
        "params": {"kinds": ["prescription"]},
        "noise": {"span_damage_by_band": {
            "light": {"samples": 10, "spans": 1500, "damaged": 165, "rate": 0.11,
                      "cer_mean": 0.02, "cer_n": 1500},
            "clean": {"samples": 10, "spans": 1500, "damaged": 0, "rate": 0.0,
                      "cer_mean": 0.0, "cer_n": 1500},
        }},
        "stats": {
            "eval_cells": {"kind:prescription": {"total": 1000, "eval": 120, "deficit": 0}},
            "value_holdout": {"forced": 5},
        },
    }
    m.update(over)
    return m


def _write(tmp: Path, manifest: dict, sft_rows=None, eval_rows=None):
    (tmp / "extraction_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False),
                                                  encoding="utf-8")
    (tmp / "extraction_sft.jsonl").write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in (sft_rows or [{"id": "extract-prescription-000001"}])) + "\n",
        encoding="utf-8")
    (tmp / "extraction_eval.jsonl").write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in (eval_rows or [{"id": "extract-prescription-000900", "value_holdout": True}])) + "\n",
        encoding="utf-8")


class CorpusQualityTests(unittest.TestCase):
    def _run(self, **kw):
        tmp = Path(tempfile.mkdtemp())
        _write(tmp, *kw.pop("args", (kw.pop("manifest", _manifest()),)))
        failures, report = check(tmp, kw.pop("policy", POL))
        return failures, report

    def test_healthy_passes(self):
        failures, report = self._run()
        self.assertEqual(failures, [])
        self.assertIn("prescription", report["kind_eval"])

    def test_span_damage_drift_fails(self):
        m = _manifest()
        m["noise"]["span_damage_by_band"]["light"]["rate"] = 0.20   # 目标 0.11±0.03
        failures, _ = self._run(manifest=m)
        self.assertTrue(any("span 损伤率" in f for f in failures))

    def test_small_band_skips_assertion(self):
        m = _manifest()
        m["noise"]["span_damage_by_band"]["light"]["spans"] = 40    # < minSpans → 跳过
        m["noise"]["span_damage_by_band"]["light"]["rate"] = 0.99
        failures, _ = self._run(manifest=m)
        self.assertEqual(failures, [])

    def test_cer_drift_fails(self):
        m = _manifest()
        m["noise"]["span_damage_by_band"]["light"]["cer_mean"] = 0.09   # 目标 0.02±0.02
        failures, _ = self._run(manifest=m)
        self.assertTrue(any("CER 均值" in f for f in failures))

    def test_missing_kind_fails(self):
        m = _manifest()
        m["params"]["kinds"] = []
        failures, _ = self._run(manifest=m)
        self.assertTrue(any("必需卡种" in f for f in failures))

    def test_kind_deficit_fails(self):
        m = _manifest()
        m["stats"]["eval_cells"]["kind:prescription"]["eval"] = 40
        m["stats"]["eval_cells"]["kind:prescription"]["deficit"] = 20
        failures, _ = self._run(manifest=m)
        self.assertTrue(any("定额" in f or "deficit" in f for f in failures))

    def test_holdout_leak_fails(self):
        failures, _ = self._run(args=(_manifest(), [{"id": "x", "value_holdout": True}],
                                      [{"id": "y", "value_holdout": True}]))
        self.assertTrue(any("泄漏" in f for f in failures))

    def test_eval_without_holdout_fails(self):
        failures, _ = self._run(args=(_manifest(), None, [{"id": "y"}]))
        self.assertTrue(any("留出集从未被测" in f for f in failures))

    def test_zero_forced_fails(self):
        m = _manifest()
        m["stats"]["value_holdout"] = {"forced": 0}
        failures, _ = self._run(manifest=m)
        self.assertTrue(any("forced=0" in f for f in failures))

    def test_underpowered_registered_not_blocking(self):
        m = _manifest()
        m["stats"]["eval_cells"]["prescription|light"] = {"total": 100, "eval": 5, "deficit": 0}
        failures, report = self._run(manifest=m)
        self.assertEqual(failures, [])
        self.assertGreaterEqual(report["underpowered_cells_total"], 1)


if __name__ == "__main__":
    unittest.main()
