#!/usr/bin/env python3
"""test-suggest-asr-metadata：LLM 草拟器纯离线面（禁令不覆盖纯草拟器,2026-10-08）。

覆盖:mock LLM（chat 注入缝）→ 建议结构 / 主文件零改动 / 负清单预检 rejected /
内容寻址缓存命中;json 块容错解析。
"""
import json
from pathlib import Path
import runpy
import tempfile
import unittest

TOOL = Path(__file__).with_name("suggest-asr-metadata.py")
MODULE = runpy.run_path(str(TOOL))


def write_fixtures(base):
    (base / "models.json").write_bytes(json.dumps({
        "formatVersion": 1, "bundledModels": [], "shared": [],
        "models": [
            {"id": "newfam", "variant": "small", "license": "REVIEW",
             "revision": "a" * 40, "source": "REVIEW",
             "watch": {"kind": "hf-repo", "repo": "csukuangfj/newfam-small"},
             "versionPolicy": {"prefix": "", "dateSource": "commit"},
             "files": [{"role": "encoder", "member": "encoder.int8.onnx",
                        "path": "newfam/encoder.int8.onnx", "bytes": 1,
                        "sha256": "1" * 64}]}]}, ensure_ascii=False,
        indent=2).encode() + b"\n")
    (base / "catalog-copy.json").write_bytes(json.dumps({
        "formatVersion": 1,
        "families": [{"id": "newfam", "name": {"en": "", "zh-Hans": "", "zh-Hant": ""},
                      "hint": {"en": "", "zh-Hans": "", "zh-Hant": ""},
                      "strengths": {"en": "", "zh-Hans": "", "zh-Hant": ""},
                      "limitations": {"en": "", "zh-Hans": "", "zh-Hant": ""}}],
        "tiers": [{"id": "newfam", "variant": "small",
                   "tierName": {"en": "", "zh-Hans": "", "zh-Hant": ""},
                   "tierHint": {"en": "", "zh-Hans": "", "zh-Hant": ""}}]},
        ensure_ascii=False, indent=2).encode() + b"\n")


class SuggestTests(unittest.TestCase):
    def test_suggestions_structure_and_negative_prcheck(self):
        banned = MODULE["load_banned_re"]()
        calls = []

        def chat(prompt, *_):
            calls.append(prompt)
            if "SPDX license" in prompt:
                return "Proposed: {\"license\": \"Apache-2.0\", \"confidence\": 0.6, \"reason\": \"repo naming\"}"
            if "version-policy prefix" in prompt:
                return "{\"prefix\": \"int8\", \"confidence\": 0.5, \"reason\": \"int8 member\"}"
            if "catalog copy" in prompt:
                return json.dumps({"name": {"zh-Hans": "最好 Newfam", "zh-Hant": "", "en": "Newfam"},
                                   "hint": {"zh-Hans": "h", "zh-Hant": "h", "en": "h"}})
            raise AssertionError("unexpected prompt")

        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            write_fixtures(base)
            before = {name: (base / name).read_bytes() for name in ("models.json", "catalog-copy.json")}
            out = base / "out"
            cache = base / "cache"
            entries, families, tiers, rejected = MODULE["collect_suggestions"](
                base, chat, cache, "mock", 0.2, banned)
            MODULE_dump = None
            after = {name: (base / name).read_bytes() for name in ("models.json", "catalog-copy.json")}
        self.assertEqual(before, after, "主文件零改动（旁路隔离）")
        self.assertEqual(len(entries), 1)
        suggestion = entries[0]["suggestions"]
        self.assertEqual(suggestion["license"]["value"], "Apache-2.0")
        self.assertTrue(suggestion["license"]["cacheKey"])
        self.assertEqual(suggestion["versionPolicy.prefix"]["value"], "int8")
        # 文案草稿含负清单词「最好」→ rejected;hint 三语里 zh-Hant 空 → 也拒
        self.assertTrue(any("newfam" in row["where"] for row in rejected),
                        "负清单/空值预检 rejected: %r" % rejected)
        self.assertEqual(len(families), 1)
        self.assertEqual(list(families[0]["suggestions"]), ["hint"],
                         "name 含负清单词被拒, hint 合法通过")
        self.assertEqual(tiers, [])

    def test_cache_hit_avoids_second_call(self):
        banned = MODULE["load_banned_re"]()
        calls = []
        def chat(prompt, *_):
            calls.append(prompt)
            return "{\"license\": \"MIT\", \"confidence\": 0.9, \"reason\": \"x\"}"
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            write_fixtures(base)
            cache = base / "cache"
            MODULE["collect_suggestions"](base, chat, cache, "mock", 0.2, banned)
            first = len(calls)
            entries, *_ = MODULE["collect_suggestions"](base, chat, cache, "mock", 0.2, banned)
            self.assertEqual(len(calls), first, "缓存命中不得二次调用")
            self.assertTrue(entries[0]["suggestions"]["license"]["cached"])

    def test_parse_json_block_tolerance(self):
        parse = MODULE["parse_json_block"]
        self.assertEqual(parse("noise {\"a\": 1} tail"), {"a": 1})
        self.assertIsNone(parse("no json at all"))
        self.assertEqual(parse("broken {oops} then {\"b\": 2}"), {"b": 2})


if __name__ == "__main__":
    unittest.main()
