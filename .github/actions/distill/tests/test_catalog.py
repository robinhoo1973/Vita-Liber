"""catalog 装载:JSONL 契约与 SQLite v4 适配器(含 schema 闸 fail-closed)。"""
import unittest
import tempfile
from pathlib import Path

from entlink.catalog import Entity, load_jsonl, load_sqlite_v4

from tests.util import make_v4_sqlite, write_jsonl as _write_jsonl


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
        # App 侧安装器同口径:物理 v5/v6 接受(投影列同形),v7+ 拒绝
        self.assertEqual(load_sqlite_v4(make_v4_sqlite(schema_version="5")).stats()["drug"], 1)
        self.assertEqual(load_sqlite_v4(make_v4_sqlite(schema_version="6")).stats()["drug"], 1)

    def test_unsupported_schema_fails_closed(self):
        with self.assertRaises(ValueError):
            load_sqlite_v4(make_v4_sqlite(schema_version="7"))

    def test_missing_file(self):
        with self.assertRaises(FileNotFoundError):
            load_sqlite_v4(Path(tempfile.mkdtemp()) / "nope.sqlite")


if __name__ == "__main__":
    unittest.main()
