"""fetch_catalog:指针解析 / 资产选择 / 包钥同源断言 / 信封解密往返(可跳)。"""
import base64
import importlib.util
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

from fetch_catalog import (MEDICAL_PACKAGE_KEY_HEX, parse_catalog_pointer,
                           select_latest_catalog_asset)

REPO_ROOT = Path(__file__).resolve().parents[3]
RELEASE_DIR = REPO_ROOT / "scripts" / "release"


def _pointer_payload(**overrides):
    sqlite_sha = "ff6d955e4394b70d6c3f29601463df787bc7f3484e0c5b6dc091211daf225258"
    cipher_sha = "bf82d8890d80fcd3aba5f0832fb9e9c4be71bf4573a98346dae3d115a76f148f"
    payload = {
        "packageAssetName": f"medical-data-package-sqlite-{sqlite_sha}-cipher-{cipher_sha}.bin",
        "packageSha256": cipher_sha,
        "sqliteSha256": sqlite_sha,
        "dataVersion": "d9cbe8cc" + "0" * 56,
        "contentSha256": "d9cbe8cc" + "0" * 56,
        "manifestSha256": "67aabe375cf79b5cfa56df20881b90b49ef43823a945840fd07e38ccb967259d",
        "catalogVersion": 1791325086,
        "installable": False,
    }
    payload.update(overrides)
    return {"payload": base64.b64encode(json.dumps(payload).encode()).decode(), "signatures": []}


class PointerTests(unittest.TestCase):
    def test_valid_pointer_roundtrip(self):
        payload = parse_catalog_pointer(json.dumps(_pointer_payload()).encode())
        self.assertEqual(payload["catalogVersion"], 1791325086)
        self.assertEqual(payload["sqliteSha256"][:8], "ff6d955e")

    def test_missing_field_rejected(self):
        bad = _pointer_payload()
        inner = json.loads(base64.b64decode(bad["payload"]))
        del inner["packageAssetName"]
        bad["payload"] = base64.b64encode(json.dumps(inner).encode()).decode()
        with self.assertRaises(ValueError):
            parse_catalog_pointer(json.dumps(bad).encode())

    def test_name_payload_mismatch_rejected(self):
        with self.assertRaises(ValueError):
            parse_catalog_pointer(json.dumps(_pointer_payload(packageSha256="0" * 64)).encode())

    def test_non_json_rejected(self):
        with self.assertRaises(ValueError):
            parse_catalog_pointer(b"not json")


class AssetSelectionTests(unittest.TestCase):
    def _asset(self, name):
        return {"name": name, "path": "/x/-/releases/download/medical-data/" + name,
                "hashAlgo": "sha256", "hashValue": "0" * 64, "sizeInByte": 1}

    def test_latest_by_version_then_timestamp(self):
        assets = [self._asset("medical-data-catalog-progress-10-20260101T000000Z.json"),
                  self._asset("medical-data-catalog-progress-9-20260102T000000Z.json"),
                  self._asset("medical-data-manifest-" + "a" * 64 + ".json")]
        chosen = select_latest_catalog_asset(assets)
        self.assertIn("progress-10-", chosen["name"])

    def test_none_rejected(self):
        with self.assertRaises(ValueError):
            select_latest_catalog_asset([self._asset("random.json")])


class PackageKeySameSourceTests(unittest.TestCase):
    def test_key_matches_app_swift_constant(self):
        """包钥与 App 内嵌常量同源(两处漂移 = 信封解密永久失败)。"""
        swift = (REPO_ROOT / "CoreKit" / "Sources" / "Infrastructure" / "ASRPackageCrypto.swift").read_text(encoding="utf-8")
        match = re.search(r'masterKeyHex\s*=\s*"([0-9a-f]{64})"', swift)
        self.assertIsNotNone(match, "ASRPackageCrypto.masterKeyHex 未解析到")
        self.assertEqual(match.group(1), MEDICAL_PACKAGE_KEY_HEX)


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault(name, module)
    spec.loader.exec_module(module)
    return module


class DecryptRoundtripTests(unittest.TestCase):
    """解密往返:构造合成 ZIP → ASR 同构信封加密 → fetch_catalog 解密解包校验 SHA。"""

    def setUp(self):
        try:
            import cryptography  # noqa: F401
        except ImportError:
            self.skipTest("cryptography 未安装(CI prepare job 会安装;本地跳过)")

    def test_roundtrip_and_tamper(self):
        import hashlib
        import zipfile

        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            sqlite_bytes = b"SQLite format 3\x00" + b"synthetic-catalog" * 100
            zip_path = tmp / "pkg.zip"
            with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("medical-catalog.sqlite", sqlite_bytes)
            identity = hashlib.sha256(sqlite_bytes).hexdigest()

            sys.path.insert(0, str(RELEASE_DIR))
            envelope = _load("asr_envelope", RELEASE_DIR / "asr_envelope.py")
            key = bytes.fromhex(MEDICAL_PACKAGE_KEY_HEX)
            cipher = tmp / "pkg.bin"
            envelope.encrypt_package(key, identity, zip_path, cipher)

            from fetch_catalog import decrypt_and_extract
            out_sqlite = tmp / "catalog.sqlite"
            decrypt_and_extract(cipher, tmp / "dec.zip", out_sqlite, identity)
            self.assertEqual(out_sqlite.read_bytes(), sqlite_bytes)

            # 篡改身份 → GCM 拒(密钥派生随身份变化)
            with self.assertRaises(ValueError):
                decrypt_and_extract(cipher, tmp / "dec2.zip", tmp / "bad.sqlite", "0" * 64)


if __name__ == "__main__":
    unittest.main()
