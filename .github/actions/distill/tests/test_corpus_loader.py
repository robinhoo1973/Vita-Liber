"""train.corpus_loader 负例装载负测(2026-10-08 TE 批;stdlib 可跑)。

覆盖:全量扫描(含 eval 行)、canonical 优先、缺失计数、冲突占比统计。
torch 路径(损失拼接/掩蔽)由 smoke-encoder 的 --negatives corpus 短冒烟覆盖。
"""
import json
import tempfile
import unittest
from pathlib import Path

from train.corpus_loader import load_negative_terms, negative_terms_for_samples


def _row(qid, eid, term, kind, split, negatives):
    return {"id": qid, "query": "q", "split": split,
            "gold": {"entity_id": eid, "term": term, "kind": kind},
            "negatives": negatives}


class NegativeTermsTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.corpus = Path(self._tmp.name) / "corpus.jsonl"
        rows = [
            # 同实体先出别名后出规范名:canonical 必须获胜
            _row("s1", "e1", "别名甲", "alias", "train",
                 [{"entity_id": "e2", "hard": False}, {"entity_id": "e9", "hard": False}]),
            _row("s2", "e2", "规范乙", "canonical", "train",
                 [{"entity_id": "e1", "hard": True}]),
            _row("s3", "e1", "规范甲", "canonical", "eval",
                 [{"entity_id": "e2", "hard": False}]),
            # eval 行里的 e3 词面必须可被训练样本解析(全量扫描纪律)
            _row("s4", "e3", "规范丙", "canonical", "eval", []),
        ]
        self.corpus.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n",
                               encoding="utf-8")

    def tearDown(self):
        self._tmp.cleanup()

    def test_load_prefers_canonical_and_scans_all_splits(self):
        terms = load_negative_terms(self.corpus)
        self.assertEqual(terms["e1"], "规范甲")
        self.assertEqual(terms["e3"], "规范丙")

    def test_negative_terms_stats(self):
        terms = load_negative_terms(self.corpus)
        train_rows = [
            {"gold": {"entity_id": "e1"}, "negatives": [{"entity_id": "e2", "hard": False},
                                                        {"entity_id": "e9", "hard": False}]},
            {"gold": {"entity_id": "e2"}, "negatives": [{"entity_id": "e1", "hard": True}]},
            {"gold": {"entity_id": "e3"}, "negatives": []},
        ]
        per_sample, stats = negative_terms_for_samples(train_rows, terms)
        self.assertEqual(per_sample[0], ["规范乙"])  # e9 未收录 → 缺失计数
        self.assertEqual(per_sample[1], ["规范甲"])
        self.assertEqual(per_sample[2], [])
        self.assertEqual(stats["neg_resolve_missing"], 1)
        self.assertAlmostEqual(stats["conflict_share"], 1 / 3, places=4)

    def test_missing_entity_id_is_skipped(self):
        per_sample, stats = negative_terms_for_samples(
            [{"gold": {"entity_id": "x"}, "negatives": [{"entity_id": None, "hard": False}]}],
            {})
        self.assertEqual(per_sample, [[]])
        self.assertEqual(stats["neg_resolve_missing"], 1)

    def test_negative_terms_entities_fallback(self):
        # R0 修复:负例按全实体表抽样,语料 gold 受 caps 截断——entities.jsonl 回退源
        # 必须解析语料中从未出现为 gold 的 entity_id(实测缺失率 6.5%→0)
        import json as _json
        import tempfile as _tempfile
        from pathlib import Path as _Path
        from train.corpus_loader import load_negative_terms
        tmp = _Path(_tempfile.mkdtemp())
        corpus = tmp / "corpus.jsonl"
        corpus.write_text(_json.dumps({"gold": {"entity_id": "D1", "term": "阿司匹林",
                                                "kind": "canonical"}}, ensure_ascii=False) + "\n",
                          encoding="utf-8")
        ents = tmp / "entities.jsonl"
        ents.write_text(
            _json.dumps({"_meta": {"data_version": "x"}}, ensure_ascii=False) + "\n" +
            _json.dumps({"domain": "drug", "entity_id": "D1", "region": "CN",
                         "names": {"name_zh": "阿司匹林"}, "aliases": []}, ensure_ascii=False) + "\n" +
            _json.dumps({"domain": "drug", "entity_id": "D2", "region": "CN",
                         "names": {"name_zh": "布洛芬"}, "aliases": []}, ensure_ascii=False) + "\n",
            encoding="utf-8")
        only_corpus = load_negative_terms(corpus)
        self.assertNotIn("D2", only_corpus)
        with_entities = load_negative_terms(corpus, ents)
        self.assertEqual(with_entities.get("D2"), "布洛芬")
        self.assertEqual(with_entities.get("D1"), "阿司匹林")   # 语料 gold 词面优先


if __name__ == "__main__":
    unittest.main()
