#!/usr/bin/env python3
"""Offline tests for the one-time GitHub→CNB asset seed (2026-10-03 plan Task 2).

No network: the source and the CNB client are fakes; --plan stays side-effect free
and a digest mismatch prevents every upload.
"""
import base64
import hashlib
import json
from pathlib import Path
import runpy
import tempfile
import unittest

seed_module = runpy.run_path(str(Path(__file__).with_name("seed-cnb-model-assets.py")))
SeedAssetError = seed_module["SeedAssetError"]
asr_expectations = seed_module["asr_expectations"]
execute_plan = seed_module["execute_plan"]
legacy_github_name = seed_module["legacy_github_name"]
plan_assets = seed_module["plan_assets"]


def fixture_catalog(index_models):
    payload = {"schemaVersion": 1, "role": "catalog", "app": "vitaliber", "assetKind": "asr",
               "rootVersion": 2, "catalogVersion": 5,
               "index": {"schemaVersion": 1, "app": "vitaliber", "assetKind": "asr", "models": index_models},
               "revokedHashes": []}
    return {"payload": base64.b64encode(json.dumps(payload).encode()).decode(), "signatures": []}


class FakeSource:
    def __init__(self, assets):
        self.assets = assets
        self.calls = []

    def __call__(self, tag, name, destination, max_bytes):
        self.calls.append(name)
        if name not in self.assets:
            raise SeedAssetError("missing fixture asset: " + name)
        data = self.assets[name]
        path = Path(destination) / name
        path.write_bytes(data)
        return path


class FakeCNBReleaseClient:
    def __init__(self):
        self.uploads = []

    def upload_immutable(self, tag, path, asset_name, expected_sha256, overwrite=False):
        self.uploads.append((asset_name, hashlib.sha256(Path(path).read_bytes()).hexdigest()))


class SeedTests(unittest.TestCase):
    def models(self, sha=None, bytes_=None):
        return [{"id": "zipformer", "variant": "large", "version": "2023-02-20",
                 "url": "zipformer-large-2023-02-20-20260912-r2.zip",
                 "bytes": bytes_ if bytes_ is not None else 7,
                 "sha256": sha or hashlib.sha256(b"fixture").hexdigest()}]

    def test_legacy_name_derivation_matches_the_four_adopted_models(self):
        cases = [("zipformer-large-2023-02-20-20260912-r2.zip", "large", "zipformer-2023-02-20-20260912-r2.zip"),
                 ("qwen3-medium-0.6b-int8-v2026.03.25-20260912-r2.zip", "medium", "qwen3-0.6b-int8-v2026.03.25-20260912-r2.zip"),
                 ("dolphin-small-small-ctc-int8-2025-04-02-20260912-r2.zip", "small", "dolphin-small-ctc-int8-2025-04-02-20260912-r2.zip"),
                 ("whisper-small-small-int8-2024-07-13-20260912-r2.zip", "small", "whisper-small-int8-2024-07-13-20260912-r2.zip")]
        for cnb_name, variant, expected in cases:
            self.assertEqual(legacy_github_name(cnb_name, variant), expected)

    def test_plan_rejects_bad_digest_without_any_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            data = b"fixture-model"
            source = FakeSource({"zipformer-2023-02-20-20260912-r2.zip": data})
            cnb = FakeCNBReleaseClient()
            # 期望 sha 与下载字节不一致:plan 必须拒绝且零上传
            models = self.models(sha=hashlib.sha256(b"expected-bytes").hexdigest())
            catalog_path = Path(directory) / "catalog.json"
            legacy_path = Path(directory) / "legacy.json"
            catalog_path.write_text(json.dumps(fixture_catalog(models)))
            legacy_path.write_text(json.dumps({"models": [
                {"id": "zipformer", "sha256": hashlib.sha256(b"expected-bytes").hexdigest(),
                 "url": "zipformer-2023-02-20-20260912-r2.zip"}]}))
            expectations = asr_expectations(catalog_path, legacy_path)
            with self.assertRaises(SeedAssetError):
                plan_assets("asr-models", source, expectations, Path(directory))
            self.assertEqual(cnb.uploads, [])

    def test_plan_and_execute_upload_only_after_full_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            data = b"fixture-model"
            digest = hashlib.sha256(data).hexdigest()
            source = FakeSource({"zipformer-2023-02-20-20260912-r2.zip": data})
            cnb = FakeCNBReleaseClient()
            models = self.models(sha=digest, bytes_=len(data))
            catalog_path = Path(directory) / "catalog.json"
            legacy_path = Path(directory) / "legacy.json"
            catalog_path.write_text(json.dumps(fixture_catalog(models)))
            legacy_path.write_text(json.dumps({"models": [
                {"id": "zipformer", "sha256": digest, "url": "zipformer-2023-02-20-20260912-r2.zip"}]}))
            expectations = asr_expectations(catalog_path, legacy_path)
            staged = plan_assets("asr-models", source, expectations, Path(directory))
            self.assertEqual(cnb.uploads, [])
            execute_plan(cnb, "asr-models", staged, expectations)
            self.assertEqual(cnb.uploads, [("zipformer-large-2023-02-20-20260912-r2.zip", digest)])

    def test_variant_absent_from_name_leaves_it_unchanged(self):
        # 名字里没有 `-{variant}-` 段时推导不碰它(seed 的 sha 校验会 fail-closed)。
        self.assertEqual(legacy_github_name("zipformer-2023-02-20-20260912-r2.zip", "large"),
                         "zipformer-2023-02-20-20260912-r2.zip")

    def test_missing_legacy_match_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            models = self.models()
            catalog_path = Path(directory) / "catalog.json"
            legacy_path = Path(directory) / "legacy.json"
            catalog_path.write_text(json.dumps(fixture_catalog(models)))
            legacy_path.write_text(json.dumps({"models": []}))
            with self.assertRaises(SeedAssetError):
                asr_expectations(catalog_path, legacy_path)


if __name__ == "__main__":
    unittest.main()
