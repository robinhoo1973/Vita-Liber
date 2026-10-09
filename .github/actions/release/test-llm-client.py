#!/usr/bin/env python3
"""test-llm-client：共享 LLM 内核（2026-10-09 抽取批）。纯离线（mock/临时目录）。

覆盖：cache_key 稳定性与敏感性、cached_chat 未命中调用/命中复用、make_chat 的
密钥环境变量注入、非可重试 HTTP 立即失败（401 不重试）、default_cache_dir 约定。
"""
import io
import json
import sys
import tempfile
import types
import unittest
import urllib.error
import urllib.request as real_request
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from llm_client import (  # noqa: E402
    LLMError, LLMQuotaExhausted, cache_key, cached_chat, default_cache_dir,
    llm_chat, make_chat,
)


class CacheKeyTests(unittest.TestCase):
    def test_stable_and_sensitive(self):
        self.assertEqual(cache_key("p", "m", 0.2), cache_key("p", "m", 0.2))
        self.assertNotEqual(cache_key("p", "m", 0.2), cache_key("p", "m", 0.5))
        self.assertNotEqual(cache_key("p", "m", 0.2), cache_key("p", "m2", 0.2))

    def test_cached_chat_miss_then_hit(self):
        calls = []
        chat = lambda prompt: calls.append(prompt) or "OUT:" + prompt
        with tempfile.TemporaryDirectory() as tmp:
            out, key, cached = cached_chat(chat, tmp, "hi", "m", 0.2)
            self.assertEqual((out, cached), ("OUT:hi", False))
            out2, key2, cached2 = cached_chat(chat, tmp, "hi", "m", 0.2)
            self.assertEqual((out2, key2, cached2), ("OUT:hi", key, True))
            self.assertEqual(len(calls), 1, "命中后不得再调 chat")
            meta = json.loads((Path(tmp) / key / "meta.json").read_text())
            self.assertEqual(meta["cacheKey"], key)

    def test_default_cache_dir_slug(self):
        path = default_cache_dir("asr-suggest")
        self.assertEqual(path.name, "vitaliber-asr-suggest")
        self.assertEqual(path.parent.name, ".cache")


class MakeChatTests(unittest.TestCase):
    def test_api_key_env_injection(self):
        captured = {}
        orig = llm_chat
        import llm_client
        llm_client.llm_chat = lambda endpoint, model, prompt, **kw: (
            captured.update(endpoint=endpoint, model=model, prompt=prompt, **kw) or "ok")
        try:
            import os
            os.environ["TEST_LLM_KEY_XYZ"] = "secret-key"
            chat = make_chat("https://endpoint.invalid/v1", "glm-x",
                             api_key_env="TEST_LLM_KEY_XYZ", temperature=0.3)
            self.assertEqual(chat("hello"), "ok")
        finally:
            llm_client.llm_chat = orig
        self.assertEqual(captured["api_key"], "secret-key")
        self.assertEqual(captured["temperature"], 0.3)
        self.assertEqual(captured["endpoint"], "https://endpoint.invalid/v1")

    def test_api_key_env_absent_is_none(self):
        captured = {}
        import llm_client
        orig = llm_client.llm_chat
        llm_client.llm_chat = lambda endpoint, model, prompt, **kw: (
            captured.update(kw) or "ok")
        try:
            chat = make_chat("http://127.0.0.1:8080/v1", "local",
                             api_key_env="DEFINITELY_UNSET_VAR_QQ")
            chat("hi")
        finally:
            llm_client.llm_chat = orig
        self.assertIsNone(captured["api_key"])


class NonRetryableTests(unittest.TestCase):
    def test_401_fails_immediately_without_retry(self):
        calls = []

        def fake_urlopen(request, timeout=None):
            calls.append(request)
            raise urllib.error.HTTPError(request.full_url, 401, "Unauthorized",
                                         {}, io.BytesIO(b'{"error": "bad key"}'))

        globals_ = llm_chat.__globals__
        saved = globals_["urllib"]
        globals_["urllib"] = types.SimpleNamespace(
            error=urllib.error,
            request=types.SimpleNamespace(Request=real_request.Request,
                                          urlopen=fake_urlopen))
        try:
            with self.assertRaises(LLMError):
                llm_chat("https://mock.invalid", "m", "hi", retries=3,
                         _sleep=lambda seconds: None)
        finally:
            globals_["urllib"] = saved
        self.assertEqual(len(calls), 1, "401 非可重试——立即失败,不得退避重试")

    def test_quota_exhausted_no_retry(self):
        """429 code 1302（日配额耗尽）= 非瞬时:立即 LLMQuotaExhausted,零重试;
        1305（访问量过大）= 瞬时:仍走退避重试。"""
        import urllib.error
        import urllib.request as real_request
        import types as _types

        def run(body):
            calls, slept = [], []
            def fake_urlopen(request, timeout=None):
                calls.append(request)
                raise urllib.error.HTTPError(request.full_url, 429, "Too Many",
                                             {}, io.BytesIO(body))
            globals_ = llm_chat.__globals__
            saved = globals_["urllib"]
            globals_["urllib"] = _types.SimpleNamespace(
                error=urllib.error,
                request=_types.SimpleNamespace(Request=real_request.Request,
                                               urlopen=fake_urlopen))
            try:
                with self.assertRaises(LLMError) as ctx:
                    llm_chat("https://mock.invalid", "m", "hi", retries=3,
                             _sleep=lambda seconds: slept.append(seconds))
                return ctx.exception, calls, slept
            finally:
                globals_["urllib"] = saved

        error, calls, slept = run(b'{"error":{"code":"1302","message":"\u8c03\u7528\u6b21\u6570\u5df2\u8fbe\u4e0a\u9650"}}')
        self.assertIsInstance(error, LLMQuotaExhausted)
        self.assertEqual(len(calls), 1, "配额耗尽不得重试")
        self.assertEqual(slept, [])

        error, calls, slept = run(b'{"error":{"code":"1305","message":"busy"}}')
        self.assertNotIsInstance(error, LLMQuotaExhausted)
        self.assertEqual(len(calls), 4, "1305 瞬时:retries=3 → 4 跳")


if __name__ == "__main__":
    unittest.main()
