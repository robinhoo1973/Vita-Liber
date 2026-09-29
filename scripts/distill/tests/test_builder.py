"""corpus.builder:冻结 JSONL + manifest 全链、金标守卫、实体级切分。"""
import json
import tempfile
import unittest
from pathlib import Path

from corpus.builder import BuildConfig, build_corpus
from corpus.manifest import verify_manifest
from entlink.catalog import load_jsonl_set

from tests.util import write_jsonl as _write_jsonl


def _tiny_catalog(n_drugs=24):
    """构造满足 --min-eval-entities 下限的小目录(默认 24 药 + 少量他域)。"""
    drugs = []
    for i in range(n_drugs):
        drugs.append({"region": "CN", "source_id": f"d{i}", "name_zh": f"测试药品{i}胶囊",
                      "aliases": [f"药品{i}", f"drug{i}"]})
    return load_jsonl_set({
        "drug": _write_jsonl(drugs),
        "hospital": _write_jsonl([{"region": "HK", "source_id": f"h{i}", "name_zh": f"香港測試醫院{i}",
                                   "short_name": f"港大医院{i}", "aliases": [f"test hospital {i}"]} for i in range(24)]),
        "department": _write_jsonl([{"region": "TW", "source_id": f"dep{i}", "name_zh": f"综合内科科室{i}",
                                     "aliases": [f"内科{i}诊室"]} for i in range(24)]),
        "exam": _write_jsonl([{"region": "CN", "source_id": f"ex{i}", "name_zh": f"实验室检查项目{i}",
                               "aliases": [f"检验项目{i}"]} for i in range(24)]),
    }, data_version="test-v1")


class BuilderTests(unittest.TestCase):
    def test_end_to_end_frozen(self):
        catalog = _tiny_catalog()
        out = Path(tempfile.mkdtemp()) / "corpus.jsonl"
        config = BuildConfig(master_seed=1, split_ratio=0.85, min_eval_entities=2, negatives_per_sample=2)
        report = build_corpus(catalog, out, config)
        manifest = verify_manifest(out.with_suffix(".jsonl.manifest.json"), out)
        self.assertIn("TFDA", json.dumps(manifest["licenses"]))
        self.assertIn("noise_model_sha256", manifest["noise_model"])
        lines = [json.loads(l) for l in out.read_text(encoding="utf-8").splitlines()]
        self.assertGreater(len(lines), 0)
        domains = {l["domain"] for l in lines}
        self.assertEqual(domains, {"drug", "hospital", "department", "exam"})
        splits = {l["split"] for l in lines}
        self.assertEqual(splits, {"train", "eval"})
        # 每行金标与负例隔离
        for l in lines:
            self.assertNotIn(l["gold"]["entity_id"], [n["entity_id"] for n in l["negatives"]])
        # 同实体别名同落一侧(实体级切分)
        by_entity: dict[str, set[str]] = {}
        for l in lines:
            by_entity.setdefault(l["gold"]["entity_id"], set()).add(l["split"])
        for eid, s in by_entity.items():
            self.assertEqual(len(s), 1, f"实体 {eid} 跨 train/eval 泄漏")
        self.assertEqual(report.manifest["corpus_sha256"], manifest["corpus_sha256"])

    def test_collision_guard_drops_ambiguous(self):
        # 两个实体互为别名(恶意重叠)→ 加噪后命中他实体的样本被重掷/丢弃,不留歧义金标
        catalog = load_jsonl_set({
            "drug": _write_jsonl([
                {"region": "CN", "source_id": "d0", "name_zh": "甲药胶囊", "aliases": ["甲乙"]},
                {"region": "CN", "source_id": "d1", "name_zh": "乙药胶囊", "aliases": ["甲乙"]},
            ] + [{"region": "CN", "source_id": f"d{i}", "name_zh": f"药品{i}胶囊",
                  "aliases": [f"药品{i}别名"]} for i in range(2, 24)]),
        }, data_version="t")
        out = Path(tempfile.mkdtemp()) / "corpus.jsonl"
        report = build_corpus(catalog, out, BuildConfig(min_eval_entities=2, split_ratio=0.85))
        # 守卫契约:任何 query 折叠后不得归他实体所有(歧义金标=0)
        from entlink.fold import fold as _fold
        owners: dict[str, set[str]] = {}
        for e in catalog.entities:
            owners.setdefault(_fold(e.names.get("name_zh", "")), set()).add(e.entity_id)
            for a in e.aliases:
                owners.setdefault(_fold(a), set()).add(e.entity_id)
        owners.pop("", None)
        n = 0
        for l in out.read_text(encoding="utf-8").splitlines():
            row = json.loads(l)
            holders = owners.get(_fold(row["query"]), set())
            self.assertFalse(holders - {row["gold"]["entity_id"]},
                             f"歧义金标残留: {row}")
            n += 1
        self.assertGreater(n, 0)

    def test_min_eval_entities_fails_closed(self):
        catalog = _tiny_catalog(n_drugs=3)
        out = Path(tempfile.mkdtemp()) / "corpus.jsonl"
        with self.assertRaises(ValueError):
            build_corpus(catalog, out, BuildConfig(min_eval_entities=5))

    def test_collision_guard_covers_english_names(self):
        # 回归:金标守卫须覆盖 name_en/short_name——别名加噪后折叠命中他实体
        # 英文名同样属歧义金标,必须重掷/丢弃(旧实现 _owner_map 只登记
        # name_zh+别名,同名英文名歧义曾漏过守卫)
        catalog = load_jsonl_set({
            "drug": _write_jsonl([
                {"region": "CN", "source_id": "d0", "name_zh": "甲药胶囊", "aliases": ["Amoxicillin"]},
                {"region": "CN", "source_id": "d1", "name_zh": "乙药胶囊", "name_en": "Amoxicillin"},
            ] + [{"region": "CN", "source_id": f"d{i}", "name_zh": f"药品{i}胶囊",
                  "aliases": [f"药品{i}别名"]} for i in range(2, 24)]),
        }, data_version="t")
        out = Path(tempfile.mkdtemp()) / "corpus.jsonl"
        build_corpus(catalog, out, BuildConfig(min_eval_entities=2, split_ratio=0.85))
        from entlink.fold import fold as _fold
        owners: dict[str, set[str]] = {}
        for e in catalog.entities:
            for v in e.names.values():
                owners.setdefault(_fold(v), set()).add(e.entity_id)
            for a in e.aliases:
                owners.setdefault(_fold(a), set()).add(e.entity_id)
        owners.pop("", None)
        rows = [json.loads(l) for l in out.read_text(encoding="utf-8").splitlines()]
        self.assertGreater(len(rows), 0)
        for row in rows:
            holders = owners.get(_fold(row["query"]), set())
            self.assertFalse(holders - {row["gold"]["entity_id"]},
                             f"歧义金标残留: {row}")

    def test_company_suffix_alias_filtered(self):
        catalog = load_jsonl_set({
            "hospital": _write_jsonl([
                {"region": "HK", "source_id": "h0", "name_zh": "測試醫院",
                 "aliases": ["測試醫院有限公司", "測試醫院"]},
            ] + [{"region": "HK", "source_id": f"h{i}", "name_zh": f"醫院{i}", "aliases": [f"h{i}"]} for i in range(1, 13)]),
        }, data_version="t")
        out = Path(tempfile.mkdtemp()) / "corpus.jsonl"
        build_corpus(catalog, out, BuildConfig(min_eval_entities=1, split_ratio=0.5))
        queries = [json.loads(l)["query"] for l in out.read_text(encoding="utf-8").splitlines()]
        self.assertFalse(any("有限公司" in q for q in queries))


if __name__ == "__main__":
    unittest.main()
