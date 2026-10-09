"""fetch_catalog:v3 指针解析/固定名选择/包钥同源断言/信封解密往返(可跳)。"""
import base64
import importlib.util
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

from fetch_catalog import (MEDICAL_PACKAGE_KEY_HEX, parse_catalog_pointer, select_manifest_asset)

# 仓根锚点逐级上溯（禁止固定层级 parents[N]——四文件化布局下会解析错位,见 workflows/README.md 分簇规则）
REPO_ROOT = Path(__file__).resolve().parent
while REPO_ROOT != REPO_ROOT.parent and not (REPO_ROOT / "CoreKit" / "Sources" / "Domain").is_dir():
    REPO_ROOT = REPO_ROOT.parent
RELEASE_DIR = REPO_ROOT / ".github" / "actions" / "release"

SQLITE_SHA = "ff6d955e4394b70d6c3f29601463df787bc7f3484e0c5b6dc091211daf225258"
CIPHER_SHA = "bf82d8890d80fcd3aba5f0832fb9e9c4be71bf4573a98346dae3d115a76f148f"
DATA_VERSION = "d9cbe8cc" + "0" * 56


def _pointer_payload(**overrides):
    payload = {
        "schemaVersion": 3,
        "catalogVersion": 1791325086,
        "packageAssetName": "package-1791325086.bin",
        "packageSha256": CIPHER_SHA,
        "sqliteSha256": SQLITE_SHA,
        "dataVersion": DATA_VERSION,
        "contentSha256": DATA_VERSION,
        "installable": False,
        "manifest": {"sqlite_sha256": SQLITE_SHA, "data_version": DATA_VERSION},
    }
    payload.update(overrides)
    return {"payload": base64.b64encode(json.dumps(payload).encode()).decode(), "signatures": []}


class PointerTests(unittest.TestCase):
    def test_valid_pointer_roundtrip(self):
        payload = parse_catalog_pointer(json.dumps(_pointer_payload()).encode())
        self.assertEqual(payload["catalogVersion"], 1791325086)
        self.assertEqual(payload["sqliteSha256"], SQLITE_SHA)

    def test_missing_field_rejected(self):
        bad = _pointer_payload()
        inner = json.loads(base64.b64decode(bad["payload"]))
        del inner["packageAssetName"]
        bad["payload"] = base64.b64encode(json.dumps(inner).encode()).decode()
        with self.assertRaises(ValueError):
            parse_catalog_pointer(json.dumps(bad).encode())

    def test_bad_package_name_rejected(self):
        with self.assertRaises(ValueError):
            parse_catalog_pointer(json.dumps(_pointer_payload(packageAssetName="medical-data-package-x.bin")).encode())

    def test_package_version_newer_than_catalog_rejected(self):
        # 包版本 = 首次产出该包的 catalogVersion,不可能大于当前 catalogVersion
        with self.assertRaises(ValueError):
            parse_catalog_pointer(json.dumps(_pointer_payload(catalogVersion=100)).encode())

    def test_older_package_version_accepted(self):
        # 续期/晋升复用旧包:packageAssetName 可小于当前 catalogVersion
        payload = parse_catalog_pointer(json.dumps(_pointer_payload(
            catalogVersion=200, packageAssetName="package-100.bin")).encode())
        self.assertEqual(payload["packageAssetName"], "package-100.bin")

    def test_inner_manifest_mismatch_rejected(self):
        with self.assertRaises(ValueError):
            parse_catalog_pointer(json.dumps(_pointer_payload(
                manifest={"sqlite_sha256": "0" * 64, "data_version": DATA_VERSION})).encode())

    def test_missing_inline_manifest_rejected(self):
        with self.assertRaises(ValueError):
            parse_catalog_pointer(json.dumps(_pointer_payload(manifest=None)).encode())

    def test_non_json_rejected(self):
        with self.assertRaises(ValueError):
            parse_catalog_pointer(b"not json")


class AssetSelectionTests(unittest.TestCase):
    def _asset(self, name):
        return {"name": name, "path": "/x/-/releases/download/medical-data/" + name,
                "hashAlgo": "sha256", "hashValue": CIPHER_SHA, "sizeInByte": 1}

    def test_fixed_name_selected(self):
        assets = [self._asset("overview.json"), self._asset("manifest.json"), self._asset("package-1.bin")]
        self.assertEqual(select_manifest_asset(assets)["name"], "manifest.json")

    def test_missing_fixed_name_rejected_with_inventory(self):
        with self.assertRaises(ValueError) as ctx:
            select_manifest_asset([self._asset("medical-data-catalog-progress-1-x.json")])
        self.assertIn("medical-data-catalog-progress", str(ctx.exception))   # 旧名不回落,失败信息点名现有资产


class PackageKeySameSourceTests(unittest.TestCase):
    def test_key_matches_app_swift_constant(self):
        """包钥与 App 内嵌常量同源(两处漂移 = 信封解密永久失败)。"""
        swift = (REPO_ROOT / "CoreKit" / "Sources" / "Infrastructure" / "ASRPackageCrypto.swift").read_text(encoding="utf-8")
        match = re.search(r'masterKeyHex\s*=\s*"([0-9a-f]{64})"', swift)
        self.assertIsNotNone(match, "ASRPackageCrypto.masterKeyHex 未解析到")
        self.assertEqual(match.group(1), MEDICAL_PACKAGE_KEY_HEX)


class ReleaseDirOverrideTests(unittest.TestCase):
    """W11 可移植覆盖:训练机 staged 树用 --release-dir/VITALIBER_RELEASE_DIR 加载三件套。

    默认路径不变(CI 行为);覆盖目录缺件 fail-closed(不是首次下载时才炸)。
    """

    def test_default_resolution_still_finds_repo_release_cluster(self):
        import fetch_catalog
        self.assertEqual(fetch_catalog.RELEASE_DIR, RELEASE_DIR)

    def test_override_switches_release_dir_and_resets_module_cache(self):
        import fetch_catalog
        saved_dir, saved_cache = fetch_catalog.RELEASE_DIR, fetch_catalog._CNB_READ_MODULE
        try:
            with tempfile.TemporaryDirectory() as tmp:
                for name in fetch_catalog.RELEASE_DIR_REQUIRED:
                    (Path(tmp) / name).write_text("# staged\n", encoding="utf-8")
                fetch_catalog._CNB_READ_MODULE = object()   # 假装已缓存旧目录加载结果
                fetch_catalog.apply_release_dir_override(tmp)
                self.assertEqual(fetch_catalog.RELEASE_DIR, Path(tmp).resolve())
                self.assertIsNone(fetch_catalog._CNB_READ_MODULE, "覆盖后必须失效旧加载缓存")
        finally:
            fetch_catalog.RELEASE_DIR, fetch_catalog._CNB_READ_MODULE = saved_dir, saved_cache

    def test_override_missing_files_rejected_fail_closed(self):
        import fetch_catalog
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "cnb_read.py").write_text("# only one\n", encoding="utf-8")
            with self.assertRaises(ValueError) as ctx:
                fetch_catalog.apply_release_dir_override(tmp)
            self.assertIn("cnb_release.py", str(ctx.exception))
            self.assertIn("asr_envelope.py", str(ctx.exception))
        self.assertEqual(fetch_catalog.RELEASE_DIR, RELEASE_DIR, "拒绝后不得改变生效目录")


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
