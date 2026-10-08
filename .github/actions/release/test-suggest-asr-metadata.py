#!/usr/bin/env python3
"""test-suggest-asr-metadata：LLM 草拟器纯离线面（禁令不覆盖纯草拟器,2026-10-08）。

覆盖:mock LLM（chat 注入缝）→ 建议结构 / 主文件零改动 / 负清单预检 rejected /
内容寻址缓存命中;json 块容错解析;429 退避重试;逐字段容错（部分成功照常落盘）。
"""
import io
import json
from pathlib import Path
import runpy
import tempfile
import types
import unittest
import urllib.error
import urllib.request as real_request

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
            entries, families, tiers, rejected, errors = MODULE["collect_suggestions"](
                base, chat, cache, "mock", 0.2, banned)
            self.assertEqual(errors, [])
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

    def test_retry_on_429_then_success(self):
        """429（限流）→ 指数退避重试 ≤retries;第二跳成功返回内容。"""
        real = urllib  # llm_chat 现居 llm_client.py;__globals__ 补丁机制不变(2026-10-09 抽取)
        calls, slept = [], []

        class FakeResponse:
            def __init__(self, body):
                self.body = body

            def read(self, _limit=None):
                return self.body

            def geturl(self):
                return "https://mock.invalid/chat/completions"

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def fake_urlopen(request, timeout=None):
            calls.append(request)
            if len(calls) == 1:
                raise urllib.error.HTTPError(request.full_url, 429, "Too Many",
                                             {}, io.BytesIO(b'{"error": {"code": "1305"}}'))
            return FakeResponse(b'{"choices": [{"message": {"content": "{\\"ok\\": 1}"}}]}')

        # runpy.run_path 返回 globals 拷贝 → 须直打函数 __globals__（同 dict）
        globals_ = MODULE["llm_chat"].__globals__
        saved = globals_["urllib"]
        globals_["urllib"] = types.SimpleNamespace(
            error=real.error,
            request=types.SimpleNamespace(Request=real_request.Request,
                                          urlopen=fake_urlopen))
        try:
            content = MODULE["llm_chat"]("https://mock.invalid", "mock-model", "hi",
                                         retries=3, backoff=5.0,
                                         _sleep=lambda seconds: slept.append(seconds))
        finally:
            globals_["urllib"] = saved
        self.assertEqual(content, '{"ok": 1}')
        self.assertEqual(len(calls), 2, "首跳 429 后应重试一次即成功")
        self.assertEqual(slept, [5.0], "退避=backoff × 2^0")

    def test_retry_exhausted_raises(self):
        real = urllib  # llm_chat 现居 llm_client.py;__globals__ 补丁机制不变(2026-10-09 抽取)
        calls, slept = [], []

        def fake_urlopen(request, timeout=None):
            calls.append(request)
            raise urllib.error.HTTPError(request.full_url, 429, "Too Many",
                                         {}, io.BytesIO(b"{}"))

        globals_ = MODULE["llm_chat"].__globals__
        saved = globals_["urllib"]
        globals_["urllib"] = types.SimpleNamespace(
            error=real.error,
            request=types.SimpleNamespace(Request=real_request.Request,
                                          urlopen=fake_urlopen))
        try:
            with self.assertRaises(MODULE["SuggestError"]):
                MODULE["llm_chat"]("https://mock.invalid", "mock-model", "hi",
                                   retries=2, backoff=1.0,
                                   _sleep=lambda seconds: slept.append(seconds))
        finally:
            globals_["urllib"] = saved
        self.assertEqual(len(calls), 3, "retries=2 → 最多 3 跳")
        self.assertEqual(slept, [1.0, 2.0], "退避序列 backoff×2^attempt")

    def test_deadline_skips_remaining(self):
        """总时限耗尽→零调用,全部字段记 deadline（重试预算不得超 job timeout）。"""
        banned = MODULE["load_banned_re"]()
        calls = []
        def chat(prompt, *_):
            calls.append(prompt)
            return "{\"license\": \"MIT\", \"confidence\": 0.9}"
        globals_ = MODULE["collect_suggestions"].__globals__
        saved = globals_["time"]
        state = {"t": 0.0}
        def fake_monotonic():
            value = state["t"]
            state["t"] += 1000.0  # 首次（deadline 计算）后即远超 5s 预算
            return value
        globals_["time"] = types.SimpleNamespace(monotonic=fake_monotonic)
        try:
            with tempfile.TemporaryDirectory() as directory:
                base = Path(directory)
                write_fixtures(base)
                entries, families, tiers, rejected, errors = MODULE["collect_suggestions"](
                    base, chat, base / "cache", "mock", 0.2, banned, max_seconds=5)
        finally:
            globals_["time"] = saved
        self.assertEqual(calls, [], "时限耗尽→零调用")
        self.assertEqual(len(errors), 4, "license+prefix+家族文案+档位文案 全记 deadline")
        self.assertTrue(all(e["error"] == "deadline exceeded" for e in errors))
        self.assertEqual((entries, families, tiers), ([], [], []))

    def test_partial_failure_tolerated(self):
        """单字段失败（429 类）记 errors 继续;部分成功照常返回。"""
        banned = MODULE["load_banned_re"]()
        def chat(prompt, *_):
            if "SPDX license" in prompt:
                return "{\"license\": \"MIT\", \"confidence\": 0.9, \"reason\": \"x\"}"
            raise MODULE["SuggestError"]("HTTP 429（mock）: 访问量过大")
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            write_fixtures(base)
            entries, families, tiers, rejected, errors = MODULE["collect_suggestions"](
                base, chat, base / "cache", "mock", 0.2, banned)
        self.assertEqual(len(entries), 1)
        self.assertIn("license", entries[0]["suggestions"])
        self.assertNotIn("versionPolicy.prefix", entries[0]["suggestions"])
        # prefix + 家族文案 + 档位文案 三处失败均入 errors（license 成功不受累）
        self.assertEqual(len(errors), 3)
        self.assertEqual((errors[0]["where"], errors[0]["field"]),
                         ("newfam/small", "versionPolicy.prefix"))
        self.assertIn("429", errors[0]["error"])
        self.assertEqual((families, tiers), ([], []))
        self.assertTrue(rejected is not None)


if __name__ == "__main__":
    unittest.main()
