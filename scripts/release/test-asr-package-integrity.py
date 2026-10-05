#!/usr/bin/env python3
"""Exercise package construction and validation using real ZIPs and independent fixtures."""
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
import zipfile

from asr_package import ASR_CATALOG_BUDGET_BYTES, MAX_PACKAGE, validate_index


TOOLS = Path(__file__).resolve().parent
ROLES = {
    "qwen3": ["frontend", "encoder", "decoder", "vocab", "merges", "tokenizerConfig", "notice"],
    "zipformer": ["encoder", "decoder", "joiner", "tokens", "bpe", "notice"],
    "dolphin": ["model", "tokens", "notice"],
    "whisper": ["encoder", "decoder", "tokens", "notice"],
}
# 与真实目录 index.json 的档位标注一致(2026-10-05 多档数据面)。
VARIANTS = {"qwen3": "medium", "zipformer": "large", "dolphin": "small", "whisper": "small"}


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.output = self.root / "output"
        self.index = self.root / "index.json"
        manifest = {"formatVersion": 1, "models": [], "shared": []}
        releases = []
        for model_id, roles in ROLES.items():
            files = []
            for role in roles:
                extension = {"notice": ".md", "vocab": ".json", "tokenizerConfig": ".json",
                             "tokens": ".txt", "merges": ".txt", "bpe": ".vocab"}.get(role, ".onnx")
                files.append(self.file_entry(f"{model_id}/{role}{extension}", role, f"fixture:{model_id}:{role}".encode()))
            license_name = "MIT" if model_id == "whisper" else "Apache-2.0"
            manifest["models"].append({"id": model_id, "variant": VARIANTS[model_id],
                                       "revision": f"pinned-{model_id}",
                                       "license": license_name, "files": files})
            releases.append({"id": model_id, "variant": VARIANTS[model_id], "version": "1.0.0",
                             "builtAt": "20260912", "artifactRevision": 1,
                             "license": license_name, "minAppVersion": "0.0.1"})
        manifest["shared"] = [self.file_entry("silero/vad.onnx", "vad", b"vad"),
                              self.file_entry("silero/LICENSE", "notice", b"vad license")]
        (self.source / "LICENSE-APACHE-2.0.txt").write_text("fixture Apache license")
        (self.source / "NOTICE.md").write_text("fixture notice")
        (self.source / "manifest.json").write_text(json.dumps(manifest))
        self.manifest = manifest
        self.index.write_text(json.dumps({"schemaVersion": 1, "app": "vitaliber", "assetKind": "asr",
                                         "baseUrl": "https://github.com/fixture/app/releases/download/asr-models",
                                         "models": releases}))

    def file_entry(self, name, role, data):
        target = self.source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        return {"role": role, "path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                "url": "https://example.test/" + name}

    def rewrite_inner_manifest_without_variant(self, model_id):
        """把已构建包的内清单剥掉 variant 键并更新索引(World A 遗留包形态)。"""
        index = json.loads((self.output / "index.json").read_text())
        model = next(m for m in index["models"] if m["id"] == model_id)
        package = self.output / model["url"]
        with zipfile.ZipFile(package, "r") as archive:
            contents = {name: archive.read(name) for name in archive.namelist()}
            infos = {name: archive.getinfo(name).file_size for name in archive.namelist()}
        manifest = json.loads(contents["manifest.json"])
        del manifest["models"][0]["variant"]
        contents["manifest.json"] = json.dumps(manifest).encode()
        with zipfile.ZipFile(package, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name in sorted(contents):
                archive.writestr(name, contents[name])
        infos["manifest.json"] = len(contents["manifest.json"])
        model["sha256"] = hashlib.sha256(package.read_bytes()).hexdigest()
        model["bytes"] = package.stat().st_size
        model["expandedBytes"] = sum(infos.values())
        (self.output / "index.json").write_text(json.dumps(index))
        return model

    def build(self):
        return subprocess.run(["python3", str(TOOLS / "build-asr-packages.py"), "--source-root", str(self.source),
                               "--index", str(self.index), "--output", str(self.output)], text=True, capture_output=True)

    def verify(self):
        return subprocess.run(["python3", str(TOOLS / "asr-package-integrity.py"), "--index", str(self.output / "index.json"),
                               "--directory", str(self.output), "--receipt", str(self.root / "receipt.json")],
                              text=True, capture_output=True)

    def built_index(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads((self.output / "index.json").read_text())

    def test_complete_packages_accept_separate_model_and_vad_notices(self):
        index = self.built_index()
        self.assertEqual({m["id"] for m in index["models"]}, set(ROLES))
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        receipt = json.loads((self.root / "receipt.json").read_text())
        self.assertEqual(len(receipt["models"]), len(index["models"]))
        for model in index["models"]:
            with zipfile.ZipFile(self.output / model["url"]) as archive:
                manifest = json.loads(archive.read("manifest.json"))
                expected = next(m["revision"] for m in self.manifest["models"]
                                if m["id"] == model["id"] and m.get("variant") == model.get("variant"))
                self.assertEqual(manifest["models"][0]["revision"], expected)
                self.assertEqual(manifest["models"][0].get("variant"), model.get("variant"))
                if model["id"] != "zipformer":
                    self.assertIn("silero/LICENSE", archive.namelist())

    def test_rebuild_ignores_input_mtime(self):
        first = self.built_index()
        for source in self.source.rglob("*"):
            if source.is_file():
                os.utime(source, (1_600_000_000, 1_600_000_000))
        second = self.built_index()
        self.assertEqual([(m["url"], m["sha256"]) for m in first["models"]],
                         [(m["url"], m["sha256"]) for m in second["models"]])

    def test_cache_download_locations_do_not_change_package_bytes(self):
        first = self.built_index()
        for model in self.manifest["models"]:
            for item in model["files"]:
                item["url"] = "https://another-cache.test/" + item["path"]
        (self.source / "manifest.json").write_text(json.dumps(self.manifest))
        second = self.built_index()
        self.assertEqual([m["sha256"] for m in first["models"]], [m["sha256"] for m in second["models"]])

    def test_missing_weight_fails(self):
        (self.source / "dolphin/model.onnx").unlink()
        result = self.build()
        self.assertNotEqual(result.returncode, 0)

    def test_legacy_inner_manifest_accepted_for_single_tier_family(self):
        # World A(2026-10-05 委员会):单档家族遗留包内清单无 variant 键——
        # 目录该家族仅一条条目,遗留包无歧义,放行以复用旧资产字节/旧 sha。
        self.built_index()
        self.rewrite_inner_manifest_without_variant("qwen3")
        self.assertEqual(self.verify().returncode, 0)

    def test_bad_archive_hash_fails(self):
        index = self.built_index()
        package = self.output / index["models"][0]["url"]
        with package.open("ab") as handle:
            handle.write(b"tampered")
        self.assertNotEqual(self.verify().returncode, 0)

    def test_validly_hashed_unsafe_zip_fails(self):
        for name, symlink in (("../escape", False), ("extra.py", False), ("dolphin/link", True)):
            with self.subTest(name=name):
                index = self.built_index()
                model = next(m for m in index["models"] if m["id"] == "dolphin")
                package = self.output / model["url"]
                with zipfile.ZipFile(package, "a") as archive:
                    info = zipfile.ZipInfo(name)
                    if symlink:
                        info.create_system = 3
                        info.external_attr = (0o120777 << 16)
                    archive.writestr(info, b"bad")
                data = package.read_bytes()
                model["sha256"] = hashlib.sha256(data).hexdigest()
                model["bytes"] = len(data)
                (self.output / "index.json").write_text(json.dumps(index))
                self.assertNotEqual(self.verify().returncode, 0)

    def test_zipformer_bundle_is_complete_without_large_models(self):
        self.built_index()
        bundle = self.output / "bundle/ASRModels"
        self.assertTrue((bundle / "zipformer/encoder.onnx").is_file())
        self.assertTrue((bundle / "manifest.json").is_file())
        self.assertFalse((bundle / "qwen3/decoder.onnx").exists())
        check = subprocess.run(["python3", str(TOOLS / "fetch-asr-models.py"), "--root", str(bundle), "--check"],
                               text=True, capture_output=True)
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        (bundle / "zipformer/encoder.onnx").unlink()
        missing = subprocess.run(["python3", str(TOOLS / "fetch-asr-models.py"), "--root", str(bundle), "--check"],
                                 text=True, capture_output=True)
        self.assertNotEqual(missing.returncode, 0)

    def test_signed_zip_reused_from_verified_release_instead_of_rebuild(self):
        first = self.built_index()
        signed = json.loads(self.index.read_text())
        signed["models"] = first["models"]   # 发布模板带签名 sha256
        (self.root / "signed-index.json").write_text(json.dumps(signed))
        rebuilt = self.root / "rebuilt"
        result = subprocess.run(["python3", str(TOOLS / "build-asr-packages.py"), "--source-root", str(self.source),
                                 "--index", str(self.root / "signed-index.json"), "--output", str(rebuilt),
                                 "--reuse-directory", str(self.output)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        second = json.loads((rebuilt / "index.json").read_text())
        for first_model, second_model in zip(first["models"], second["models"]):
            self.assertEqual((first_model["sha256"], first_model["bytes"]),
                             (second_model["sha256"], second_model["bytes"]))
            self.assertEqual((self.output / first_model["url"]).read_bytes(),
                             (rebuilt / second_model["url"]).read_bytes())

    def test_verified_release_packages_restore_the_pinned_build_tree(self):
        self.built_index()
        restored = self.root / "restored"
        result = subprocess.run(["python3", str(TOOLS / "materialize-asr-packages.py"),
                                 "--index", str(self.output / "index.json"), "--directory", str(self.output),
                                 "--source-manifest", str(self.source / "manifest.json"), "--root", str(restored)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((restored / "dolphin/model.onnx").read_bytes(), b"fixture:dolphin:model")
        self.assertEqual((restored / "manifest.json").read_bytes(), (self.source / "manifest.json").read_bytes())
        check = subprocess.run(["python3", str(TOOLS / "fetch-asr-models.py"), "--root", str(restored), "--check"],
                               text=True, capture_output=True)
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)

    def test_source_preparation_reuses_verified_cnb_assets(self):
        index = self.built_index()
        target = self.root / "ci-source"
        module = runpy.run_path(str(TOOLS / "prepare-asr-source.py"))

        def inventory(repository):
            return [{"name": m["url"],
                     "path": "/" + repository + "/-/releases/download/asr-models/" + m["url"],
                     "hashAlgo": "sha256", "hashValue": m["sha256"], "sizeInByte": m["bytes"]}
                    for m in index["models"]]

        def download(repository, asset, destination, expected_sha256, expected_size):
            data = (self.output / asset["name"]).read_bytes()
            self.assertEqual(len(data), expected_size)
            Path(destination).parent.mkdir(parents=True, exist_ok=True)
            Path(destination).write_bytes(data)
            return Path(destination)

        module["prepare"](index, self.output / "index.json", self.source, target,
                          self.root / "cache", "fixture/app",
                          inventory=inventory, download=download)
        self.assertEqual((target / "qwen3/encoder.onnx").read_bytes(), b"fixture:qwen3:encoder")
        check = subprocess.run(["python3", str(TOOLS / "fetch-asr-models.py"), "--root", str(target), "--check"],
                               text=True, capture_output=True)
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)


class MultiVariantPackageTests(PackageTests):
    """同家族多档管线回归:每家族两档(8 包),整套单档用例在 (id, variant) 形态下复跑。"""

    def setUp(self):
        super().setUp()
        for model_id, roles in ROLES.items():
            second = "small" if VARIANTS[model_id] != "small" else "medium"
            files = []
            for role in roles:
                extension = {"notice": ".md", "vocab": ".json", "tokenizerConfig": ".json",
                             "tokens": ".txt", "merges": ".txt", "bpe": ".vocab"}.get(role, ".onnx")
                files.append(self.file_entry(f"{model_id}-{second}/{role}{extension}", role,
                                             f"fixture:{model_id}:{second}:{role}".encode()))
            license_name = "MIT" if model_id == "whisper" else "Apache-2.0"
            self.manifest["models"].append({"id": model_id, "variant": second,
                                            "revision": f"pinned-{model_id}-{second}",
                                            "license": license_name, "files": files})
        releases = []
        for model in self.manifest["models"]:
            releases.append({"id": model["id"], "variant": model["variant"], "version": "1.0.0",
                             "builtAt": "20260912", "artifactRevision": 1,
                             "license": model["license"], "minAppVersion": "0.0.1"})
        self.index.write_text(json.dumps({"schemaVersion": 1, "app": "vitaliber", "assetKind": "asr",
                                          "baseUrl": "https://github.com/fixture/app/releases/download/asr-models",
                                          "models": releases}))
        (self.source / "manifest.json").write_text(json.dumps(self.manifest))

    def test_legacy_inner_manifest_accepted_for_single_tier_family(self):
        # 子类夹具每族双档:临时把 qwen3 裁成单档家族,验证 World A 放行语义
        # (基类同名用例在单档夹具上已覆盖)。
        self.built_index()
        index = json.loads((self.output / "index.json").read_text())
        index["models"] = [m for m in index["models"]
                           if not (m["id"] == "qwen3" and m["variant"] == "small")]
        (self.output / "index.json").write_text(json.dumps(index))
        self.rewrite_inner_manifest_without_variant("qwen3")
        self.assertEqual(self.verify().returncode, 0)

    def test_legacy_inner_manifest_rejected_for_multi_tier_family(self):
        # 多档家族的内清单必须带 variant——遗留形态在双档下无法无歧义归属。
        self.built_index()
        self.rewrite_inner_manifest_without_variant("qwen3")
        self.assertNotEqual(self.verify().returncode, 0)

    def test_multi_variant_packages_get_distinct_names_and_receipts(self):
        index = self.built_index()
        self.assertEqual(len(index["models"]), 8)
        urls = [m["url"] for m in index["models"]]
        self.assertEqual(len(set(urls)), len(urls))
        for model in index["models"]:
            self.assertIn("-" + model["variant"] + "-", model["url"])
        self.assertEqual(self.verify().returncode, 0)
        receipt = json.loads((self.root / "receipt.json").read_text())
        self.assertEqual(len(receipt["models"]), 8)
        self.assertEqual({(m["id"], m["variant"]) for m in receipt["models"]},
                         {(m["id"], m["variant"]) for m in index["models"]})


class MultiVariantValidationTests(unittest.TestCase):
    """validate_index 的多档规则单元面:身份/URL/档数/预算(2026-10-05 委员会)。"""

    def base_index(self):
        models = []
        for model_id in ("qwen3", "zipformer", "dolphin", "whisper"):
            models.append({"id": model_id, "variant": VARIANTS[model_id], "version": "1.0.0",
                           "url": f"{model_id}-{VARIANTS[model_id]}.zip", "bytes": 123, "sha256": "a" * 64})
        return {"schemaVersion": 1, "app": "vitaliber", "assetKind": "asr", "models": models}

    def test_twelve_entry_catalog_is_accepted(self):
        models = []
        for model_id in ("qwen3", "zipformer", "dolphin", "whisper"):
            for variant in ("small", "medium", "large"):
                models.append({"id": model_id, "variant": variant, "version": "1.0.0",
                               "url": f"{model_id}-{variant}.zip", "bytes": 123, "sha256": "a" * 64,
                               "license": "MIT" if model_id == "whisper" else "Apache-2.0"})
        validate_index({"schemaVersion": 1, "app": "vitaliber", "assetKind": "asr", "models": models})

    def test_same_identity_across_variants_is_rejected(self):
        index = self.base_index()
        clone = dict(index["models"][0], url="qwen3-medium-other.zip")
        index["models"].append(clone)
        with self.assertRaises(ValueError):
            validate_index(index)

    def test_duplicate_url_across_entries_is_rejected(self):
        index = self.base_index()
        for model in index["models"]:
            model["url"] = "same.zip"
        with self.assertRaises(ValueError):
            validate_index(index)

    def test_unknown_variant_is_rejected(self):
        index = self.base_index()
        index["models"][0]["variant"] = "tiny"
        with self.assertRaises(ValueError):
            validate_index(index)

    def test_four_tiers_per_family_is_rejected(self):
        index = self.base_index()
        index["models"].append(dict(index["models"][0], variant="small", url="extra.zip"))
        with self.assertRaises(ValueError):
            validate_index(index)

    def test_missing_family_is_rejected(self):
        index = self.base_index()
        index["models"] = [m for m in index["models"] if m["id"] != "whisper"]
        with self.assertRaises(ValueError):
            validate_index(index)

    def test_catalog_aggregate_budget_is_enforced(self):
        index = self.base_index()
        for model in index["models"]:
            model["bytes"] = MAX_PACKAGE
        with self.assertRaises(ValueError):
            validate_index(index)
        # 单包上限内但聚合超预算:预算常量才是多档目录的盖帽。
        index = self.base_index()
        for model in index["models"]:
            model["bytes"] = ASR_CATALOG_BUDGET_BYTES // 4 + 1
        with self.assertRaises(ValueError):
            validate_index(index)


if __name__ == "__main__":
    unittest.main()
