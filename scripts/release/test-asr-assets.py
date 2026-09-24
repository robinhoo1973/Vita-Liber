import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import tarfile
import unittest

spec = importlib.util.spec_from_file_location("assets", Path(__file__).with_name("fetch-asr-models.py"))
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


class ASRAssetsTests(unittest.TestCase):
    def test_bundle_manifest_must_match_git_source_except_bundled_profile(self):
        # S-M7：build job 的 --check 读的是 artifact 覆盖后的清单；必须证明它与本提交的
        # 钉版清单同源——只允许多出 bundledModels 档位，其他任何差异都拒绝。
        source = {"formatVersion": 1, "models": [{"id": "zipformer", "files": []}], "shared": []}
        bundle = dict(source, bundledModels=["zipformer"])
        assets.require_same_source_manifest(bundle, source)
        with self.assertRaises(ValueError):
            assets.require_same_source_manifest(dict(source, bundledModels=["zipformer"], models=[]), source)
        with self.assertRaises(ValueError):
            assets.require_same_source_manifest(dict(source), source)  # 缺 bundledModels 不是随包档位清单

    def test_ipa_inspection_requires_embedded_model_baseline(self):
        # S-M8：设计 §2.4 要求最终 IPA 内嵌可解析且非空的 TrustedModelHashes 基线。
        spec = importlib.util.spec_from_file_location("reconcile", Path(__file__).with_name("reconcile-frameworks.py"))
        reconcile = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(reconcile)
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Payload" / "VitaLiber.app"
            app.mkdir(parents=True)
            with self.assertRaises(ValueError):
                reconcile.require_embedded_baseline(app)
            baseline = app / "TrustedModelHashes.json"
            baseline.write_text(json.dumps({"schemaVersion": 1, "entries": [], "revokedHashes": []}))
            with self.assertRaises(ValueError):
                reconcile.require_embedded_baseline(app)
            baseline.write_text(json.dumps({"schemaVersion": 1, "entries": [{"id": "zipformer", "sha256": "a" * 64}]}))
            with self.assertRaises(ValueError):
                reconcile.require_embedded_baseline(app)
            baseline.write_text(json.dumps({"schemaVersion": 1, "entries": [{"id": "zipformer", "sha256": "a" * 64}], "revokedHashes": []}))
            reconcile.require_embedded_baseline(app)

    def test_corrupt_cached_file_is_not_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "model.onnx"
            path.write_bytes(b"bad!")
            item = {"bytes": 4, "sha256": hashlib.sha256(b"good").hexdigest()}
            self.assertFalse(assets.valid_file(path, item))
            path.write_bytes(b"good")
            self.assertTrue(assets.valid_file(path, item))

    def test_manifest_cannot_write_outside_resource_folder(self):
        item = {"path": "../model.onnx", "role": "model", "url": "https://example.com/model", "bytes": 4, "sha256": "0" * 64}
        with self.assertRaises(ValueError):
            assets.validate_entries([item])

    def test_check_does_not_download_missing_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            item = {"path": "model.onnx", "role": "model", "url": "https://invalid.example/model", "bytes": 4, "sha256": "0" * 64}
            with self.assertRaises(ValueError):
                assets.ensure_file(root, item, check_only=True)
            self.assertEqual(list(root.iterdir()), [])

    def test_archive_cannot_install_a_symlink_as_a_model(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_path = root / "source.tar.bz2"
            with tarfile.open(archive_path, "w:bz2") as archive:
                member = tarfile.TarInfo("models/decoder.onnx")
                member.type = tarfile.SYMTYPE
                member.linkname = "/etc/passwd"
                archive.addfile(member)
            config = {"root": "models", "url": "https://example.com/models.tar.bz2",
                "parts": [{"role": "decoder", "member": "decoder.onnx", "path": "out/decoder.onnx"}]}
            with self.assertRaises(ValueError):
                assets.extract_parts(root, archive_path, config)
            self.assertFalse((root / "out").exists())

    def test_cache_omitting_a_required_decoder_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "encoder").write_bytes(b"ok")
            config = {"sha256": "a" * 64, "parts": [{"role": "encoder", "path": "encoder"}, {"role": "decoder", "path": "decoder"}]}
            old = {"id": "qwen3", "archive": config, "files": [{"role": "encoder", "path": "encoder", "bytes": 2, "sha256": hashlib.sha256(b"ok").hexdigest()}]}
            with self.assertRaises(ValueError):
                assets.ensure_archive(root, {"id": "qwen3", "archive": config}, {"models": [old]}, check_only=True)


if __name__ == "__main__":
    unittest.main()
