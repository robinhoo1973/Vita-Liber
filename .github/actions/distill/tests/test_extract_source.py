"""extract.catalog_source:目录 SQLite → data-dir 物化契约(逐文件 schema)。"""
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from extract.catalog_source import materialize


def _make_fixture() -> Path:
    tmp = Path(tempfile.mkdtemp()) / "catalog.sqlite"
    conn = sqlite3.connect(tmp)
    conn.executescript("""
    CREATE TABLE catalog_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
    CREATE TABLE drug (region TEXT NOT NULL, source_id TEXT NOT NULL UNIQUE, name_zh TEXT, name_en TEXT,
        dosage_form TEXT, spec TEXT, region_specific_json TEXT NOT NULL, aliases_json TEXT NOT NULL);
    CREATE TABLE drug_detail (region TEXT NOT NULL, source_id TEXT NOT NULL, usage_text TEXT, indications TEXT);
    CREATE TABLE hospital (region TEXT NOT NULL, source_id TEXT NOT NULL UNIQUE, name_zh TEXT NOT NULL,
        type_zh TEXT, level_zh TEXT, admin_area TEXT, depts_json TEXT NOT NULL);
    CREATE TABLE department (region TEXT NOT NULL, source_id TEXT NOT NULL UNIQUE, name_zh TEXT NOT NULL,
        category_zh TEXT);
    CREATE TABLE diagnosis (region TEXT NOT NULL, source_id TEXT NOT NULL UNIQUE, name_zh TEXT NOT NULL,
        chapter_zh TEXT);
    CREATE TABLE exam_item (region TEXT NOT NULL, source_id TEXT NOT NULL UNIQUE, name_zh TEXT NOT NULL,
        name_en TEXT, category TEXT, specimen TEXT, unit TEXT);
    """)
    conn.execute("INSERT INTO catalog_meta VALUES ('schema_version','7'),('data_version','v7-fixture')")
    conn.executemany(
        "INSERT INTO drug (region, source_id, name_zh, name_en, dosage_form, spec, region_specific_json, aliases_json) "
        "VALUES (?,?,?,?,?,?,?,?)",
        [("CN", "CN-NHSA-XA01", "阿司匹林肠溶片", "", "肠溶片", "100mg", "{}",
          '[{"text":"阿司匹林","type":"base_zh"}]'),
         ("CN", "CN-YIB-TP-1", "牛黄清感胶囊", "", "", "", "{\"insurance_class\":\"乙\"}",
          '[{"text":"牛黄清感胶囊","type":"full_zh"}]'),
         ("TW", "衛署藥製字第04號", "蘇打錠500毫克", "", "錠劑", "塑膠瓶裝", "{}", "[]"),
         ("HK", "HK-1", "", "PANADOL TABLET", "Tablet", "500mg", "{}", "[]")])
    conn.execute("INSERT INTO drug_detail VALUES ('CN','CN-NHSA-XA01','口服。一次1片,一日1次','用于解热镇痛')")
    conn.execute("INSERT INTO drug_detail VALUES ('CN','CN-YIB-TP-1','','用于感冒')")
    conn.execute("INSERT INTO hospital (region, source_id, name_zh, type_zh, level_zh, admin_area, depts_json) "
                 "VALUES ('TW','H1','高雄市立民生醫院','綜合醫院','區域醫院','高雄市','[{\"name_zh\":\"家醫科\"},{\"name_zh\":\"內科\"}]')")
    conn.execute("INSERT INTO department VALUES ('CN','DEP1','内科','内科')")
    conn.execute("INSERT INTO diagnosis VALUES ('CN','R05','咳嗽','症状、体征和临床与实验室异常所见')")
    conn.execute("INSERT INTO exam_item VALUES ('TW','E1','血球計數檢查',NULL,'檢查','血液',NULL)")
    conn.commit()
    conn.close()
    return tmp


class MaterializeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp())
        cls.out = cls.tmp / "data"
        cls.catalog = _make_fixture()
        cls.descriptor = materialize(cls.catalog, cls.out)
        # 血缘清单由 CLI 层写(与生产同路径):用 subprocess 跑一次完整入口
        import subprocess, sys
        result = subprocess.run(
            [sys.executable, str(Path(__file__).resolve().parents[1] / "extract" / "catalog_source.py"),
             "--catalog-sqlite", str(cls.catalog), "--out-dir", str(cls.out)],
            capture_output=True, text=True, timeout=120)
        cls.cli_rc, cls.cli_err = result.returncode, result.stderr

    def _lines(self, rel):
        return [json.loads(l) for l in (self.out / rel).read_text(encoding="utf-8").splitlines() if l.strip()]

    def test_drug_splits_and_fields(self):
        cn = self._lines("drugs_cn.jsonl")
        nhsa = self._lines("drugs_nhsa.jsonl")
        tw = self._lines("tw_records.jsonl")
        hk = self._lines("hk_records.jsonl")
        self.assertEqual(len(cn), 1)          # 非 NHSA 的 CN 行
        self.assertEqual(cn[0]["name_zh"], "牛黄清感胶囊")
        self.assertEqual(nhsa[0]["region_specific"], {"spec": "100mg", "dosage_form": "肠溶片"})
        self.assertEqual(tw[0]["usage_text"], "")  # TW 无 detail 行
        self.assertEqual(tw[0]["source_id"], "衛署藥製字第04號")
        self.assertEqual(hk[0]["name_en"], "PANADOL TABLET")   # HK 英文名回落

    def test_details_and_index(self):
        details = self._lines("medical_details.jsonl")
        self.assertEqual(len(details), 2)
        index = json.loads((self.out / "medical_index.json").read_text(encoding="utf-8"))["index"]
        self.assertIn("阿司匹林", index)          # 对象形态别名解析
        self.assertIn("阿司匹林肠溶片", index)     # 主名并入
        self.assertEqual(index["阿司匹林"], ["CN-NHSA-XA01"])

    def test_ref_files_with_region_lowercase(self):
        hospitals = self._lines("ref/hospital_tw.jsonl")
        self.assertEqual(hospitals[0]["depts"][0]["name_zh"], "家醫科")
        diagnoses = self._lines("ref/diagnosis_cn.jsonl")
        self.assertEqual(diagnoses[0]["name_zh"], "咳嗽")
        self.assertEqual((self.out / "ref/exam_hk.jsonl").read_text(encoding="utf-8"), "")  # 空文件=该格兜底

    def test_facts_subtree(self):
        drugs = self._lines("facts/drug.jsonl")
        asp = [d for d in drugs if d["name"] == "阿司匹林肠溶片"][0]
        self.assertEqual(asp["usage"], "口服。一次1片,一日1次")
        diagnosis = self._lines("facts/diagnosis.jsonl")
        self.assertEqual(diagnosis[0]["chapter"], "症状、体征和临床与实验室异常所见")

    def test_training_feed_manifest_written(self):
        self.assertEqual(self.cli_rc, 0, msg=self.cli_err)
        feed = json.loads((self.out / "training_feed_manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(feed["mode"], "cnb-catalog-materialized")
        self.assertEqual(feed["catalog"]["catalog_data_version"], "v7-fixture")
        self.assertIn("drugs_cn.jsonl", feed["files"])


if __name__ == "__main__":
    unittest.main()
