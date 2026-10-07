"""gate.entlink_gate:基线臂指标、tripwire、模型五层、BR-006 同源守卫。"""
import json
import tempfile
import unittest
from pathlib import Path

from corpus.builder import BuildConfig, build_corpus
from entlink.catalog import load_jsonl_set
from entlink.recall import RecallEngine
from gate.entlink_gate import GateConfig, run_gate
from gate.wording import WordingGuard

from tests.util import write_jsonl as _write_jsonl


def _catalog():
    return load_jsonl_set({
        "drug": _write_jsonl([
            {"region": "CN", "source_id": f"d{i}", "name_zh": f"测试药品{i}胶囊",
             "aliases": [f"药品{i}"]} for i in range(30)
        ]),
        "hospital": _write_jsonl([
            {"region": "HK", "source_id": f"h{i}", "name_zh": f"香港測試醫院{i}", "aliases": [f"港大医院{i}"]}
            for i in range(30)
        ]),
        "department": _write_jsonl([
            {"region": "TW", "source_id": f"dep{i}", "name_zh": f"综合内科科室{i}", "aliases": [f"内科{i}诊室"]}
            for i in range(30)
        ]),
        "exam": _write_jsonl([
            {"region": "CN", "source_id": f"ex{i}", "name_zh": f"实验室检查项目{i}", "aliases": [f"检验项目{i}"]}
            for i in range(30)
        ]),
    }, data_version="gate-test")


def _eval_lines(tmp: Path) -> list[dict]:
    out = tmp / "corpus.jsonl"
    # 机制测试只用 light/medium 带:合成目录别名 3-5 字,heavy=3 个真实
    # 编辑操作(删字/替换)超出基线引擎编辑距离上限 2,全带下 heavy 必然
    # 全拒识——那是带级难度的真实属性,不该由机制测试兜底(重带 tripwire
    # 判红已有 test_min_accepts_tripwire_red 覆盖)。
    build_corpus(_catalog(), out, BuildConfig(master_seed=9, min_eval_entities=2,
                                              bands=("light", "medium")))
    return [json.loads(l) for l in out.read_text(encoding="utf-8").splitlines() if json.loads(l)["split"] == "eval"]


class GateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.catalog = _catalog()
        self.engine = RecallEngine().build(self.catalog)
        self.eval_lines = _eval_lines(self.tmp)

    def test_baseline_arm_metrics_and_verdict(self):
        result = run_gate(engine=self.engine, eval_lines=self.eval_lines,
                          config=GateConfig(min_accepts=1, baseline_only=True))
        self.assertEqual(result.verdict, "pass", result.failures)
        for domain in ("drug", "hospital", "department", "exam"):
            self.assertIn(domain, result.metrics)
        self.assertIn("pinyin_available", result.index_report)
        self.assertEqual(result.layers["model"], "n/a(基线臂:无模型候选,五层闸随 P3 部署件启用)")

    def test_all_reject_tripwire_red(self):
        # 空索引 → 全拒识 → tripwire 判红(防假绿)
        empty_engine = RecallEngine().build(load_jsonl_set({}, data_version="empty"))
        result = run_gate(engine=empty_engine, eval_lines=self.eval_lines,
                          config=GateConfig(min_accepts=1))
        self.assertEqual(result.verdict, "fail")
        self.assertTrue(any("全拒识" in f for f in result.failures))

    def test_min_accepts_tripwire_red(self):
        result = run_gate(engine=self.engine, eval_lines=self.eval_lines[:3],
                          config=GateConfig(min_accepts=5))
        self.assertEqual(result.verdict, "fail")
        self.assertTrue(any("tripwire" in f for f in result.failures))

    def test_model_layers_wrong_link_red(self):
        ids_by_domain = {}
        for e in self.catalog.entities:
            ids_by_domain.setdefault(e.domain, []).append(e.entity_id)
        candidates = {}
        for line in self.eval_lines:
            pool = ids_by_domain[line["domain"]]
            wrong = pool[(pool.index(line["gold"]["entity_id"]) + 1) % len(pool)]
            candidates[line["id"]] = [{"entity_id": wrong, "score": 0.9, "matched_term": line["query"]}]
        result = run_gate(engine=self.engine, eval_lines=self.eval_lines,
                          config=GateConfig(min_accepts=1), model_candidates=candidates)
        self.assertEqual(result.verdict, "fail")
        self.assertTrue(any("错链" in f for f in result.failures))

    def test_wording_guard_br006(self):
        guard = WordingGuard([
            {"pattern": "建议服用", "label": "治疗建议"},
            {"pattern": "确诊", "label": "诊断表述"},
        ])
        self.assertIsNotNone(guard.violation("建议服用阿莫西林"))
        self.assertIsNone(guard.violation("阿莫西林胶囊 每日两次"))


if __name__ == "__main__":
    unittest.main()
