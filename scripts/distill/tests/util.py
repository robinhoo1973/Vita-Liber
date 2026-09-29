"""测试共用夹具:JSONL 目录与 v4 SQLite 构造。"""
import json
import sqlite3
import tempfile
from pathlib import Path


def write_jsonl(rows):
    tmp = Path(tempfile.mkdtemp()) / "catalog.jsonl"
    tmp.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows), encoding="utf-8")
    return tmp


def make_v4_sqlite(schema_version="4", data_version="2026.09.29"):
    tmp = Path(tempfile.mkdtemp()) / "catalog.sqlite"
    conn = sqlite3.connect(tmp)
    conn.executescript("""
    CREATE TABLE catalog_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
    CREATE TABLE drug (id INTEGER PRIMARY KEY, region TEXT NOT NULL, source_id TEXT NOT NULL UNIQUE,
        license_no TEXT, name_zh TEXT, name_en TEXT, brand_name TEXT, dosage_form TEXT, spec TEXT,
        drug_category TEXT, license_holder TEXT, manufacturer TEXT, insurance_code TEXT, drug_code TEXT,
        active_ingredients TEXT, usage_ref_json TEXT NOT NULL, region_specific_json TEXT NOT NULL, aliases_json TEXT NOT NULL);
    CREATE TABLE hospital (region TEXT NOT NULL, source_id TEXT NOT NULL UNIQUE, code TEXT, name_zh TEXT NOT NULL,
        short_name TEXT, type_zh TEXT, level_zh TEXT, address TEXT, phone TEXT, admin_area TEXT,
        depts_json TEXT NOT NULL, aliases_json TEXT NOT NULL, match_status TEXT);
    CREATE TABLE department (region TEXT NOT NULL, source_id TEXT NOT NULL UNIQUE, code TEXT NOT NULL,
        name_zh TEXT NOT NULL, category_zh TEXT, aliases_json TEXT NOT NULL, match_status TEXT);
    CREATE TABLE exam_item (region TEXT NOT NULL, source_id TEXT NOT NULL UNIQUE, code TEXT NOT NULL,
        name_zh TEXT NOT NULL, name_en TEXT, category TEXT, method TEXT, specimen TEXT, unit TEXT,
        price_ref TEXT, loinc_concept_id TEXT, aliases_json TEXT NOT NULL, match_status TEXT);
    """)
    conn.execute("INSERT INTO catalog_meta VALUES ('schema_version', ?), ('data_version', ?)",
                 (schema_version, data_version))
    conn.execute("INSERT INTO drug (region, source_id, name_zh, usage_ref_json, region_specific_json, aliases_json) "
                 "VALUES ('CN','d1','阿莫西林胶囊','{}','{}','[\"阿莫西林\",\"Amoxicillin\"]')")
    conn.execute("INSERT INTO hospital (region, source_id, name_zh, short_name, depts_json, aliases_json, match_status) "
                 "VALUES ('HK','h1','香港大學深圳醫院','港大深圳醫院','[]','[\"港大医院\"]','exact')")
    conn.execute("INSERT INTO department (region, source_id, code, name_zh, aliases_json, match_status) "
                 "VALUES ('TW','dep1','02','內科','[\"内科\"]','exact')")
    conn.execute("INSERT INTO exam_item (region, source_id, code, name_zh, aliases_json, match_status) "
                 "VALUES ('CN','ex1','250203','血常规','[\"血常規\",\"CBC\"]','exact')")
    conn.commit()
    conn.close()
    return tmp
