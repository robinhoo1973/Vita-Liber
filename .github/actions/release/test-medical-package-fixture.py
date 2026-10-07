#!/usr/bin/env python3
"""医疗目录包信封夹具 · 跨语言字节合同测试（公仓侧，Linux 可跑）。

背景（2026-10-07 委员会 D5 裁决：CI 强制唯一办法）：
医疗目录包与 ASR 共享 aes256gcm-v1 信封与命名空间，字节合同的三方（Go 生产端
golden exporter / Python 正本 asr_envelope.py / Swift 消费 ASRPackageCrypto→
PackageEnvelopeCrypto）此前只有"本地人肉对拍"，零 CI 约束（私仓对拍还会静默
skip）。本测试把「Go 导出 ↔ 公仓夹具 ↔ Python 正本」钉成可自动复核的一条链；
Swift 侧消费由 macOS L1 的 goEnvelopePackageOpens 独立覆盖——两侧合起来即
三方合同的完整机器化。

夹具为 TEST-ONLY（expected.json 的 note 声明），随 golden_export_test.go 导出；
本测试只读夹具，不读私仓、不触网。
裁决与负例清单全文：refactor/discussions/2026-10-07-medical-envelope-migration-round1.md。
"""
import hashlib
import io
import json
import re
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
while ROOT != ROOT.parent and not (ROOT / "CoreKit/Sources/Domain").is_dir():
    ROOT = ROOT.parent
sys.path.insert(0, str(ROOT / ".github" / "actions" / "release"))

import asr_envelope  # noqa: E402  （正本实现，同目录）

FIXTURES = ROOT / "CoreKit/Tests/CoreKitTests/Fixtures/medical"
SWIFT_SOURCE = ROOT / "CoreKit/Sources/Infrastructure/ASRPackageCrypto.swift"
MASTER_RE = re.compile(r'masterKeyHex\s*=\s*"([0-9a-fA-F]{64})"')


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


class MedicalPackageFixtureTests(unittest.TestCase):
    """Go 导出夹具 ↔ Python 正本逐字节 + 语义断言。"""

    @classmethod
    def setUpClass(cls):
        cls.expected = json.loads((FIXTURES / "expected.json").read_text(encoding="utf-8"))
        cls.package = FIXTURES / cls.expected["packageAssetName"]
        cls.catalog = FIXTURES / "catalog.sqlite"
        # 主密钥自 App 源码抓取（先例 test-asr-package-integrity.py）：与
        # ASRPackageCrypto.masterKeyHex 同源——抓不到即测试硬错（绝不静默）。
        match = MASTER_RE.search(SWIFT_SOURCE.read_text(encoding="utf-8"))
        assert match, "ASRPackageCrypto.masterKeyHex 未在 Swift 源码中找到（声明形态被改？）"
        cls.master = bytes.fromhex(match.group(1))

    def decrypt(self, package: Path, identity: str) -> bytes:
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary) / "plain.zip"
            asr_envelope.decrypt_package(self.master, identity, package, out)
            return out.read_bytes()

    def test_fixture_set_present(self):
        """夹具四件齐备：缺失 = 硬错（防 untracked/手工漂移；ERR#27 族）。"""
        for path in (FIXTURES / "expected.json", self.package, self.catalog):
            self.assertTrue(path.is_file(), f"夹具缺失: {path}")

    def test_asset_name_follows_v3_grammar(self):
        """v3 包名 = `package-<catalogVersion>.bin`（版本=首产 catalogVersion）。
        v2 的 hash 派生长名已退役：包完整性命中改由签名字段 packageSha256 在
        字节层断言（test_envelope_bytes_match_signed_digest），名字不再承担。"""
        self.assertEqual(
            self.expected["packageAssetName"],
            f"package-{self.expected['catalogVersion']}.bin",
        )
        self.assertEqual(self.package.stat().st_size, self.expected["packageSize"])

    def test_fixed_pointer_names_are_frozen(self):
        """v3 单头固定名：manifest.json（唯一提交点，删旧→传新）/ overview.json（可选）。"""
        self.assertEqual(self.expected["manifestAssetName"], "manifest.json")
        self.assertEqual(self.expected["overviewAssetName"], "overview.json")

    def test_envelope_bytes_match_signed_digest(self):
        """信封字节 sha256 == 指针签名覆盖的 packageSha256（下载前校验的同一值）。"""
        self.assertTrue(asr_envelope.is_envelope_file(self.package))
        self.assertEqual(sha256_file(self.package), self.expected["packageSha256"])

    def test_decrypts_with_sqlite_identity_and_single_sqlite_entry(self):
        """identity=sqliteSha256 可解；内层恰一个 medical-catalog.sqlite,
        且其 sha256 同时等于 expected.sqliteSha256 与仓库 catalog.sqlite 实测值
        ——Go 导出 ↔ Python 正本 ↔ 公仓夹具 三方逐字节对账。"""
        plain = self.decrypt(self.package, self.expected["sqliteSha256"])
        with zipfile.ZipFile(io.BytesIO(plain)) as archive:
            names = archive.namelist()
            self.assertEqual(names, [self.expected["zipEntryName"]])
            inner = archive.read(names[0])
        inner_sha = hashlib.sha256(inner).hexdigest()
        self.assertEqual(inner_sha, self.expected["sqliteSha256"])
        self.assertEqual(inner_sha, sha256_file(self.catalog))

    def test_wrong_identity_fails_loudly(self):
        """错误 identity（翻一位 hex）必须认证失败——绝不解出垃圾（fail-closed）。"""
        wrong = ("0" if self.expected["sqliteSha256"][0] != "0" else "1") + self.expected["sqliteSha256"][1:]
        with self.assertRaises(ValueError):
            self.decrypt(self.package, wrong)

    def test_tampered_last_byte_fails_loudly(self):
        """末字节翻转（tag 尾）必须认证失败。"""
        tampered = bytearray(self.package.read_bytes())
        tampered[-1] ^= 0xFF
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "tampered.bin"
            path.write_bytes(bytes(tampered))
            with self.assertRaises(ValueError):
                self.decrypt(path, self.expected["sqliteSha256"])

    def test_truncated_header_fails_loudly(self):
        """截断头（<23B）必须拒绝而非分配/写出（Swift 侧同语义由 macOS L1 覆盖）。"""
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "truncated.bin"
            path.write_bytes(self.package.read_bytes()[:10])
            with self.assertRaises(ValueError):
                self.decrypt(path, self.expected["sqliteSha256"])


if __name__ == "__main__":
    unittest.main()
