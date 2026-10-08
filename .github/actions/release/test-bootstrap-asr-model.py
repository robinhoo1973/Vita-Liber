#!/usr/bin/env python3
"""test-bootstrap-asr-model：bootstrap 纯函数面钉（2026-10-08，纯离线）。

角色推断 / 身份推断（family+variant 令牌扫描）/ 成员筛选 / 许可启发 /
候选择优（exact-name → token+int8）/ 逆测对账（match/mismatch/cosmetic 三分）
/ seeds 文件形状。
"""
import json
from pathlib import Path
import runpy
import tempfile
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
        # 训练格式载荷（2026-10-08 全量深探实测误收 turbo-encoder.weights）
        self.assertFalse(selected("turbo-encoder.weights"))
        self.assertFalse(selected("model.pth"))

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

    def test_prefer_license_notice_prefers_model_license(self):
        # 双许可并存择一（verify 首跑实证,2026-10-08）：MODEL_LICENSE（模型
        # 专属）优先于 LICENSE（仓级）——sense-voice 上游同存两件,金样取
        # MODEL_LICENSE；单件家族（whisper 等）择一后集不变。
        prefer = MODULE["prefer_license_notice"]
        both = [{"role": "notice", "member": "README.md"},
                {"role": "notice", "member": "LICENSE"},
                {"role": "notice", "member": "MODEL_LICENSE"},
                {"role": "model", "member": "model.int8.onnx"}]
        self.assertEqual([f["member"] for f in prefer(both)],
                         ["MODEL_LICENSE", "model.int8.onnx"],
                         "MODEL_LICENSE 优先且弃 README")
        single = [{"role": "notice", "member": "LICENSE"},
                  {"role": "model", "member": "model.onnx"}]
        self.assertEqual([f["member"] for f in prefer(single)], ["LICENSE", "model.onnx"],
                         "单件许可不受择一影响")

    def test_apply_template(self):
        # 对账继承（防硬编码）：约定字段随模板走，字节事实不继承
        apply = MODULE["apply_template"]
        template = {"id": "whisper", "variant": "tiny", "license": "MIT",
                    "source": "https://github.com/openai/whisper",
                    "versionPolicy": {"prefix": "int8", "dateSource": "commit"},
                    "files": [{"role": "encoder", "path": "whisper/tiny-encoder.int8.onnx",
                               "member": "tiny-encoder.int8.onnx", "bytes": 1,
                               "sha256": "1" * 64}]}
        draft = {"id": "whisper", "variant": "tiny", "license": "REVIEW", "source": "REVIEW",
                 "versionPolicy": {"prefix": "", "dateSource": "commit"},
                 "files": [{"role": "encoder", "path": "whisper-tiny/tiny-encoder.int8.onnx",
                            "member": "tiny-encoder.int8.onnx", "bytes": 1,
                            "sha256": "2" * 64}]}
        merged = apply(draft, template)
        self.assertEqual(merged["source"], template["source"])
        self.assertEqual(merged["versionPolicy"]["prefix"], "int8")
        self.assertEqual(merged["license"], "MIT")
        self.assertEqual(merged["files"][0]["path"], "whisper/tiny-encoder.int8.onnx",
                         "path 目录前缀继承既有约定")
        self.assertEqual(merged["files"][0]["sha256"], "2" * 64,
                         "字节事实不继承——对账须暴露真实差异")
        self.assertIs(apply(draft, None), draft, "无模板原样返回")
        # 2026-10-08 全量深探：14M/bilingual 命名 variant 不可判定 → 对账时继承
        unnamed = {"id": "zipformer", "variant": None, "files": []}
        self.assertEqual(apply(unnamed, {"variant": "large", "files": []})["variant"],
                         "large", "variant=None 且模板存在时继承（仅对账口径）")

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

    def test_compare_entry_single_member_substitution_is_cosmetic(self):
        # 选件口径（2026-10-08 无硬编码化）：同角色两侧各 1 件而选件不同 ⇒
        # cosmetic（zipformer decoder 非量化偏好 / 金样 notice 为 url 基件等
        # 全部已知差异走此口径,无需家族白名单）。
        compare = MODULE["compare_entry"]
        base = {"id": "zipformer", "variant": "large", "license": "Apache-2.0",
                "revision": "a" * 40, "watch": {"repo": "r"}}
        draft = dict(base, files=[
            {"role": "decoder", "member": "decoder.int8.onnx", "path": "p", "bytes": 2, "sha256": "2" * 64},
        ])
        existing = dict(base, files=[
            {"role": "decoder", "member": "decoder.onnx", "path": "p", "bytes": 1, "sha256": "1" * 64},
        ])
        report = compare(draft, existing)
        self.assertEqual(report["mismatch"], [], "单件替换不判红")
        self.assertEqual(len(report["cosmetic"]), 2, "两侧各记一条选件差异")
        # 对侧为 url 基件（无 member）时同样成立（fire-red/sense-voice 形态）
        existing_url = dict(base, files=[
            {"role": "notice", "path": "p/LICENSE", "url": "https://x/LICENSE",
             "bytes": 1, "sha256": "1" * 64},
        ])
        draft_readme = dict(base, files=[
            {"role": "notice", "member": "README.md", "path": "p/README.md", "bytes": 2, "sha256": "2" * 64},
        ])
        report = compare(draft_readme, existing_url)
        self.assertEqual(report["mismatch"], [], "对侧 url 基单件同角色 ⇒ cosmetic")
        self.assertTrue(report["cosmetic"])

    def test_compare_entry_redundant_same_role_is_mismatch(self):
        # 防御保留：生成器同角色产出多件（fp32 混入类）⇒ mismatch（不得被
        # 选件口径放行——07ed7b3 防混入的验收面）。
        compare = MODULE["compare_entry"]
        base = {"id": "whisper", "variant": "tiny", "license": "MIT",
                "revision": "a" * 40, "watch": {"repo": "r"}}
        draft = dict(base, files=[
            {"role": "encoder", "member": "tiny-encoder.int8.onnx", "path": "p", "bytes": 1, "sha256": "1" * 64},
            {"role": "encoder", "member": "tiny-encoder.onnx", "path": "p", "bytes": 1, "sha256": "1" * 64},
        ])
        existing = dict(base, files=[
            {"role": "encoder", "member": "tiny-encoder.int8.onnx", "path": "p", "bytes": 1, "sha256": "1" * 64},
        ])
        report = compare(draft, existing)
        self.assertTrue(any("tiny-encoder.onnx" in line for line in report["mismatch"]),
                        "冗余多件必须判红")
        # 角色缺失（draft 无该角色文件）⇒ mismatch,不放行
        draft_missing = dict(base, files=[])
        report = compare(draft_missing, existing)
        self.assertTrue(any("only in existing" in line for line in report["mismatch"]))

    def test_emit_config_candidates(self):
        # 生成链第一步（2026-10-08 业主指令）：只追加新家族提案;既有条目零触碰
        # （人工字段原样）;catalog-copy 骨架三语空串（投影器 fail-closed 拒
        # 空串——骨架不可能静默出厂）。
        emit = MODULE["emit_config_candidates"]
        proposals = [{"entry": "newfam.small", "repo": "r",
                      "draft": {"id": "newfam", "variant": "small", "license": "REVIEW",
                                "source": "REVIEW", "revision": "a" * 40,
                                "watch": {"kind": "hf-repo", "repo": "r"},
                                "versionPolicy": {"prefix": "", "dateSource": "commit"},
                                "files": []}}]
        config = {"formatVersion": 1, "models": [
            {"id": "whisper", "variant": "tiny", "license": "MIT", "revision": "b" * 40,
             "source": "s", "watch": {"kind": "hf-repo", "repo": "w"},
             "versionPolicy": {"prefix": "int8"}, "files": []}]}
        copy_doc = {"formatVersion": 1,
                    "families": [{"id": "whisper", "name": {"en": "W", "zh-Hans": "W", "zh-Hant": "W"}}],
                    "tiers": [{"id": "whisper", "variant": "tiny"}]}
        with tempfile.TemporaryDirectory() as directory:
            written = emit(proposals, config, copy_doc, Path(directory))
            self.assertEqual(len(written), 3, "两文件+README")
            models = json.loads((Path(directory) / "models.json").read_text())
            copy_out = json.loads((Path(directory) / "catalog-copy.json").read_text())
        self.assertEqual([m["id"] for m in models["models"]], ["whisper", "newfam"],
                         "仅追加新家族,既有条目原样")
        self.assertEqual(models["models"][0]["license"], "MIT", "既有条目零触碰")
        family = next(f for f in copy_out["families"] if f["id"] == "newfam")
        self.assertEqual(family["name"], {"en": "", "zh-Hans": "", "zh-Hant": ""},
                         "文案骨架=空串（投影器 fail-closed 拒）")
        self.assertTrue(any(t["id"] == "newfam" and t["variant"] == "small"
                            for t in copy_out["tiers"]))

    def test_discover_authors(self):
        # 自动发现（防硬编码名单）：批量发布者入域，偶发单仓社区账号出局
        discover = MODULE["discover_authors"]

        def fetch(url):
            self.assertIn("search=sherpa-onnx", url)
            return ([{"id": "csukuangfj/sherpa-onnx-x%d" % i} for i in range(5)]
                    + [{"id": "k2-fsa/sherpa-onnx-y%d" % i} for i in range(2)]
                    + [{"id": "one-off/sherpa-onnx-z"}])

        self.assertEqual(discover(fetch_json=fetch), ("csukuangfj", "k2-fsa"))

    def test_resolve_authors(self):
        # 三级解析：显式 → config 提取 → 自动发现
        resolve = MODULE["resolve_authors"]
        config = {"models": [
            {"watch": {"kind": "hf-repo", "repo": "alpha/x"}},
            {"watch": {"kind": "github-release", "repo": "beta/y"}},
        ]}
        self.assertEqual(resolve(config, explicit="zzz"), ("zzz",), "显式最高优先")
        self.assertEqual(resolve(config), ("alpha",), "config 提取；非 hf-repo 不入域")

        def fetch(url):
            return [{"id": "gamma/a"}, {"id": "gamma/b"}]

        self.assertEqual(resolve({"models": []}, fetch_json=fetch), ("gamma",),
                         "无 config 时自动发现兜底")

    def test_inventory_report(self):
        inventory = MODULE["inventory_report"]
        config = {"models": [
            {"id": "whisper", "variant": "tiny",
             "watch": {"kind": "hf-repo", "repo": "csukuangfj/sherpa-onnx-whisper-tiny"}},
            {"id": "whisper", "variant": "base",
             "watch": {"kind": "hf-repo", "repo": "csukuangfj/sherpa-onnx-whisper-base"}},
        ]}

        def fetch(url):
            self.assertIn("author=csukuangfj", url,
                          "作者域应自 config 的 hf-repo watch 提取（零硬编码）")
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

    def test_inventory_report_github_release_kind(self):
        # github-release 型家族（2026-10-08 通用化,零家族名硬编码）：repo/tag/
        # 资产模式全来自 config 的 watch/archive；资产名与 watch.asset 通配匹配,
        # 通配外资产不入行;该型不做「钉版仓库缺失」检查（repo 语义是发布仓）。
        inventory = MODULE["inventory_report"]
        config = {"models": [
            {"id": "familyx", "variant": "medium",
             "watch": {"kind": "github-release", "repo": "some/repo",
                       "asset": "sherpa-onnx-familyx-*.tar.bz2"},
             "archive": {"url": "https://github.com/x/y/releases/download/asr-models/sherpa-onnx-familyx-2026.tar.bz2"}},
        ]}

        def fetch(url):
            if "huggingface" in url:
                return []
            self.assertIn("api.github.com/repos/some/repo/releases/tags/asr-models", url)
            return {"assets": [{"name": "sherpa-onnx-familyx-2026.tar.bz2"},
                               {"name": "sherpa-onnx-familyx-int8-2026.tar.bz2"},
                               {"name": "unrelated.tar.bz2"}]}

        report = inventory([{"name": "familyx"}], config, fetch_json=fetch)
        rows = report["results"][0]["rows"]
        statuses = {row["repo"]: row["status"] for row in rows}
        self.assertEqual(statuses["sherpa-onnx-familyx-2026.tar.bz2"], "in-config:familyx.medium")
        self.assertEqual(statuses["sherpa-onnx-familyx-int8-2026.tar.bz2"], "new-candidate")
        self.assertNotIn("unrelated.tar.bz2", statuses, "watch.asset 通配外资产不入行")
        self.assertEqual(report["results"][0]["missing_pinned"], [],
                         "github-release 型不做钉版仓库缺失检查")

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
