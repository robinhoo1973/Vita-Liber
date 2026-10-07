#!/usr/bin/env python3
"""test-bootstrap-asr-model：bootstrap 纯函数面钉（2026-10-08，纯离线）。

角色推断 / 身份推断（family+variant 令牌扫描）/ 成员筛选 / 许可启发 /
逆测对账（match/mismatch/cosmetic 三分——「从名字可复得人工钉版」的可测面）。
"""
from pathlib import Path
import runpy
import unittest

TOOLS = Path(__file__).resolve().parent
MODULE = runpy.run_path(str(TOOLS / "bootstrap-asr-model.py"))


class BootstrapTests(unittest.TestCase):
    def test_infer_role(self):
        infer = MODULE["infer_role"]
        cases = {
            "preprocess.onnx": "preprocessor",
            "encode.int8.onnx": "encoder",
            "uncached_decode.int8.onnx": "uncachedDecoder",
            "cached_decode.int8.onnx": "cachedDecoder",
            "conv_frontend.onnx": "frontend",
            "encoder-epoch-99-avg-1.int8.onnx": "encoder",
            "decoder-epoch-99-avg-1.onnx": "decoder",
            "joiner-epoch-99-avg-1.int8.onnx": "joiner",
            "model.int8.onnx": "model",
            "tiny-encoder.int8.onnx": "encoder",
            "tiny-decoder.int8.onnx": "decoder",
            "tiny-tokens.txt": "tokens",
            "MODEL_LICENSE": "notice",
            "tokens.txt": "tokens",
            "bpe.vocab": "bpe",
            "vocab.json": "vocab",
            "merges.txt": "merges",
            "tokenizer_config.json": "tokenizerConfig",
            "LICENSE": "notice",
            "README.md": "notice",
            "test_wavs/0.wav": None,
            ".gitattributes": None,
        }
        for member, role in cases.items():
            self.assertEqual(infer(member), role, member)

    def test_infer_identity(self):
        infer = MODULE["infer_identity"]
        self.assertEqual(infer("csukuangfj/sherpa-onnx-whisper-turbo"), ("whisper", "turbo"))
        self.assertEqual(infer("csukuangfj/sherpa-onnx-moonshine-tiny-en-int8"),
                         ("moonshine", "tiny"))
        self.assertEqual(infer("csukuangfj/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23"),
                         ("zipformer", None))
        self.assertEqual(infer("csukuangfj/sherpa-onnx-dolphin-base-ctc-multi-lang-int8-2025-04-02"),
                         ("dolphin", "base"))
        with self.assertRaises(MODULE["BootstrapError"]):
            infer("someone/random-model")

    def test_member_selected(self):
        selected = MODULE["member_selected"]
        self.assertTrue(selected("encode.int8.onnx"))
        self.assertFalse(selected("test_wavs/0.wav"))
        self.assertFalse(selected(".gitattributes"))

    def test_infer_license(self):
        infer = MODULE["infer_license"]
        self.assertEqual(infer(["MIT License\nCopyright ..."]), "MIT")
        self.assertEqual(infer(["Permission is hereby granted, free of charge"]), "MIT")
        self.assertEqual(infer(["Apache License\nVersion 2.0, January 2004"]), "Apache-2.0")
        self.assertIsNone(infer(["All rights reserved"]))

    def test_prefer_license_notice(self):
        prefer = MODULE["prefer_license_notice"]
        files = [{"role": "notice", "member": "README.md"},
                 {"role": "notice", "member": "LICENSE"},
                 {"role": "encoder", "member": "encode.int8.onnx"}]
        kept = prefer(files)
        self.assertEqual([f["member"] for f in kept], ["LICENSE", "encode.int8.onnx"],
                         "有 LICENSE 时弃 README 兜底")
        only_readme = [{"role": "notice", "member": "README.md"},
                       {"role": "encoder", "member": "encode.int8.onnx"}]
        self.assertEqual(prefer(only_readme), only_readme, "无许可文本时保留 README 兜底")

    def test_compare_entry(self):
        compare = MODULE["compare_entry"]
        draft = {"id": "whisper", "variant": "tiny", "license": "MIT", "revision": "a" * 40,
                 "watch": {"kind": "hf-repo", "repo": "csukuangfj/sherpa-onnx-whisper-tiny"},
                 "files": [{"role": "encoder", "path": "whisper-tiny/tiny-encoder.int8.onnx",
                            "member": "tiny-encoder.int8.onnx", "bytes": 10, "sha256": "1" * 64}]}
        existing = {"id": "whisper", "variant": "tiny", "license": "MIT", "revision": "a" * 40,
                    "watch": {"repo": "csukuangfj/sherpa-onnx-whisper-tiny"},
                    "files": [{"role": "encoder", "path": "whisper/tiny-encoder.int8.onnx",
                               "member": "tiny-encoder.int8.onnx", "bytes": 10, "sha256": "1" * 64}]}
        report = compare(draft, existing)
        self.assertEqual(report["mismatch"], [], "同内容不同路径约定只算外观差异")
        self.assertTrue(report["cosmetic"], "路径约定差异必须入 cosmetic")
        existing["files"][0]["sha256"] = "2" * 64
        report = compare(draft, existing)
        self.assertTrue(any("tiny-encoder" in line for line in report["mismatch"]))

    def test_drift_check_hf_repo(self):
        check = MODULE["drift_check"]
        entry = {"id": "whisper", "variant": "tiny", "revision": "a" * 40,
                 "watch": {"kind": "hf-repo", "repo": "r/x"},
                 "files": [{"role": "encoder", "member": "tiny-encoder.int8.onnx",
                            "path": "p", "bytes": 1, "sha256": "1" * 64}]}

        def fetch_ok(url):
            return {"sha": "a" * 40,
                    "siblings": [{"rfilename": "tiny-encoder.int8.onnx"},
                                 {"rfilename": ".gitattributes"},
                                 {"rfilename": "README.md"}]}

        row = check(entry, fetch_json=fetch_ok)
        self.assertEqual(row["status"], "ok", row["findings"])

        def fetch_moved(url):
            return {"sha": "b" * 40,
                    "siblings": [{"rfilename": "tiny-encoder.int8.onnx"},
                                 {"rfilename": "tiny-encoder.fp32.onnx"}]}

        row = check(entry, fetch_json=fetch_moved)
        self.assertEqual(row["status"], "ok", "修订滚动=info 非 drift")
        messages = " ".join(f["message"] for f in row["findings"])
        self.assertIn("修订已滚动", messages)
        self.assertIn("未收录成员", messages)

        def fetch_missing(url):
            return {"sha": "a" * 40, "siblings": [{"rfilename": "other.onnx"}]}

        self.assertEqual(check(entry, fetch_json=fetch_missing)["status"], "drift")

        def fetch_fail(url):
            raise OSError("network down")

        self.assertEqual(check(entry, fetch_json=fetch_fail)["status"], "unknown")

    def test_drift_check_github_release(self):
        check = MODULE["drift_check"]
        entry = {"id": "qwen3", "variant": "medium",
                 "watch": {"kind": "github-release", "repo": "k2-fsa/sherpa-onnx"},
                 "archive": {"url": "https://github.com/x/y/releases/download/asr-models/qwen3-asr.tar.bz2"}}

        def fetch_ok(url):
            return [{"assets": [{"name": "qwen3-asr.tar.bz2"}]}]

        self.assertEqual(check(entry, fetch_json=fetch_ok)["status"], "ok")

        def fetch_gone(url):
            return [{"assets": [{"name": "other.tar.bz2"}]}]

        self.assertEqual(check(entry, fetch_json=fetch_gone)["status"], "drift")


if __name__ == "__main__":
    unittest.main()
