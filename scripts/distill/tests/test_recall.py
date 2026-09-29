"""RecallEngine:分层命中与确定性(无 pypinyin 环境自动缺位 L2/L3)。"""
import unittest

from entlink.catalog import load_jsonl_set
from entlink.recall import RecallEngine

from tests.util import write_jsonl as _write_jsonl


class RecallTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        paths = {
            "drug": _write_jsonl([
                {"region": "CN", "source_id": "d1", "name_zh": "阿莫西林胶囊", "aliases": ["阿莫西林", "Amoxicillin"]},
                {"region": "CN", "source_id": "d2", "name_zh": "阿莫西林克拉维酸钾片"},
                {"region": "TW", "source_id": "d3", "name_zh": "安莫西林膠囊"},
            ]),
            "hospital": _write_jsonl([
                {"region": "HK", "source_id": "h1", "name_zh": "香港大學深圳醫院", "short_name": "港大深圳醫院",
                 "aliases": ["港大医院"]},
            ]),
            "department": _write_jsonl([
                {"region": "TW", "source_id": "dep1", "name_zh": "內科", "aliases": ["内科"]},
            ]),
            "exam": _write_jsonl([
                {"region": "CN", "source_id": "ex1", "name_zh": "血常规", "aliases": ["血常規", "CBC"]},
            ]),
        }
        cls.engine = RecallEngine().build(load_jsonl_set(paths, data_version="t"))

    def test_exact_name_hit(self):
        hits = self.engine.search("阿莫西林胶囊", top_k=3)
        self.assertEqual(hits[0].entity_id, "d1")
        self.assertEqual(hits[0].layer, "exact")
        self.assertEqual(hits[0].score, 1.0)

    def test_alias_hit(self):
        hits = self.engine.search("阿莫西林")
        self.assertEqual(hits[0].entity_id, "d1")
        self.assertEqual(hits[0].layer, "alias")

    def test_english_alias(self):
        hits = self.engine.search("Amoxicillin")
        self.assertEqual(hits[0].entity_id, "d1")

    def test_fuzzy_edit_one(self):
        hits = self.engine.search("阿莫西林胶囊")  # exact 之外还有候选
        self.assertEqual(hits[0].entity_id, "d1")
        hits = self.engine.search("阿莫西林胶襄")  # 囊→襄 形近(不在表内,靠 edit distance)
        self.assertEqual(hits[0].entity_id, "d1")
        self.assertEqual(hits[0].layer, "fuzzy")
        self.assertEqual(hits[0].dist, 1)

    def test_variant_alias_region(self):
        # 繁简查询经由 TW 行的繁体名或别名命中(依赖别名表,不依赖转换层)
        hits = self.engine.search("内科")
        self.assertEqual(hits[0].entity_id, "dep1")
        self.assertEqual(hits[0].layer, "alias")

    def test_domain_filter(self):
        hits = self.engine.search("阿莫西林", domain="hospital", top_k=5)
        self.assertEqual(hits, [])
        hits = self.engine.search("阿莫西林", domain="drug")
        self.assertEqual(hits[0].entity_id, "d1")

    def test_deterministic(self):
        first = self.engine.search("阿莫西林", top_k=10)
        for _ in range(3):
            self.assertEqual(self.engine.search("阿莫西林", top_k=10), first)

    def test_empty_query(self):
        self.assertEqual(self.engine.search(""), [])

    def test_describe(self):
        desc = self.engine.describe()
        self.assertEqual(desc["entities"], {"drug": 3, "hospital": 1, "department": 1, "exam": 1})
        self.assertIn("pinyin_available", desc)
        self.assertEqual(desc["max_edit"], 2)

    def test_rebuild_clears_previous_index(self):
        # 回归:同实例二次 build 须清空旧域索引(曾残留 drug 域造成跨目录串档)
        engine = RecallEngine()
        engine.build(load_jsonl_set({
            "drug": _write_jsonl([{"region": "CN", "source_id": "d1", "name_zh": "阿莫西林胶囊"}]),
        }, data_version="t"))
        engine.build(load_jsonl_set({
            "hospital": _write_jsonl([{"region": "HK", "source_id": "h1", "name_zh": "香港大學深圳醫院"}]),
        }, data_version="t"))
        self.assertEqual(engine.describe()["domains"], ["hospital"])
        self.assertEqual(engine.search("阿莫西林胶囊", domain="drug"), [])


if __name__ == "__main__":
    unittest.main()
