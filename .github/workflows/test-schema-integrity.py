#!/usr/bin/env python3
"""Execute the actual baseline DDL and the v23 rebuild against SQLite, without Apple SDKs."""
from pathlib import Path
import re
import sqlite3
import unittest
from contextlib import closing

ROOT = Path(__file__).resolve().parents[2]


def baseline():
    text = (ROOT / "CoreKit/Sources/Infrastructure/SchemaV2.swift").read_text()
    return re.search(r'static let ddl\s*=\s*"""(.*?)"""', text, re.S).group(1)


class SchemaIntegrityTests(unittest.TestCase):
    def test_fresh_database_creates_all_indexes_and_relationship_columns(self):
        with closing(sqlite3.connect(":memory:")) as db:
            db.execute("PRAGMA foreign_keys = ON")
            db.executescript(baseline())
            columns = {row[1] for row in db.execute("PRAGMA table_info(ocr_card_commit)")}
            self.assertIn("encounter_id", columns)
            self.assertEqual(list(db.execute("PRAGMA foreign_key_check")), [])
            self.assertIn("hk_import_status", {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")})

    def test_v23_preserves_v22_receipts_and_accepts_new_card_kinds(self):
        with closing(sqlite3.connect(":memory:")) as db:
            # GRDB registers this function on Apple. This test exercises schema/FKs, not the tokenizer.
            db.create_function("bigrams", 1, lambda value: " ".join((value or "")[i:i + 2] for i in range(max(0, len(value or "") - 1))))
            db.execute("PRAGMA foreign_keys = ON")
            db.executescript(baseline())
            db.execute("DROP TABLE ocr_card_commit")
            db.executescript("""
                CREATE TABLE ocr_card_commit (
                  card_id TEXT NOT NULL, row_id TEXT NOT NULL,
                  patient_id TEXT NOT NULL REFERENCES patient_profile(id),
                  document_file_id TEXT NOT NULL REFERENCES document_file(id), page_index INTEGER NOT NULL,
                  card_kind TEXT NOT NULL CHECK(card_kind IN ('metric_sample','encounter','prescription')),
                  entity_id TEXT NOT NULL, created_at REAL NOT NULL, PRIMARY KEY(card_id,row_id),
                  FOREIGN KEY(document_file_id,page_index) REFERENCES document_page(document_file_id,page_index));
                INSERT INTO patient_profile (id,display_name,relation,created_at,updated_at) VALUES ('p','Owner','self',0,0);
                INSERT INTO document_file (id,patient_id,doc_type,sha256,mime_type,origin,created_at,updated_at)
                  VALUES ('d','p','record','hash','image/png','camera',0,0);
                INSERT INTO document_page (id,document_file_id,page_index,status,created_at) VALUES ('pg','d',0,'ok',0);
                INSERT INTO encounter (id,patient_id,date,kind,created_at,updated_at) VALUES ('e','p',0,'outpatient',0,0);
                INSERT INTO ocr_card_commit VALUES ('c','r','p','d',0,'encounter','e',0);
                """)
            text = (ROOT / "CoreKit/Sources/Infrastructure/SchemaMigrations.swift").read_text()
            migration = re.search(r'Step\(version: 23,.*?sql:\s*"""(.*?)"""', text, re.S).group(1)
            db.executescript("BEGIN;" + migration + "PRAGMA user_version=23; COMMIT;")
            self.assertEqual(db.execute("SELECT card_id,row_id,encounter_id FROM ocr_card_commit").fetchall(), [("c", "r", None)])
            db.execute("INSERT INTO ocr_card_commit VALUES ('c2','r2','p','d',0,'claim_item','receipt','e',0)")
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("INSERT INTO ocr_card_commit VALUES ('c3','r3','p','d',0,'medication','m','missing',0)")

    # 子项目 D · D1-1（discussions/2026-09-13-hospital-card-schema-round1 §D.1/§D.4）：
    # 冻结的 v24 基线夹具 + v25 SQL 步 = 全新库基线（pragma_table_info 逐表相等）；
    # ocr_card_commit 重建搬运无损、entity_table = card_kind；新表成员隔离 FK 生效。
    # 回填为 Swift 代码步（GRDBStore.backfillRecognitionFactLines），由 CoreKit
    # SchemaV25GoldenTests 在 macOS 覆盖；本测试只复核 SQL 半场（Linux 可跑）。
    TABLES_V25 = ["encounter", "prescription", "prescription_line", "claim_item", "claim_line",
                  "document_file", "stock_lot", "ocr_card_commit"]

    @staticmethod
    def columns(db, table):
        return sorted((r[1], r[2], r[3], r[4], r[5]) for r in db.execute(f"PRAGMA table_info({table})"))

    @staticmethod
    def statements(sql):
        # v25 步无触发器体、字面量内无分号——按分号切分即语句边界（与 SchemaMigrations.statements 同结果）。
        return [s.strip() for s in sql.split(";") if s.strip()]

    def test_v25_upgrades_frozen_v24_baseline_to_fresh_baseline_and_preserves_receipts(self):
        fixture = (ROOT / "CoreKit/Tests/CoreKitTests/Fixtures/schema_v24_baseline.sql").read_text()
        text = (ROOT / "CoreKit/Sources/Infrastructure/SchemaMigrations.swift").read_text()
        step = re.search(r'Step\(version: 25,.*?sql:\s*"""(.*?)"""', text, re.S)
        self.assertIsNotNone(step, "v25 recognition-fact-lines 迁移步缺失")
        migration = step.group(1)
        bigrams = lambda value: " ".join((value or "")[i:i + 2] for i in range(max(0, len(value or "") - 1)))
        with closing(sqlite3.connect(":memory:")) as legacy, closing(sqlite3.connect(":memory:")) as fresh:
            for db in (legacy, fresh):
                db.create_function("bigrams", 1, bigrams)
                db.execute("PRAGMA foreign_keys = ON")
            fresh.executescript(baseline())
            legacy.executescript(fixture)
            legacy.execute("PRAGMA user_version = 24")
            legacy.executescript("""
                INSERT INTO patient_profile (id,display_name,relation,created_at,updated_at) VALUES ('p','Owner','self',0,0);
                INSERT INTO document_file (id,patient_id,doc_type,sha256,mime_type,origin,created_at,updated_at)
                  VALUES ('d','p','处方单','hash','image/png','import',0,0);
                INSERT INTO document_page (id,document_file_id,page_index,status,created_at) VALUES ('pg','d',0,'ok',0);
                INSERT INTO prescription (id,patient_id,document_file_id,source,prescribed_at,advice_text,confirmed,created_at,updated_at)
                  VALUES ('rx','p','d','ocr',0,'Drug A 0.5g',1,0,0);
                INSERT INTO ocr_card_commit (card_id,row_id,patient_id,document_file_id,page_index,card_kind,entity_id,encounter_id,created_at)
                  VALUES ('c','r','p','d',0,'prescription','rx',NULL,1);
                """)
            # runner（GRDBStore.migrateIncremental）在事务外关闭外键、表重建步单事务执行
            legacy.execute("PRAGMA foreign_keys = OFF")
            legacy.executescript("BEGIN;" + migration + "PRAGMA user_version = 25; COMMIT;")
            legacy.execute("PRAGMA foreign_keys = ON")
            for table in self.TABLES_V25:
                self.assertEqual(self.columns(legacy, table), self.columns(fresh, table), f"{table}: 老库逐步升级 ≠ 全新库基线")
            self.assertEqual(legacy.execute("PRAGMA user_version").fetchone()[0], 25)
            self.assertEqual(list(legacy.execute("PRAGMA foreign_key_check")), [])
            self.assertEqual(legacy.execute("SELECT card_id,row_id,card_kind,entity_table,entity_id,encounter_id FROM ocr_card_commit").fetchall(),
                             [("c", "r", "prescription", "prescription", "rx", None)], "搬运无损且 entity_table = card_kind")
            self.assertEqual(legacy.execute("SELECT advice_text FROM prescription WHERE id='rx'").fetchone(), ("Drug A 0.5g",), "advice_text 原样保留")
            indexes = {r[0] for r in legacy.execute("SELECT name FROM sqlite_master WHERE type='index'")}
            for name in ("idx_ocr_card_commit_source", "idx_ocr_card_commit_entity", "idx_ocr_card_commit_encounter",
                         "idx_ocr_card_commit_entity_table", "idx_prescription_line_patient", "idx_claim_line_patient"):
                self.assertIn(name, indexes)
            # entity_table 枚举一次列全 D1–D3：行表可写、未知表名被 CHECK 拒绝
            legacy.execute("INSERT INTO prescription_line (id,prescription_id,patient_id,ordinal,printed_name,dose_text,dose_unit,confirmed,created_at,updated_at)"
                           " VALUES ('l0','rx','p',0,'Drug A','0.5','g',1,0,0)")
            legacy.execute("INSERT INTO ocr_card_commit VALUES ('c','r2','p','d',0,'prescription','prescription_line','l0',NULL,2)")
            with self.assertRaises(sqlite3.IntegrityError):
                legacy.execute("INSERT INTO ocr_card_commit VALUES ('c','r3','p','d',0,'prescription','bogus_table','l0',NULL,3)")
            # 成员隔离：行表 patient_id 悬空被拒；UNIQUE(prescription_id, ordinal) 生效
            with self.assertRaises(sqlite3.IntegrityError):
                legacy.execute("INSERT INTO prescription_line (id,prescription_id,patient_id,ordinal,printed_name,confirmed,created_at,updated_at)"
                               " VALUES ('l9','rx','ghost',9,'X',1,0,0)")
            with self.assertRaises(sqlite3.IntegrityError):
                legacy.execute("INSERT INTO prescription_line (id,prescription_id,patient_id,ordinal,printed_name,confirmed,created_at,updated_at)"
                               " VALUES ('l1','rx','p',0,'Dup',1,0,0)")
            legacy.execute("INSERT INTO claim_item (id,patient_id,item_type,confirmed,created_at,updated_at) VALUES ('ci','p','fee',1,0,0)")
            legacy.execute("INSERT INTO claim_line (id,claim_item_id,patient_id,ordinal,item_name,created_at) VALUES ('cl','ci','p',0,'挂号费',0)")
            with self.assertRaises(sqlite3.IntegrityError):
                legacy.execute("INSERT INTO claim_line (id,claim_item_id,patient_id,ordinal,item_name,created_at) VALUES ('cl2','missing','p',1,'X',0)")
            # BR-006/007：剂量/数量为文本 + 单位列，表内无 REAL 剂量列
            line_types = {r[1]: r[2] for r in legacy.execute("PRAGMA table_info(prescription_line)")}
            for column in ("dose_text", "dose_unit", "quantity_text", "quantity_unit", "frequency_text", "duration_text"):
                self.assertEqual(line_types[column], "TEXT", column)
            # 幂等纪律：新表/新索引语句一律 IF NOT EXISTS（在全新库上重放不炸）；表重建只针对 ocr_card_commit
            creates = [s for s in self.statements(migration) if re.match(r"CREATE (TABLE|INDEX)", s)]
            rebuild = [s for s in creates if not s.startswith(("CREATE TABLE IF NOT EXISTS", "CREATE INDEX IF NOT EXISTS"))]
            self.assertTrue(all("ocr_card_commit" in s for s in rebuild), rebuild)
            for statement in creates:
                if statement.startswith(("CREATE TABLE IF NOT EXISTS", "CREATE INDEX IF NOT EXISTS")):
                    fresh.execute(statement)
            adds = [s for s in self.statements(migration) if s.startswith("ALTER TABLE") and "ADD COLUMN" in s]
            self.assertEqual(len(adds), 5 + 7 + 1 + 5 + 2, "encounter 5 / prescription 7 / stock_lot 1 / claim_item 5 / document_file 2")


if __name__ == "__main__":
    unittest.main()
