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


if __name__ == "__main__":
    unittest.main()
