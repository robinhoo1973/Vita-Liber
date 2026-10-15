"""Offline signed-envelope -> ZIP -> shared gate -> both CI consumers."""
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import shutil
import sqlite3
import sys
import tempfile
import unittest
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import fetch_catalog as fc
import build_corpus as corpus_cli
import eval_entlink as eval_cli
from catalog_contract import CONTRACT_PATH, readonly_connection, sha256_file, validate_sqlite
from corpus.builder import BuildConfig, build_corpus
from corpus.manifest import verify_manifest, write_manifest
from entlink.catalog import load_entities_dump, load_sqlite_v4
from extract.catalog_source import materialize
from tests.test_catalog_contract import FIXTURES

EXPECTED = json.loads((FIXTURES / "expected.json").read_text(encoding="utf-8"))
LEGACY = FIXTURES.parent / "medical"
NOW = datetime(2026, 10, 1, 13, 0, tzinfo=timezone.utc)


class FixtureClock(datetime):
    @classmethod
    def now(cls, tz=None):
        return NOW if tz is not None else NOW.replace(tzinfo=None)


class UnifiedGoldenTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)

    def test_public_json_ddl_and_real_bridge_goldens_are_byte_pinned(self):
        self.assertEqual(sha256_file(CONTRACT_PATH), EXPECTED["contractSHA256"])
        for name, key in (("schema.sql", "schemaSHA256"), ("catalog.sql", "catalogSHA256")):
            self.assertEqual(sha256_file(FIXTURES / name), EXPECTED[key])
        for name in ("base", "reviewed"):
            expected = EXPECTED[name]
            path = FIXTURES / expected["file"]
            identity = validate_sqlite(path, schema=9, data_version=expected["releaseID"],
                                       content_sha256=expected["releaseID"],
                                       sqlite_sha256=expected["sqliteSHA256"])
            self.assertEqual(identity.activation_id, expected["activationID"])
        self.assertNotEqual(EXPECTED["base"]["releaseID"], EXPECTED["reviewed"]["releaseID"])

    def test_human_review_changes_only_graph_content_but_requires_a_new_r_and_file_sha(self):
        snapshots = []
        for key, count in (("base", 0), ("reviewed", 1)):
            path = FIXTURES / EXPECTED[key]["file"]
            with contextlib.closing(readonly_connection(path)) as conn:
                self.assertEqual(conn.execute("SELECT count(*) FROM effective_facts").fetchone()[0], count)
                self.assertEqual(conn.execute("SELECT count(*) FROM catalog_relation").fetchone()[0], 2)
                snapshots.append({name: conn.execute(f'SELECT * FROM "{name}"').fetchall()
                                  for name in ("drug", "drug_reference", "drug_detail", "hospital",
                                               "department", "diagnosis", "exam_item")})
        self.assertEqual(snapshots[0], snapshots[1])
        self.assertNotEqual(EXPECTED["base"]["sqliteSHA256"], EXPECTED["reviewed"]["sqliteSHA256"])
        bad = self.root / "auto-approved.sqlite"
        shutil.copy2(FIXTURES / EXPECTED["reviewed"]["file"], bad)
        with contextlib.closing(sqlite3.connect(bad)) as conn:
            conn.executescript("DELETE FROM current_assertion_review")
        with self.assertRaisesRegex(ValueError, "actor/rationale"):
            validate_sqlite(bad)

    def test_history_only_file_change_keeps_r_but_does_not_reuse_byte_identity(self):
        path = self.root / "history.sqlite"
        shutil.copy2(FIXTURES / EXPECTED["reviewed"]["file"], path)
        with contextlib.closing(sqlite3.connect(path)) as conn:
            conn.executescript("INSERT INTO metadata VALUES ('diagnostic-history-note','not active content')")
        identity = validate_sqlite(path)
        self.assertEqual(identity.data_version, EXPECTED["reviewed"]["releaseID"])
        self.assertNotEqual(sha256_file(path), EXPECTED["reviewed"]["sqliteSHA256"])
        with self.assertRaises(ValueError):
            validate_sqlite(path, sqlite_sha256=EXPECTED["reviewed"]["sqliteSHA256"])

    def test_public_graph_views_hide_inactive_assertions_without_promoting_catalog_relations(self):
        path = self.root / "inactive.sqlite"
        shutil.copy2(FIXTURES / EXPECTED["reviewed"]["file"], path)
        with contextlib.closing(sqlite3.connect(path)) as conn:
            conn.execute("UPDATE assertion_state SET active=0 WHERE assertion_uid=?",
                         (EXPECTED["reviewAssertionUID"],))
            conn.commit()
            self.assertEqual(conn.execute("SELECT count(*) FROM effective_facts").fetchone()[0], 0)
            self.assertEqual(conn.execute("SELECT count(*) FROM graph_projection WHERE assertion_id=?",
                                          (EXPECTED["reviewAssertionUID"],)).fetchone()[0], 0)
            self.assertEqual(conn.execute("SELECT count(*) FROM catalog_relation").fetchone()[0], 2)
        with self.assertRaises(ValueError):
            validate_sqlite(path, sqlite_sha256=EXPECTED["reviewed"]["sqliteSHA256"])

    def test_verified_storage_identity_survives_corpus_and_its_self_hash(self):
        catalog = load_sqlite_v4(FIXTURES / EXPECTED["base"]["file"], group_by_name=True)
        path = self.root / "corpus.jsonl"
        build_corpus(catalog, path, BuildConfig(min_eval_entities=0, bands=("light",),
                                              include_canonical_names=True))
        manifest_path = path.with_suffix(".jsonl.manifest.json")
        manifest = verify_manifest(manifest_path, path)
        self.assertEqual(manifest["catalog_storage_identity"]["releaseID"], EXPECTED["base"]["releaseID"])
        self.assertEqual(manifest["catalog_storage_identity"]["sqliteSha256"], EXPECTED["base"]["sqliteSHA256"])
        manifest["catalog_storage_identity"]["sqliteSha256"] = "0" * 64
        write_manifest(manifest_path, manifest)
        with self.assertRaises(ValueError):
            verify_manifest(manifest_path, path)

    def test_cli_entity_dump_and_eval_bind_the_same_storage_identity(self):
        assets = self.root / "assets"
        assets.mkdir()
        descriptor = fc.run_local(FIXTURES / EXPECTED["base"]["file"], assets)
        source = assets / "source.json"
        source.write_text(json.dumps(descriptor), encoding="utf-8")
        corpus = self.root / "corpus.jsonl"
        dump = self.root / "entities.jsonl"
        arguments = ["build_corpus.py", "--catalog-sqlite", str(assets / "catalog.sqlite"),
                     "--source-json", str(source), "--out", str(corpus), "--dump-entities", str(dump),
                     "--min-eval-entities", "0", "--bands", "light", "--no-mine",
                     "--negatives", "0", "--include-canonical-names", "--group-by-name"]
        with patch.object(sys, "argv", arguments), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(corpus_cli.main(), 0)
        catalog = load_entities_dump(dump)
        manifest = verify_manifest(corpus.with_suffix(".jsonl.manifest.json"), corpus)
        self.assertEqual(catalog.storage_identity, manifest["catalog_storage_identity"])
        self.assertEqual(catalog.storage_identity["sqliteSha256"], EXPECTED["base"]["sqliteSHA256"])
        expected_entities = load_sqlite_v4(assets / "catalog.sqlite").entities
        self.assertEqual({e.entity_id for e in catalog.entities}, {e.entity_id for e in expected_entities})
        arguments = ["eval_entlink.py", "--corpus", str(corpus), "--catalog-entities", str(dump),
                     "--min-accepts", "0"]
        with patch.object(sys, "argv", arguments), contextlib.redirect_stdout(io.StringIO()), \
                patch.object(eval_cli, "run_gate", wraps=eval_cli.run_gate) as gate:
            self.assertIn(eval_cli.main(), (0, 2))  # A small synthetic corpus need not pass the model-quality gate.
            gate.assert_called_once()
        original = dump.read_text(encoding="utf-8").splitlines()
        for change in ("sha", "missing"):
            rows = list(original)
            header = json.loads(rows[0])
            if change == "sha":
                header["_meta"]["storage_identity"]["sqliteSha256"] = "f" * 64
            else:
                del header["_meta"]["storage_identity"]
            rows[0] = json.dumps(header)
            dump.write_text("\n".join(rows) + "\n", encoding="utf-8")
            with self.subTest(change=change), patch.object(sys, "argv", arguments), \
                    contextlib.redirect_stderr(io.StringIO()), patch.object(eval_cli, "run_gate") as gate:
                self.assertEqual(eval_cli.main(), 1)
                gate.assert_not_called()


@unittest.skipUnless(importlib.util.find_spec("cryptography"), "signed-envelope runtime needs pinned cryptography")
class SignedUnifiedPipelineTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.out = self.root / "out"
        self.out.mkdir()
        self.database = self.root / "input.sqlite"
        shutil.copy2(FIXTURES / EXPECTED["reviewed"]["file"], self.database)
        self.downloads = []

    def package_and_pointer(self, mutate=None, sqlite_sha=None):
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        sys.path.insert(0, str(fc.RELEASE_DIR))
        from asr_envelope import encrypt_package
        identity = sqlite_sha or sha256_file(self.database)
        archive = self.root / "fixed.zip"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as package:
            info = zipfile.ZipInfo(fc.SQLITE_ENTRY_NAME)
            info.compress_type = zipfile.ZIP_DEFLATED
            package.writestr(info, self.database.read_bytes())
        cipher = self.root / "package.bin"
        encrypt_package(bytes.fromhex(fc.MEDICAL_PACKAGE_KEY_HEX), identity, archive, cipher)
        payload = json.loads(base64.b64decode(json.loads((LEGACY / "installable-manifest.json").read_bytes())["payload"]))
        payload.update(catalogVersion=42, packageAssetName="package-41.bin", packageSize=cipher.stat().st_size,
                       packageSha256=sha256_file(cipher), sqliteSha256=identity, sqliteSchemaVersion=9,
                       dataVersion=EXPECTED["reviewed"]["releaseID"], contentSha256=EXPECTED["reviewed"]["releaseID"],
                       installable=True)
        payload["manifest"].update(sqlite_sha256=identity, sqlite_schema_version=9,
                                   data_version=payload["dataVersion"], content_sha256=payload["contentSha256"],
                                   installable=True)
        if mutate:
            mutate(payload)
        raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
        keys = json.loads((LEGACY / "catalog-signing-keys.json").read_bytes())["keys"]
        signatures = [{"keyId": key["keyId"], "signature": base64.b64encode(
            Ed25519PrivateKey.from_private_bytes(base64.b64decode(key["privateKey"])).sign(raw)).decode()}
            for key in keys]
        envelope = json.dumps({"payload": base64.b64encode(raw).decode(), "signatures": signatures}).encode()
        self.assets = {"manifest.json": envelope, payload["packageAssetName"]: cipher.read_bytes()}
        return raw

    def fetch(self):
        assets = [{"name": name, "hashValue": hashlib.sha256(data).hexdigest(), "sizeInByte": len(data)}
                  for name, data in self.assets.items()]

        def download(repository, tag, asset, destination):
            self.downloads.append(asset["name"])
            destination.write_bytes(self.assets[asset["name"]])

        with patch.object(fc, "datetime", FixtureClock), \
                patch.object(fc, "fetch_tag_page", return_value="offline"), \
                patch.object(fc, "_cnb_read", return_value=SimpleNamespace(parse_cnb_tag_page=lambda *args: assets)), \
                patch.object(fc, "download_asset", side_effect=download), \
                contextlib.redirect_stdout(io.StringIO()):
            return fc.run_remote(fc.DEFAULT_REPOSITORY, fc.DEFAULT_TAG, self.out, False,
                                 trust_root=LEGACY / "pinned-root.json")

    def assert_retains_last_good(self):
        active = self.out / "catalog.sqlite"
        pointer = self.out / "pointer.json"
        active.write_bytes(b"last-good catalog")
        pointer.write_bytes(b"last-good pointer")
        with self.assertRaises(ValueError):
            self.fetch()
        self.assertEqual(active.read_bytes(), b"last-good catalog")
        self.assertEqual(pointer.read_bytes(), b"last-good pointer")

    def test_real_signed_wire_envelope_zip_descriptor_entlink_extract_roundtrip(self):
        raw = self.package_and_pointer()
        descriptor = self.fetch()
        self.assertEqual(descriptor["signedPointerDigest"], hashlib.sha256(raw).hexdigest())
        self.assertEqual(descriptor["releaseID"], EXPECTED["reviewed"]["releaseID"])
        self.assertEqual(descriptor["sqliteSha256"], EXPECTED["reviewed"]["sqliteSHA256"])
        source = self.out / "source.json"
        source.write_text(json.dumps(descriptor), encoding="utf-8")
        catalog = load_sqlite_v4(self.out / "catalog.sqlite", source_descriptor=source)
        self.assertEqual(catalog.storage_identity["signedPointerDigest"], descriptor["signedPointerDigest"])
        with contextlib.closing(readonly_connection(self.out / "catalog.sqlite")) as conn:
            uid, source_id = conn.execute("SELECT entity_uid,source_id FROM catalog_entry WHERE table_name='drug'").fetchone()
        self.assertNotEqual(uid, source_id)
        self.assertEqual(catalog.by_domain("drug")[0].entity_id, uid)
        result = materialize(self.out / "catalog.sqlite", self.root / "extracted", descriptor)
        self.assertEqual(result["releaseID"], descriptor["releaseID"])
        self.assertFalse((self.out / ".fetch-work").exists())

    def test_signed_r_mismatch_keeps_previous_outputs(self):
        def mutate(payload):
            payload["dataVersion"] = payload["contentSha256"] = "f" * 64
            payload["manifest"]["data_version"] = payload["manifest"]["content_sha256"] = "f" * 64
        self.package_and_pointer(mutate)
        self.assert_retains_last_good()

    def test_same_r_different_signed_sqlite_sha_is_not_accepted_as_reuse(self):
        self.package_and_pointer(sqlite_sha="f" * 64)
        self.assert_retains_last_good()

    def test_partial_and_auto_approved_snapshots_fail_before_outputs_change(self):
        for sql in ("UPDATE catalog_meta SET value='partial' WHERE key='content_scope'; "
                    "UPDATE graph_release SET scope='partial'",
                    "DELETE FROM current_assertion_review"):
            with self.subTest(sql=sql):
                shutil.copy2(FIXTURES / EXPECTED["reviewed"]["file"], self.database)
                with contextlib.closing(sqlite3.connect(self.database)) as conn:
                    conn.executescript(sql)
                self.package_and_pointer()
                self.assert_retains_last_good()

    def test_noninstallable_and_v8_pointers_fail_before_package_download(self):
        for field, value, manifest_field in (("installable", False, "installable"),
                                              ("sqliteSchemaVersion", 8, "sqlite_schema_version")):
            with self.subTest(field=field):
                def mutate(payload):
                    payload[field] = value
                    payload["manifest"][manifest_field] = value
                self.downloads.clear()
                self.package_and_pointer(mutate)
                self.assert_retains_last_good()
                self.assertEqual(self.downloads, ["manifest.json"])

    def test_wire_versions_are_strict_bounded_integers(self):
        for field, value in (("schemaVersion", 3.0), ("catalogVersion", 1 << 63),
                             ("manifestSchemaVersion", 2.0), ("packageAssetName", "package-41.bin\n")):
            with self.subTest(field=field):
                def mutate(payload):
                    if field == "manifestSchemaVersion":
                        payload["manifest"]["schema_version"] = value
                    else:
                        payload[field] = value
                self.downloads.clear()
                self.package_and_pointer(mutate)
                self.assert_retains_last_good()
                self.assertEqual(self.downloads, ["manifest.json"])

    def test_raw_signed_payload_tamper_fails_with_no_package_download(self):
        self.package_and_pointer()
        envelope = json.loads(self.assets["manifest.json"])
        raw = json.loads(base64.b64decode(envelope["payload"]))
        raw["catalogVersion"] += 1
        envelope["payload"] = base64.b64encode(json.dumps(raw).encode()).decode()
        self.assets["manifest.json"] = json.dumps(envelope).encode()
        self.assert_retains_last_good()
        self.assertEqual(self.downloads, ["manifest.json"])


if __name__ == "__main__":
    unittest.main()
