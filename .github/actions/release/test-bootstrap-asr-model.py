#!/usr/bin/env python3
"""test-bootstrap-asr-model：bootstrap 纯函数面钉（2026-10-08，纯离线）。

角色推断 / 身份推断（family+variant 令牌扫描）/ 成员筛选 / 许可启发 /
候选择优（exact-name → token+int8）/ 逆测对账（match/mismatch/cosmetic 三分）
/ seeds 文件形状。
"""
import json
from pathlib import Path
import runpy
import unittest

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS
while ROOT != ROOT.parent and not (ROOT / "CoreKit" / "Sources" / "Domain").is_dir():
    ROOT = ROOT.parent
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
        # 连字家族（2026-10-08 实测修复：拆词扫描会让两家族全数失配）
        self.assertEqual(infer("csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"),
                         ("sense-voice", None))
        self.assertEqual(infer("csukuangfj2/sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25"),
                         ("fire-red", None))
        # 单词家族在中段（streaming- 前缀）
        self.assertEqual(infer("csukuangfj/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23"),
                         ("zipformer", None))
        with self.assertRaises(MODULE["BootstrapError"]):
            infer("someone/random-model")

    def test_member_selected(self):
        selected = MODULE["member_selected"]
        self.assertTrue(selected("encode.int8.onnx"))
        self.assertFalse(selected("test_wavs/0.wav"))
        self.assertFalse(selected(".gitattributes"))

    def test_select_quantized_members(self):
        # 2026-10-08 全量深探实证：whisper 仓 fp32+int8 孪生全收会与在册约定失配
        select = MODULE["select_quantized_members"]
        members = ["tiny-encoder.onnx", "tiny-encoder.int8.onnx",
                   "tiny-decoder.onnx", "tiny-decoder.int8.onnx",
                   "tiny-tokens.txt", "test_wavs/0.wav", "README.md"]
        self.assertEqual(select(members),
                         ["tiny-encoder.int8.onnx", "tiny-decoder.int8.onnx",
                          "tiny-tokens.txt", "test_wavs/0.wav", "README.md"],
                         "int8 优先且保持原顺序；非 onnx 透传")
        self.assertEqual(select(["tiny-encoder.fp16.onnx", "tiny-encoder.onnx"]),
                         ["tiny-encoder.fp16.onnx"],
                         "无 int8 时 fp16 优于 fp32（且无角色名不参与判定，原样透传）")
        self.assertEqual(select(["model.onnx", "model2.onnx"]),
                         ["model.onnx", "model2.onnx"],
                         "不同基名不是孪生，不得合并")
        self.assertEqual(select(["encode.onnx", "cached_decode.onnx"]),
                         ["encode.onnx", "cached_decode.onnx"],
                         "异角色同后缀不误并")

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

    def test_compare_entry_tolerates_url_based_existing_files(self):
        # 全量深探首跑实证：既有条目含 url 基文件（无 member 键，如 whisper 外部
        # LICENSE）时不得 KeyError——其不在镜像仓对照面内。
        compare = MODULE["compare_entry"]
        draft = {"id": "whisper", "variant": "tiny", "license": "MIT", "revision": "a" * 40,
                 "watch": {"kind": "hf-repo", "repo": "r"},
                 "files": [{"role": "encoder", "member": "tiny-encoder.int8.onnx",
                            "path": "p", "bytes": 1, "sha256": "1" * 64}]}
        existing = {"id": "whisper", "variant": "tiny", "license": "MIT", "revision": "a" * 40,
                    "watch": {"repo": "r"},
                    "files": [{"role": "encoder", "member": "tiny-encoder.int8.onnx",
                               "path": "p", "bytes": 1, "sha256": "1" * 64},
                              {"role": "notice", "path": "whisper/tiny/LICENSE",
                               "url": "https://raw.example/LICENSE", "bytes": 5, "sha256": "2" * 64}]}
        report = compare(draft, existing)
        self.assertEqual(report["mismatch"], [])

    def test_inventory_report(self):
        inventory = MODULE["inventory_report"]
        config = {"models": [
            {"id": "whisper", "variant": "tiny",
             "watch": {"kind": "hf-repo", "repo": "csukuangfj/sherpa-onnx-whisper-tiny"}},
            {"id": "whisper", "variant": "base",
             "watch": {"kind": "hf-repo", "repo": "csukuangfj/sherpa-onnx-whisper-base"}},
        ]}

        def fetch(url):
            if "huggingface" in url:
                return [{"id": "csukuangfj/sherpa-onnx-whisper-tiny"},
                        {"id": "csukuangfj/sherpa-onnx-whisper-large-v3"}]
            return []

        report = inventory([{"name": "whisper"}], config, fetch_json=fetch)
        rows = report["results"][0]["rows"]
        statuses = {row["repo"]: row["status"] for row in rows}
        self.assertEqual(statuses["csukuangfj/sherpa-onnx-whisper-tiny"],
                         "in-config:whisper.tiny")
        self.assertEqual(statuses["csukuangfj/sherpa-onnx-whisper-large-v3"], "new-candidate")
        self.assertEqual(report["summary"]["in_config"], 1)
        self.assertEqual(report["summary"]["new_candidates"], 1)
        self.assertEqual(report["results"][0]["missing_pinned"],
                         ["csukuangfj/sherpa-onnx-whisper-base"],
                         "钉版仓库未在候选出现必须暴露")

    def test_live_seeds_file_shape(self):
        seeds = json.loads((ROOT / ".github" / "config" / "asr" / "seeds.json").read_bytes())
        self.assertEqual(seeds["formatVersion"], 1)
        self.assertEqual([seed["name"] for seed in seeds["seeds"]],
                         ["whisper", "zipformer", "dolphin", "sense-voice",
                          "fire-red", "moonshine", "qwen3"],
                         "业务口径（2026-10-08 业主）：seeds 仅家族名，repo/档位由工具自找")

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
            self.assertIn("/releases/tags/asr-models", url, "必须按 tag 单发布查询（全量响应会截断）")
            return {"assets": [{"name": "qwen3-asr.tar.bz2"}]}

        self.assertEqual(check(entry, fetch_json=fetch_ok)["status"], "ok")

        def fetch_gone(url):
            return {"assets": [{"name": "other.tar.bz2"}]}

        self.assertEqual(check(entry, fetch_json=fetch_gone)["status"], "drift")


if __name__ == "__main__":
    unittest.main()
