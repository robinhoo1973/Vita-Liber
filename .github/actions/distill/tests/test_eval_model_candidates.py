"""eval_model_candidates 纯函数负测(2026-10-08 round5 E0;stdlib 可跑)。

torch 路径(编码/打分)由带 torch 执行面覆盖;此处锁词面选取与并集名次语义。
"""
import json
import tempfile
import unittest
from pathlib import Path

from eval_model_candidates import load_entity_terms, merge_candidates


class EntityTermsTests(unittest.TestCase):
    def test_name_priority_and_meta_skip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "entities.jsonl"
            rows = [
                {"_meta": {"dataVersion": "v1"}},
                {"entity_id": "e1", "region": "CN",
                 "names": {"name_zh": "规范甲", "short_name": "简称甲"}},
                {"entity_id": "e2", "region": "CN", "names": {"short_name": "简称乙"}},
                {"entity_id": "e3", "region": "CN", "names": {}},  # 无词面 → 跳过
            ]
            path.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n",
                            encoding="utf-8")
            terms = load_entity_terms(path)
            self.assertEqual(terms, [("e1", "规范甲"), ("e2", "简称乙")])


class MergeTests(unittest.TestCase):
    def _cand(self, eid, source, score=0.5):
        return {"entity_id": eid, "score": score, "matched_term": eid, "source": source}

    def test_rank1_is_model_and_engine_appended(self):
        model_top = [self._cand("m1", "model"), self._cand("m2", "model")]
        engine_top = [self._cand("m2", "engine"), self._cand("g1", "engine")]
        merged = merge_candidates(model_top, engine_top, k=2)
        self.assertEqual(merged[0]["entity_id"], "m1")
        self.assertEqual(merged[0]["source"], "model")
        self.assertEqual([c["entity_id"] for c in merged], ["m1", "m2", "g1"])  # 去重保名次

    def test_engine_never_promoted_above_model(self):
        model_top = [self._cand("m1", "model")]
        engine_top = [self._cand("g1", "engine"), self._cand("g2", "engine")]
        merged = merge_candidates(model_top, engine_top)
        self.assertEqual(merged[0]["source"], "model")

    def test_empty_model_falls_back_to_engine_order(self):
        merged = merge_candidates([], [self._cand("g1", "engine")], k=10)
        self.assertEqual([c["entity_id"] for c in merged], ["g1"])


if __name__ == "__main__":
    unittest.main()
