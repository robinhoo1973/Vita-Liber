#!/usr/bin/env python3
"""Offline publisher tests: the ASR release pipeline writes only to a CNB Release.

2026-10-03 plan Task 3: `publish(args, client)` accepts an injected CNB client;
the GitHub `gh` wrapper is gone entirely. No network access is performed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from types import SimpleNamespace

TOOL = Path(__file__).with_name("publish-asr-release.py")
CNB_BASE = "https://cnb.cool/robinhoo1973/Resources/-/releases/download/asr-models"
VARIANTS = {"qwen3": "medium", "zipformer": "large", "dolphin": "small", "whisper": "small",
            "sense-voice": "small", "fire-red": "large", "moonshine": "base"}


class FakeCNBReleaseClient:
    """Stateful fake: uploads are recorded only on real uploads, not on reuse."""

    def __init__(self, downloads=None):
        self.uploads = []
        self.assets = []
        self.downloads = downloads or {}

    def list_assets(self, tag):
        return [{"name": a["name"], "size": a["size"], "hash_algo": "sha256", "hash_value": a["sha256"],
                 "path": "/robinhoo1973/Resources/-/releases/download/" + tag + "/" + a["name"]}
                for a in self.assets]

    def upload_immutable(self, tag, path, asset_name, expected_sha256, overwrite=False):
        payload = Path(path).read_bytes()
        digest = hashlib.sha256(payload).hexdigest()
        if digest != expected_sha256:
            raise RuntimeError("digest mismatch for " + asset_name)
        for asset in self.assets:
            if asset["name"] == asset_name:
                if asset["sha256"] == digest and asset["size"] == len(payload):
                    return SimpleNamespace(name=asset_name, size=len(payload), sha256=digest)
                if not overwrite:
                    raise RuntimeError("collision for " + asset_name)
                # 2026-10-05 审查:发布路径以 overwrite=True 更新同名异内容
                # 模型资产(业主 R2:不同才更新上传)。
                asset["sha256"] = digest
                asset["size"] = len(payload)
                asset["content"] = payload
                self.uploads.append((asset_name, digest))
                return SimpleNamespace(name=asset_name, size=len(payload), sha256=digest)
        self.assets.append({"name": asset_name, "size": len(payload), "sha256": digest, "content": payload})
        self.uploads.append((asset_name, digest))
        return SimpleNamespace(name=asset_name, size=len(payload), sha256=digest)

    def download_asset(self, tag, asset_name, destination, max_bytes):
        if asset_name in self.downloads:
            data = self.downloads[asset_name]
        else:
            data = next((a["content"] for a in self.assets if a["name"] == asset_name), None)
        if data is None:
            raise RuntimeError("missing fixture download: " + asset_name)
        if len(data) > max_bytes:
            raise RuntimeError("fixture download exceeds bound: " + asset_name)
        Path(destination).write_bytes(data)
        return Path(destination)


def make_signed_asr_fixture(directory):
    """Signed root/catalog + verified packages, all pinned to the CNB resource base."""
    directory = Path(directory)
    packages_module = runpy.run_path(str(TOOL.with_name("test-asr-package-integrity.py")))
    trust_module = runpy.run_path(str(TOOL.with_name("test-model-trust.py")))
    packages = packages_module["PackageTests"]()
    packages.setUp()
    index = packages.built_index()
    index["baseUrl"] = CNB_BASE
    (packages.output / "index.json").write_text(json.dumps(index))
    trust = trust_module["TrustTests"]()
    trust.setUp()
    trust.root_payload["assetBaseURL"] = CNB_BASE
    trust.root_payload["allowedHosts"] = ["cnb.cool", "asset.cnb.cool"]
    trust.catalog_payload["index"] = index
    sign = trust_module["envelope"]
    root_file = trust.write("1.root.json", sign(trust.root_payload, trust.keys[:2]))
    catalog_file = trust.write("3.catalog.json", sign(trust.catalog_payload, trust.keys[3:5]))
    options = argparse.Namespace(index=packages.output / "index.json", directory=packages.output,
                                 root=root_file, catalog=catalog_file,
                                 repository="robinhoo1973/Resources")
    return packages, trust, trust_module, options


class PublicationTests(unittest.TestCase):
    def plan(self, assets):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            index = {"schemaVersion": 1, "app": "vitaliber", "assetKind": "asr",
                     "families": [{"id": m, "name": {"zh-Hans": m}, "hint": {"zh-Hans": "fixture hint"},
                                   "languages": ["zh"], "dialects": []} for m in VARIANTS],
                     "models": [
                {"id": m, "variant": VARIANTS[m], "version": "1.0.0", "url": m + ".zip",
                 "bytes": 123, "sha256": "a" * 64,
                 "license": "MIT" if m in {"whisper", "sense-voice", "fire-red"} else "Apache-2.0",
                 "tierName": {"zh-Hans": "档"}, "tierHint": {"zh-Hans": "fixture tier"}}
                for m in VARIANTS]}
            (root / "index.json").write_text(json.dumps(index))
            (root / "assets.json").write_text(json.dumps(assets))
            return subprocess.run(["python3", str(TOOL), "plan", "--index", str(root / "index.json"),
                                   "--assets", str(root / "assets.json")], text=True, capture_output=True)

    @staticmethod
    def cnb_asset(name, size, digest):
        return {"name": name, "size": size,
                "hash_algo": "sha256", "hash_value": digest} if digest else {"name": name, "size": size}

    def test_all_missing_packages_are_uploaded(self):
        result = self.plan([])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"qwen3.zip": "upload", "zipformer.zip": "upload",
                                                     "dolphin.zip": "upload", "whisper.zip": "upload",
                                                     "sense-voice.zip": "upload", "fire-red.zip": "upload",
                                                     "moonshine.zip": "upload"})

    def test_same_content_is_reused(self):
        result = self.plan([self.cnb_asset("qwen3.zip", 123, "a" * 64)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["qwen3.zip"], "reuse")

    def test_same_name_different_content_is_never_overwritten(self):
        for size, digest in ((124, "a" * 64), (123, "b" * 64)):
            with self.subTest(size=size):
                result = self.plan([self.cnb_asset("qwen3.zip", size, digest)])
                self.assertNotEqual(result.returncode, 0)

    def test_missing_server_digest_requires_download_verification(self):
        result = self.plan([self.cnb_asset("qwen3.zip", 123, None)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["qwen3.zip"], "verify")

    def test_publish_uses_cnb_and_has_no_github_writer(self):
        module = runpy.run_path(str(TOOL))
        self.assertFalse(hasattr(module, "gh"))
        with tempfile.TemporaryDirectory() as directory:
            packages, trust, _, options = make_signed_asr_fixture(Path(directory))
            self.addCleanup(packages.doCleanups)
            self.addCleanup(trust.doCleanups)
            client = FakeCNBReleaseClient()
            module["publish"](options, client)
            names = {asset for asset, _ in client.uploads}
            models = json.loads(options.index.read_text())["models"]
            # 单一 JSON 架构(2026-10-06 业主裁定):资产面 = 模型包 + index.json;
            # 根/版本化目录/回执不再上传。
            self.assertTrue({m["url"] for m in models} | {"index.json"} <= names)
            self.assertFalse(any(name.endswith(".root.json") or name.endswith(".catalog.json")
                                 or name.endswith("package-validation.json") for name in names))

    def test_publish_overwrites_same_name_different_content_model(self):
        # 业主 R2(2026-10-05/06):同名异内容模型资产按 overwrite 更新上传——
        # 发布路径不再被 publication_plan 的硬错挡住(plan 子命令仍保
        # 规划期拒绝语义,见 plan 用例)。
        module = runpy.run_path(str(TOOL))
        with tempfile.TemporaryDirectory() as directory:
            packages, trust, _, options = make_signed_asr_fixture(Path(directory))
            self.addCleanup(packages.doCleanups)
            self.addCleanup(trust.doCleanups)
            client = FakeCNBReleaseClient()
            module["publish"](options, client)
            first_uploads = list(client.uploads)
            target = next(m["url"] for m in json.loads(options.index.read_text())["models"])
            tampered = next(a for a in client.assets if a["name"] == target)
            tampered["content"] = b"rebuilt-with-different-bytes"
            tampered["size"] = len(tampered["content"])
            tampered["sha256"] = hashlib.sha256(tampered["content"]).hexdigest()
            # 目录/根/回执同名同内容 → 跳过;模型同名异内容 → 走更新上传。
            module["publish"](options, client)
            second = [name for name, _ in client.uploads]
            self.assertEqual(len(second), len(first_uploads) + 1)
            self.assertIn(target, second)
            updated = next(a for a in client.assets if a["name"] == target)
            self.assertEqual(updated["sha256"], tampered["sha256"])

    def test_publish_rejects_tampered_remote_index_bytes(self):
        # 单一 JSON 架构(2026-10-06 业主裁定):远端 index.json 被篡改 = 验签
        # 硬错(同版本异字节等价歧义闸亦在链校验内),不静默覆写。
        module = runpy.run_path(str(TOOL))
        with tempfile.TemporaryDirectory() as directory:
            packages, trust, _, options = make_signed_asr_fixture(Path(directory))
            self.addCleanup(packages.doCleanups)
            self.addCleanup(trust.doCleanups)
            client = FakeCNBReleaseClient()
            module["publish"](options, client)
            tampered = next(a for a in client.assets if a["name"] == "index.json")
            tampered["content"] = b"tampered-index"
            tampered["size"] = len(tampered["content"])
            tampered["sha256"] = hashlib.sha256(tampered["content"]).hexdigest()
            with self.assertRaises((RuntimeError, ValueError)):
                module["publish"](options, client)

    def test_second_publish_is_idempotent_reuse(self):
        module = runpy.run_path(str(TOOL))
        with tempfile.TemporaryDirectory() as directory:
            packages, trust, _, options = make_signed_asr_fixture(Path(directory))
            self.addCleanup(packages.doCleanups)
            self.addCleanup(trust.doCleanups)
            client = FakeCNBReleaseClient()
            module["publish"](options, client)
            first_uploads = list(client.uploads)
            module["publish"](options, client)
            self.assertEqual(client.uploads, first_uploads)  # 复用路径不产生新上传

    def test_same_version_different_payload_equivocation_rejected(self):
        module = runpy.run_path(str(TOOL))
        with tempfile.TemporaryDirectory() as directory:
            packages, trust, trust_module, options = make_signed_asr_fixture(Path(directory))
            self.addCleanup(packages.doCleanups)
            tampered = dict(trust.catalog_payload)
            tampered["index"] = dict(trust.catalog_payload["index"])
            tampered["index"]["models"] = tampered["index"]["models"][:-1]
            equivocation = trust_module["envelope"](tampered, trust.keys[3:5])
            equivocation_bytes = json.dumps(equivocation).encode()
            client = FakeCNBReleaseClient(downloads={"index.json": equivocation_bytes})
            # 远程清单必须可见该目录资产,链校验才进入比对分支
            client.assets.append({"name": "index.json", "size": len(equivocation_bytes),
                                  "sha256": hashlib.sha256(equivocation_bytes).hexdigest(),
                                  "content": equivocation_bytes})
            with self.assertRaises(ValueError):
                module["publish"](options, client)


if __name__ == "__main__":
    unittest.main()
