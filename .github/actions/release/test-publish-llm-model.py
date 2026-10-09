#!/usr/bin/env python3
"""Offline tests for publish-llm-model.py（2026-10-09 换型+下载化批）。

Never performs network access: covers the pure helpers (asset naming, URL derivation,
source-host whitelist) and asserts the **repo catalog** stays consistent with the
publisher's deterministic derivation — a mismatch here would mean the app would
download from a URL the publisher never writes (silent 404 at runtime).
"""
import importlib.util
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE
while ROOT != ROOT.parent and not (ROOT / "CoreKit" / "Sources" / "Domain").is_dir():
    ROOT = ROOT.parent

spec = importlib.util.spec_from_file_location("publish_llm_model", HERE / "publish-llm-model.py")
assert spec and spec.loader
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class AssetNamingTests(unittest.TestCase):
    def test_asset_name_is_content_addressed(self):
        entry = {"id": "llm-general-qwen3-0.6b-q4-k-m",
                 "sha256": "ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a"}
        self.assertEqual(publisher.asset_name_for(entry),
                         "llm-general-qwen3-0.6b-q4-k-m-ac2d97712095a558.gguf")

    def test_expected_url_shape(self):
        entry = {"id": "m", "sha256": "0" * 64}
        self.assertEqual(
            publisher.expected_cnb_url(entry, "owner/repo"),
            "https://cnb.cool/owner/repo/-/releases/download/llama-models/m-" + "0" * 16 + ".gguf")


class RepoCatalogConsistencyTests(unittest.TestCase):
    """仓库目录的 url 必须等于发布器推导值（否则运行时 404 静默）。"""

    def test_repo_catalog_urls_match_derivation(self):
        import json
        catalog_path = ROOT / "Resources" / "LLMCatalog" / "catalog.json"
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        self.assertTrue(catalog["models"], "catalog 为空——发布面无货")
        for entry in catalog["models"]:
            with self.subTest(entry=entry["id"]):
                self.assertEqual(entry["url"],
                                 publisher.expected_cnb_url(entry, publisher.DEFAULT_REPOSITORY))


class SourceWhitelistTests(unittest.TestCase):
    def test_accepts_https_whitelisted_hosts(self):
        self.assertTrue(publisher.source_allowed(
            "https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/x.gguf"))
        self.assertTrue(publisher.source_allowed(
            "https://cdn-lfs.huggingface.co/repos/x"))
        self.assertTrue(publisher.source_allowed(
            "https://github.com/ggml-org/llama.cpp/releases/download/b11012/x.gguf"))

    def test_rejects_other_schemes_hosts_ports_credentials(self):
        self.assertFalse(publisher.source_allowed("http://huggingface.co/x"))
        self.assertFalse(publisher.source_allowed("https://evil.example/x"))
        self.assertFalse(publisher.source_allowed("https://huggingface.co.evil.example/x"))
        self.assertFalse(publisher.source_allowed("https://huggingface.co:8443/x"))
        self.assertFalse(publisher.source_allowed("https://user:pass@huggingface.co/x"))


if __name__ == "__main__":
    unittest.main()
