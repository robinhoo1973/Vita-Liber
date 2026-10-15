"""One public schema and shared synthetic rows drive Python and Swift consumers."""
import hashlib
import json
import shutil
import sqlite3
import stat
import tempfile
import unittest
import zipfile
from contextlib import closing
from pathlib import Path

from catalog_contract import (CONTRACT_PATH, MARKER, inspect_connection, readonly_connection,
                              sha256_file, validate_source_descriptor, validate_sqlite)
from entlink.catalog import load_sqlite_v4
from extract.catalog_source import materialize
from fetch_catalog import SQLITE_ENTRY_NAME, extract_sqlite_zip, run_local

ROOT = Path(__file__).resolve().parent
while not (ROOT / "CoreKit" / "Package.swift").is_file():
    ROOT = ROOT.parent
FIXTURES = ROOT / "CoreKit" / "Tests" / "CoreKitTests" / "Fixtures" / "unified"
R = "a" * 64


def make_unified(path: Path) -> Path:
    conn = sqlite3.connect(path)
    try:
        for name in ("schema.sql", "catalog.sql", "app-consumer.sql"):
            conn.executescript((FIXTURES / name).read_text(encoding="utf-8"))
        conn.commit()
    finally:
        conn.close()
    return path


class UnifiedContractTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.path = make_unified(self.directory / "catalog.sqlite")

    def mutate(self, sql):
        with closing(sqlite3.connect(self.path)) as conn:
            conn.executescript(sql)

    def test_public_contract_copies_and_fixed_shape(self):
        bundled = ROOT / "CoreKit" / "Sources" / "Infrastructure" / "Resources" / CONTRACT_PATH.name
        self.assertEqual(CONTRACT_PATH.read_bytes(), bundled.read_bytes())
        identity = validate_sqlite(self.path, schema=9, data_version=R, content_sha256=R,
                                   sqlite_sha256=sha256_file(self.path))
        self.assertEqual(identity.activation_id, "activation-A-1")
        self.assertEqual(identity.descriptor()["storageContract"], MARKER)
        with closing(readonly_connection(self.path)) as conn:
            self.assertEqual(dict(conn.execute("SELECT region,usage_text FROM drug_detail")),
                             {"CN": "CN 原文😀", "TW": "TW 原文😀"})
            self.assertEqual(conn.execute("SELECT unit,price_ref,loinc_concept_id FROM exam_item").fetchone(),
                             (None, None, None))

    def test_v9_corruption_never_falls_back_to_legacy(self):
        cases = (
            "DELETE FROM catalog_meta WHERE key='storage_contract'",
            "UPDATE catalog_meta SET value='broken' WHERE key='storage_contract'",
            "UPDATE catalog_meta SET value='8' WHERE key='schema_version'; PRAGMA user_version=8",
            "UPDATE catalog_meta SET value='7' WHERE key='schema_version'; PRAGMA user_version=7",
            "UPDATE metadata SET value='development' WHERE key='lifecycle'",
            "DELETE FROM metadata WHERE key='lifecycle'",
            "DROP VIEW active_entity",
            "DROP TABLE alias_state",
            "DROP TABLE producer_state_history",
            "UPDATE graph_release SET content_sha256='" + "c" * 64 + "'",
            "UPDATE metadata SET value='missing-event' WHERE key='activation_id'",
            "UPDATE graph_activation SET release_id='" + "c" * 64 + "'",
            "UPDATE catalog_entry SET current_revision_uid='revision-entry-drug-tw' WHERE entry_uid='entry-drug-cn'",
            "DELETE FROM catalog_entry WHERE entry_uid='entry-drug-cn'",
            "UPDATE graph_release SET catalog_count=11",
            "UPDATE catalog_meta SET value='missing' WHERE key='producer_input_sha256'",
            "DELETE FROM producer_import",
            "CREATE UNIQUE INDEX invalid_global_hospital_source ON hospital(source_id)",
            "UPDATE drug SET aliases_json='not-json' WHERE id=1",
            "ALTER TABLE metadata RENAME TO real_metadata; CREATE VIEW metadata AS SELECT * FROM real_metadata",
            "ALTER TABLE catalog_meta RENAME TO real_meta; CREATE VIEW catalog_meta AS SELECT * FROM real_meta",
        )
        for sql in cases:
            with self.subTest(sql=sql):
                path = self.directory / "case.sqlite"
                shutil.copy2(self.path, path)
                with closing(sqlite3.connect(path)) as conn:
                    conn.executescript(sql)
                with self.assertRaises((ValueError, sqlite3.Error)):
                    validate_sqlite(path)

    def test_partial_and_empty_never_install_or_serve(self):
        for scope, ready in (("partial", "true"), ("empty", "false"), ("full", "false")):
            with self.subTest(scope=scope, ready=ready):
                self.mutate(f"UPDATE graph_release SET scope='{scope}'; "
                            f"UPDATE catalog_meta SET value='{scope}' WHERE key='content_scope'; "
                            f"UPDATE catalog_meta SET value='{ready}' WHERE key='catalog_ready'")
                for reader in (validate_sqlite, load_sqlite_v4):
                    with self.assertRaises(ValueError):
                        reader(self.path)
                with self.assertRaises(ValueError):
                    materialize(self.path, self.directory / "rejected")
                self.assertFalse((self.directory / "rejected").exists())

    def test_old_current_revision_and_a_b_a_activation_are_valid(self):
        # A revision need not be the newest; it must belong to its current entry.
        self.mutate("""
            INSERT INTO catalog_revision
            SELECT 'unused-newer',entry_uid,content_sha256,'{}','{"newer":true}','2099-01-01'
            FROM catalog_revision WHERE revision_uid='revision-entry-drug-cn';
            INSERT INTO graph_release SELECT replace(release_id,'a','b'),2,replace(content_sha256,'a','b'),
                scope,status,source_manifest_json,catalog_count,entity_count,assertion_count,created_at
            FROM graph_release;
            INSERT INTO graph_activation VALUES
                ('activation-B-2',2,'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','2026-10-02'),
                ('activation-A-3',3,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','2026-10-03');
            UPDATE metadata SET value='activation-A-3' WHERE key='activation_id';
        """)
        self.assertEqual(validate_sqlite(self.path).activation_id, "activation-A-3")

    def test_producer_state_audit_requires_import_but_does_not_rebind_content(self):
        identity = validate_sqlite(self.path)
        original_sha = sha256_file(self.path)
        self.mutate("""
            INSERT INTO producer_state_history
            SELECT 'audit-1',input_sha256,'fetch_snapshot','["snapshot-a"]',
                   '{"status":"running"}','{"status":"complete"}','2026-10-14'
            FROM producer_import;
            """)
        self.assertEqual(validate_sqlite(self.path), identity)
        self.assertNotEqual(sha256_file(self.path), original_sha)
        with self.assertRaisesRegex(ValueError, "SQLite SHA"):
            validate_sqlite(self.path, sqlite_sha256=original_sha)
        self.mutate("UPDATE producer_state_history SET input_sha256='missing-import'")
        with self.assertRaisesRegex(ValueError, "foreign_key_check"):
            validate_sqlite(self.path)

    def test_approved_assertions_require_matching_immutable_human_decisions(self):
        self.mutate("""
            INSERT INTO entity VALUES ('directions','statement','CN','directions','Source directions');
            INSERT INTO assertion(uid,subject_uid,subject_kind,object_uid,object_kind,region,
                                  relation,polarity,derivation,review_status)
            VALUES ('assertion-1','canonical-drug-甲','drug','directions','statement','CN',
                    'directions','positive','explicit','approved');
            """)
        with self.assertRaisesRegex(ValueError, "actor/rationale"):
            validate_sqlite(self.path)
        self.mutate("""
            INSERT INTO assertion_review VALUES ('decision-1','assertion-1','approved','reviewer',
                                                 'Verified source evidence','2026-10-01');
            INSERT INTO current_assertion_review VALUES ('assertion-1','decision-1');
            """)
        self.assertEqual(validate_sqlite(self.path).data_version, R)
        self.mutate("UPDATE assertion SET review_status='pending' WHERE uid='assertion-1'")
        with self.assertRaisesRegex(ValueError, "actor/rationale"):
            validate_sqlite(self.path)

    def test_entlink_uses_entry_entity_uid_even_when_grouping_is_requested(self):
        self.mutate("UPDATE drug SET name_zh='同名藥品'")
        catalog = load_sqlite_v4(self.path, group_by_name=True)
        self.assertEqual({e.entity_id for e in catalog.by_domain("drug")},
                         {"canonical-drug-甲", "canonical-drug-乙"})
        self.assertEqual(catalog.data_version, R)

    def test_open_object_aliases_keep_source_bytes_and_reach_both_consumers(self):
        aliases = [{"text": "未來開放別名😀", "type": "future-type",
                    "unknown": {"unmodified": [None, 9007199254740993]}},
                   "舊字串別名", {"text": {"nested": "not an alias"}}, {"future": "not an alias"}]
        raw = json.dumps(aliases, ensure_ascii=False, separators=(", ", ": "))
        with closing(sqlite3.connect(self.path)) as conn:
            for table in ("drug", "hospital", "department", "diagnosis", "exam_item"):
                conn.execute(f"UPDATE {table} SET aliases_json=?", (raw,))
            conn.commit()
        before = sha256_file(self.path)
        catalog = load_sqlite_v4(self.path)
        for entity in catalog.entities:
            self.assertEqual(entity.aliases, ("未來開放別名😀", "舊字串別名"))
        out = self.directory / "object-aliases"
        materialize(self.path, out)
        index = json.loads((out / "medical_index.json").read_text(encoding="utf-8"))["index"]
        self.assertEqual(set(index["未來開放別名😀"]),
                         {'["CN","shared-source"]', '["TW","shared-source"]'})
        with closing(readonly_connection(self.path)) as conn:
            for table in ("drug", "hospital", "department", "diagnosis", "exam_item"):
                self.assertEqual(conn.execute(f"SELECT DISTINCT aliases_json FROM {table}").fetchall(),
                                 [(raw,)])
        self.assertEqual(sha256_file(self.path), before)

    def test_extraction_region_keys_keep_details_and_aliases_separate(self):
        self.mutate("""UPDATE drug SET aliases_json='["共同別名","共同寫法"]';
                       UPDATE drug_detail SET indications='region-specific'""")
        out = self.directory / "data"
        descriptor = materialize(self.path, out)
        self.assertEqual(descriptor["releaseID"], R)
        cn = json.loads((out / "drugs_cn.jsonl").read_text(encoding="utf-8"))
        tw = json.loads((out / "tw_records.jsonl").read_text(encoding="utf-8"))
        self.assertEqual((cn["usage_text"], tw["usage_text"]), ("CN 原文😀", "TW 原文😀"))
        details = [json.loads(line) for line in (out / "medical_details.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertEqual({(row["region"], row["source_id"]) for row in details},
                         {("CN", "shared-source"), ("TW", "shared-source")})
        facts = [json.loads(line) for line in
                 (out / "facts" / "drug.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertEqual(len(facts), 2)
        self.assertEqual({row["region"]: row["usage"] for row in facts},
                         {"CN": "CN 原文😀", "TW": "TW 原文😀"})
        index = json.loads((out / "medical_index.json").read_text(encoding="utf-8"))
        self.assertEqual(set(index["index"]["共同別名"]),
                         {'["CN","shared-source"]', '["TW","shared-source"]'})

    def test_descriptor_binds_r_and_file_sha_independently(self):
        descriptor = run_local(self.path, self.directory)
        identity = validate_sqlite(self.path)
        validate_source_descriptor(identity, descriptor, sha256_file(self.path))
        for key in ("dataVersion", "releaseID", "activationID", "contentSha256",
                    "sqliteSha256", "storageContract", "graphSchemaVersion"):
            bad = {**descriptor, key: "wrong"}
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_source_descriptor(identity, bad, sha256_file(self.path))
        before = descriptor["sqliteSha256"]
        self.mutate("INSERT INTO metadata VALUES ('history-diagnostic','new history, same R')")
        self.assertEqual(validate_sqlite(self.path).data_version, R)
        self.assertNotEqual(sha256_file(self.path), before)
        with self.assertRaises(ValueError):
            materialize(self.path, self.directory / "mismatch", descriptor)

    def test_descriptor_types_are_exact_and_cannot_coerce_bool_or_float(self):
        descriptor = run_local(self.path, self.directory)
        identity = validate_sqlite(self.path)
        digest = sha256_file(self.path)
        for field, value in (("sqliteSchemaVersion", 9.0), ("graphSchemaVersion", 2.0),
                             ("appCatalogSchemaVersion", 4.0), ("catalogReady", 1)):
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_source_descriptor(identity, {**descriptor, field: value}, digest)
        with self.assertRaises(ValueError):
            validate_source_descriptor(identity, {**descriptor, "mode": "cnb-release-v3",
                                                  "signedPointerDigest": 1}, digest)

    def test_fixed_zip_plain_file_sha_and_gate_before_replacement(self):
        content = self.path.read_bytes()
        target = self.directory / "active.sqlite"
        target.write_bytes(b"old last-good")
        for name, mode, extra in (
            ("nested/medical-catalog.sqlite", stat.S_IFREG, False),
            ("medical-catalog.sqlite", stat.S_IFLNK, False),
            ("medical-catalog.sqlite", stat.S_IFDIR, False),
            ("medical-catalog.sqlite", stat.S_IFREG, True),
            ("other.sqlite", stat.S_IFREG, False),
        ):
            with self.subTest(name=name, mode=mode, extra=extra):
                archive = self.directory / "bad.zip"
                with zipfile.ZipFile(archive, "w") as package:
                    info = zipfile.ZipInfo(name)
                    info.create_system = 3
                    info.external_attr = (mode | 0o600) << 16
                    package.writestr(info, content)
                    if extra:
                        package.writestr("README.txt", "not allowed")
                with self.assertRaises(ValueError):
                    extract_sqlite_zip(archive, target, hashlib.sha256(content).hexdigest())
                self.assertEqual(target.read_bytes(), b"old last-good")
        archive = self.directory / "good.zip"
        with zipfile.ZipFile(archive, "w") as package:
            package.writestr(SQLITE_ENTRY_NAME, content)
        with self.assertRaises(ValueError):
            extract_sqlite_zip(archive, target, "0" * 64)
        extract_sqlite_zip(archive, target, hashlib.sha256(content).hexdigest())
        self.assertEqual(target.read_bytes(), content)
