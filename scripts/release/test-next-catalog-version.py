#!/usr/bin/env python3
"""next-catalog-version 单调推进回归（2026-10-07 锚点事故修复）。

事故：旧「按优先级首命中+1」在 repo=v7 / remote=v8 时输出 8 → 下次发布与远端
同版本 → 发布器等价歧义闸必红（37398352957 族，CI 浅克隆 + 仓库信封停滞）。
新语义 = max(全部来源 ∪ {地板 6}) + 1；远端非 404 异常（网络/5xx/形状）= 硬错，
绝不静默降版本。全程离线（fetch/git 注入）。
"""
import base64
import importlib.util
import json
import tempfile
import unittest
import urllib.error
from pathlib import Path

TOOL = Path(__file__).with_name("next-catalog-version.py")
_spec = importlib.util.spec_from_file_location("next_catalog_version", TOOL)
module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(module)


def envelope(version):
    payload = json.dumps({"catalogVersion": version}).encode()
    return json.dumps({"payload": base64.b64encode(payload).decode(), "signatures": [1]}).encode()


def fetch_returning(data):
    def fetch(url):
        assert url.endswith("/manifest.json"), url
        assert url.startswith("https://cnb.cool/owner/resources/"), url
        return data
    return fetch


def fetch_http_error(code):
    def fetch(url):
        raise urllib.error.HTTPError(url, code, "denied", {}, None)
    return fetch


class NextCatalogVersionTests(unittest.TestCase):
    def call(self, tmp, *, repo=None, remote=None, git=None, fetch=None):
        manifest = Path(tmp) / "manifest.json"
        if repo is not None:
            manifest.write_bytes(envelope(repo))
        if fetch is None:
            fetch = fetch_returning(envelope(remote)) if remote is not None else fetch_http_error(404)
        return module.next_catalog_version("owner/resources", fetch=fetch,
                                           git_versions=lambda: git, repo_manifest=str(manifest))

    def test_incident_repo7_remote8_yields_9(self):
        # 37398352957 事故矩阵：仓库信封停滞 v7、远端已是 v8——旧实现输出 8（必红）
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(self.call(tmp, repo=7, remote=8), 9)

    def test_higher_repo_wins(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(self.call(tmp, repo=9, remote=8), 10)

    def test_all_missing_keeps_floor_semantics(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(self.call(tmp), 7)

    def test_git_history_only_six_yields_seven(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(self.call(tmp, git=6), 7)

    def test_remote_404_falls_back_to_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(self.call(tmp, repo=7), 8)

    def test_remote_network_error_is_hard(self):
        def failing(url):
            raise urllib.error.URLError("dns down")
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(module.RemoteFetchError):
                self.call(tmp, repo=7, fetch=failing)

    def test_remote_5xx_is_hard(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(module.RemoteFetchError):
                self.call(tmp, fetch=fetch_http_error(500))

    def test_remote_non_envelope_is_hard(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(module.RemoteFetchError):
                self.call(tmp, repo=7, fetch=fetch_returning(b'{"not": "envelope"}'))

    def test_malformed_repo_envelope_warns_and_continues(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest = Path(tmp) / "manifest.json"
            manifest.write_bytes(b"garbage-not-json")
            self.assertEqual(module.next_catalog_version(
                "owner/resources", fetch=fetch_returning(envelope(8)),
                git_versions=lambda: None, repo_manifest=str(manifest)), 9)

    def test_combined_sources_take_max(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(self.call(tmp, repo=5, remote=8, git=6), 9)


if __name__ == "__main__":
    unittest.main()
