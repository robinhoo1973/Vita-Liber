"""catalog 装载:JSONL 契约与 SQLite v4 适配器(含 schema 闸 fail-closed)。"""
import json
import unittest
import tempfile
from pathlib import Path

from entlink.catalog import Entity, load_entities_dump, load_jsonl, load_sqlite_v4
from entlink.recall import RecallEngine

from tests.util import make_v4_sqlite, make_v7_duplicate_sqlite, write_jsonl as _write_jsonl


class JsonlTests(unittest.TestCase):
    def test_drug_rows(self):
        path = _write_jsonl([
            {"region": "CN", "source_id": "d1", "name_zh": "阿莫西林胶囊", "aliases": ["阿莫西林", "Amoxicillin"]},
            {"region": "TW", "source_id": "d2", "name_zh": "安莫西林膠囊", "name_en": "Amoxicillin"},
        ])
        catalog = load_jsonl(path, "drug", data_version="test")
        self.assertEqual(catalog.stats(), {"drug": 2})
        e1 = catalog.entities[0]
        self.assertIsInstance(e1, Entity)
        self.assertEqual(e1.names["name_zh"], "阿莫西林胶囊")
        self.assertEqual(e1.aliases, ("阿莫西林", "Amoxicillin"))

    def test_hospital_short_name(self):
        path = _write_jsonl([
            {"region": "HK", "source_id": "h1", "name_zh": "香港大學深圳醫院", "short_name": "港大深圳醫院"},
        ])
        catalog = load_jsonl(path, "hospital")
        self.assertIn("short_name", catalog.entities[0].names)

    def test_open_object_aliases_are_text_only_and_do_not_rewrite_jsonl(self):
        aliases = [
            {"text": " 藥品別名😀 ", "type": "future/open-type",
             "future": {"raw": [None, 9007199254740993]}},
            "舊字串別名",
            {"text": 7, "type": "base_zh"}, {"text": {"unexpected": "not a name"}},
            {"type": "unrecognized", "unknown": "not a name"}, None, True,
        ]
        for value in (aliases, json.dumps(aliases, ensure_ascii=False)):
            with self.subTest(encoded=isinstance(value, str)):
                path = _write_jsonl([{"source_id": "D1", "name_zh": "主名稱", "aliases": value}])
                before = path.read_bytes()
                catalog = load_jsonl(path, "drug")
                self.assertEqual(catalog.entities[0].aliases, ("藥品別名😀", "舊字串別名"))
                candidate = RecallEngine().build(catalog).search("藥品別名😀", domain="drug")[0]
                self.assertEqual((candidate.entity_id, candidate.layer), ("D1", "alias"))
                self.assertEqual(path.read_bytes(), before)

    def test_entity_dump_object_aliases_never_escape_as_dicts(self):
        path = _write_jsonl([
            {"_meta": {"data_version": "open-aliases"}},
            {"entity_id": "D1", "domain": "drug", "region": "TW", "names": {"name_zh": "主名稱"},
             "aliases": [{"text": "新版別名", "type": {"future": "open"}},
                         {"unknown": "not a name"}, {"text": None}, "舊別名"]},
        ])
        before = path.read_bytes()
        catalog = load_entities_dump(path)
        self.assertEqual(catalog.entities[0].aliases, ("新版別名", "舊別名"))
        self.assertEqual(path.read_bytes(), before)

    def test_bad_json_fails_loud(self):
        path = _write_jsonl([])
        path.write_text("{not json\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            load_jsonl(path, "drug")

    def test_no_name_fails_loud(self):
        path = _write_jsonl([{"source_id": "x"}])
        with self.assertRaises(ValueError):
            load_jsonl(path, "drug")

    def test_unknown_domain(self):
        with self.assertRaises(ValueError):
            load_jsonl(_write_jsonl([]), "nope")


class SqliteV4Tests(unittest.TestCase):
    def test_loads_four_domains(self):
        catalog = load_sqlite_v4(make_v4_sqlite())
        self.assertEqual(catalog.stats(), {"drug": 1, "hospital": 1, "department": 1, "exam": 1})
        self.assertEqual(catalog.data_version, "2026.09.29")
        drug = catalog.by_domain("drug")[0]
        self.assertEqual(drug.aliases, ("阿莫西林", "Amoxicillin"))
        self.assertEqual(catalog.by_domain("hospital")[0].match_status, "exact")

    def test_physical_v5_v6_accepted(self):
        # 历史投影:v5/v6 接受(投影列同形;无 diagnosis 表 = 该域零实体)
        self.assertEqual(load_sqlite_v4(make_v4_sqlite(schema_version="5")).stats()["drug"], 1)
        self.assertEqual(load_sqlite_v4(make_v4_sqlite(schema_version="6")).stats()["drug"], 1)

    def test_v7_accepted_with_diagnosis_domain(self):
        # v7(2026-10-06 生产发布)新增 diagnosis 域
        catalog = load_sqlite_v4(make_v4_sqlite(schema_version="7"))
        self.assertEqual(catalog.stats(), {"drug": 1, "hospital": 1, "department": 1, "exam": 1, "diagnosis": 1})
        diagnosis = catalog.by_domain("diagnosis")[0]
        self.assertEqual(diagnosis.names["name_zh"], "咳嗽")
        self.assertEqual(diagnosis.aliases, ("咳痰",))

    def test_v7_missing_diagnosis_table_fails_closed(self):
        # v7 缺表 = 投影漂移(旧版缺 diagnosis 不拒载;v7 起必须物化)
        with self.assertRaises(ValueError):
            load_sqlite_v4(make_v4_sqlite(schema_version="7", with_diagnosis=False))

    def test_unsupported_schema_fails_closed(self):
        with self.assertRaises(ValueError):
            load_sqlite_v4(make_v4_sqlite(schema_version="8"))

    def test_group_by_name_merges_rows(self):
        catalog = load_sqlite_v4(make_v7_duplicate_sqlite(), group_by_name=True)
        drugs = catalog.by_domain("drug")
        self.assertEqual(len(drugs), 1)
        merged = drugs[0]
        self.assertEqual(merged.entity_id, "CN-NHSA-B")   # 组内最小 source_id(定序)
        self.assertEqual(merged.names["name_zh"], "阿司匹林肠溶片")
        self.assertEqual(merged.aliases, ("阿司匹林", "拜阿司匹灵"))
        unmerged = load_sqlite_v4(make_v7_duplicate_sqlite(), group_by_name=False)
        self.assertEqual(len(unmerged.by_domain("drug")), 2)

    def test_missing_file(self):
        with self.assertRaises(FileNotFoundError):
            load_sqlite_v4(Path(tempfile.mkdtemp()) / "nope.sqlite")


if __name__ == "__main__":
    unittest.main()
