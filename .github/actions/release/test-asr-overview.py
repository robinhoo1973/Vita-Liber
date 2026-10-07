#!/usr/bin/env python3
"""test-asr-overview：ASR 人读概览生成器三面钉（2026-10-07 恢复批，纯离线）。

面 1 纯函数确定性 + 内容完备；面 2 自验拒篡改；面 3 CLI 信封往返
（生产调用形状：publish 以签名信封为输入）。
"""
import base64
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from asr_overview import build, verify
from asr_package import json_bytes

TOOLS = Path(__file__).resolve().parent


def _payload():
    return {
        "schemaVersion": 1, "role": "catalog", "app": "vitaliber", "assetKind": "asr",
        "catalogVersion": 7, "issuedAt": "2026-10-07T00:00:00Z",
        "expiresAt": "2026-11-06T00:00:00Z", "rootVersion": 1, "revokedHashes": [],
        "index": {
            "families": [
                {"id": "whisper", "name": {"zh-Hans": "Whisper"},
                 "languages": ["zh", "en"], "dialects": []},
            ],
            "models": [
                {"id": "whisper", "variant": "tiny", "version": "2024-07-13",
                 "artifactRevision": 2, "bytes": 62083183, "expandedBytes": 105944625,
                 "license": "MIT", "tierName": {"zh-Hans": "极轻"},
                 "tierHint": {"zh-Hans": "hint"}, "url": "whisper-tiny.zip",
                 "sha256": "a" * 64, "packaging": "zip",
                 "encryption": "aes256gcm-v1", "packageSignature": {"x": 1}},
            ],
        },
    }


class AsrOverviewTests(unittest.TestCase):
    def test_build_is_deterministic_and_complete(self):
        payload_bytes = json_bytes(_payload())
        one, two = build(payload_bytes), build(payload_bytes)
        self.assertEqual(one, two, "概览必须是签名载荷的纯函数（可重跑同字节）")
        doc = json.loads(one)
        self.assertEqual(doc["kind"], "asr-overview")
        self.assertEqual(doc["catalogVersion"], 7)
        self.assertEqual(doc["issuedAt"], "2026-10-07T00:00:00Z")
        self.assertEqual(doc["totals"], {"families": 1, "tiers": 1,
                                         "bytes": 62083183, "expandedBytes": 105944625})
        tier = doc["tiers"][0]
        self.assertEqual((tier["id"], tier["variant"]), ("whisper", "tiny"))
        # 非权威面：不携带包摘要与包级签名（权威一律在签名目录）。
        self.assertNotIn("sha256", tier)
        self.assertNotIn("packageSignature", tier)

    def test_verify_rejects_tamper(self):
        payload_bytes = json_bytes(_payload())
        tampered = bytearray(build(payload_bytes))
        tampered[10] ^= 1
        with self.assertRaises(ValueError):
            verify(bytes(tampered), payload_bytes)

    def test_changes_block_and_previous_payload_roundtrip(self):
        current = _payload()
        current["catalogVersion"] = 8
        previous = json.loads(json.dumps(_payload()))  # catalogVersion 7
        previous["index"]["models"].append({
            "id": "whisper", "variant": "base", "version": "2024-07-13",
            "sha256": "b" * 64, "license": "MIT",
            "tierName": {"zh-Hans": "微轻"}, "tierHint": {"zh-Hans": "h"}})
        current["index"]["models"].append({
            "id": "whisper", "variant": "small", "version": "2024-07-13",
            "sha256": "c" * 64, "license": "MIT",
            "tierName": {"zh-Hans": "轻量"}, "tierHint": {"zh-Hans": "h"}})
        current["index"]["models"][0]["sha256"] = "d" * 64  # tiny 更新
        one = build(json_bytes(current), previous)
        two = build(json_bytes(current), previous)
        self.assertEqual(one, two, "带 previous 的概览必须仍是纯函数（重跑同字节）")
        changes = json.loads(one)["changes"]
        self.assertEqual(changes["fromCatalogVersion"], 7)
        self.assertEqual(changes["added"], [{"id": "whisper", "variant": "small"}])
        self.assertEqual(changes["removed"], [{"id": "whisper", "variant": "base"}])
        self.assertEqual(changes["updated"][0]["fromVersion"], "2024-07-13")
        verify(one, json_bytes(current), previous)
        with self.assertRaises(ValueError):
            verify(one, json_bytes(current), None)

    def test_first_publish_changes_is_null(self):
        doc = json.loads(build(json_bytes(_payload())))
        self.assertIsNone(doc["changes"])

    def test_family_strengths_limitations_pass_through(self):
        payload = _payload()
        payload["index"]["families"][0]["strengths"] = {"zh-Hans": "强项"}
        payload["index"]["families"][0]["limitations"] = {"zh-Hans": "局限"}
        doc = json.loads(build(json_bytes(payload)))
        self.assertEqual(doc["families"][0]["strengths"], {"zh-Hans": "强项"})
        self.assertEqual(doc["families"][0]["limitations"], {"zh-Hans": "局限"})

    def test_cli_envelope_roundtrip(self):
        payload = json_bytes(_payload())
        envelope = json_bytes({"payload": base64.b64encode(payload).decode(),
                               "signatures": []})
        with tempfile.TemporaryDirectory() as td:
            catalog = Path(td) / "manifest.json"
            catalog.write_bytes(envelope)
            output = Path(td) / "overview.json"
            result = subprocess.run(
                ["python3", str(TOOLS / "asr_overview.py"),
                 "--catalog", str(catalog), "--output", str(output)],
                text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            doc = json.loads(output.read_bytes())
            self.assertEqual(doc["totals"]["tiers"], 1)


if __name__ == "__main__":
    unittest.main()
