#!/usr/bin/env python3
"""Exercise package construction and validation using real ZIPs and independent fixtures."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile


TOOLS = Path(__file__).resolve().parent
ROLES = {
    "qwen3": ["frontend", "encoder", "decoder", "vocab", "merges", "tokenizerConfig", "notice"],
    "zipformer": ["encoder", "decoder", "joiner", "tokens", "bpe", "notice"],
    "dolphin": ["model", "tokens", "notice"],
    "whisper": ["encoder", "decoder", "tokens", "notice"],
}


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
            manifest["models"].append({"id": model_id, "revision": f"pinned-{model_id}",
                                       "license": license_name, "files": files})
            releases.append({"id": model_id, "version": "1.0.0", "builtAt": "20260912", "artifactRevision": 1,
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
        self.assertEqual(len(receipt["models"]), 4)
        for model in index["models"]:
            with zipfile.ZipFile(self.output / model["url"]) as archive:
                manifest = json.loads(archive.read("manifest.json"))
                self.assertEqual(manifest["models"][0]["revision"], "pinned-" + model["id"])
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

    def test_source_preparation_reuses_verified_release_assets(self):
        self.built_index()
        binaries = self.root / "bin"
        binaries.mkdir()
        gh = binaries / "gh"
        gh.write_text("#!/usr/bin/env python3\nimport os, pathlib, shutil, sys\na=sys.argv\n"
                      "name=a[a.index('--pattern')+1]\ndest=pathlib.Path(a[a.index('--dir')+1])\n"
                      "shutil.copyfile(pathlib.Path(os.environ['FIXTURE_PACKAGES'])/name, dest/name)\n")
        gh.chmod(0o755)
        target = self.root / "ci-source"
        env = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}", FIXTURE_PACKAGES=str(self.output))
        result = subprocess.run(["python3", str(TOOLS / "prepare-asr-source.py"), "--index", str(self.output / "index.json"),
                                 "--source", str(self.source), "--root", str(target), "--cache", str(self.root / "cache"),
                                 "--repository", "fixture/app"], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((target / "qwen3/encoder.onnx").read_bytes(), b"fixture:qwen3:encoder")


if __name__ == "__main__":
    unittest.main()
