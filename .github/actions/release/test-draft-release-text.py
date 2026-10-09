#!/usr/bin/env python3
"""test-draft-release-text：发布文本草拟器纯离线面（mock chat 注入缝）。

覆盖：release-notes 三语成稿与缓存命中 / 负清单命中拒绝 / 非 JSON 拒绝；
readme-block 结构产出与逐块拒绝（字段缺失、负清单命中）；渲染头序。
"""
import json
from pathlib import Path
import runpy
import tempfile
import unittest

TOOL = Path(__file__).with_name("draft-release-text.py")
MODULE = runpy.run_path(str(TOOL))

FACTS = {"tag": "llama-models", "repository": "robinhoo1973/Resources",
         "assets": [{"name": "medical-llm-64m-q4-k-m-v1.gguf", "size": 41234567}],
         "previousNotes": "", "extraFacts": "corpus dataVersion=DV2; steps=940"}


def three_lang_doc(**overrides):
    doc = {"zh-Hans": "本次更新内容。", "zh-Hant": "本次更新內容。",
           "en": "What is new in this release."}
    doc.update(overrides)
    return json.dumps(doc, ensure_ascii=False)


class ReleaseNotesTests(unittest.TestCase):
    def test_happy_path_and_cache_hit(self):
        banned = MODULE["load_banned_re"]()
        calls = []
        chat = lambda prompt, *_: calls.append(prompt) or three_lang_doc()
        with tempfile.TemporaryDirectory() as tmp:
            result = MODULE["draft_release_notes"](FACTS, chat, tmp, "m", 0.2, banned)
            self.assertIn("markdown", result, result)
            md = result["markdown"]
            self.assertIn(MODULE["SECTION_HEADING"], md)
            for heading in ("### 简体中文", "### 繁體中文", "### English"):
                self.assertIn(heading, md)
            again = MODULE["draft_release_notes"](FACTS, chat, tmp, "m", 0.2, banned)
            self.assertTrue(again["cached"], "同输入第二次应命中缓存")
            self.assertEqual(again["markdown"], md, "缓存命中=同字节")
            self.assertEqual(len(calls), 1)

    def test_banned_word_rejects_draft(self):
        banned = MODULE["load_banned_re"]()
        chat = lambda prompt, *_: three_lang_doc(**{"zh-Hans": "最快的新版本。"})
        with tempfile.TemporaryDirectory() as tmp:
            result = MODULE["draft_release_notes"](FACTS, chat, tmp, "m", 0.2, banned)
            self.assertIn("error", result)
            self.assertIn("负清单", result["error"])
            self.assertNotIn("markdown", result)

    def test_doc_key_and_overlong_rejected(self):
        banned = MODULE["load_banned_re"]()
        chat = lambda prompt, *_: three_lang_doc()
        with tempfile.TemporaryDirectory() as tmp:
            result = MODULE["draft_release_notes"](FACTS, chat, tmp, "m", 0.2, banned)
            self.assertEqual(set(result["doc"]), {"zh-Hans", "zh-Hant", "en"},
                             "doc=三语原文（发布页消费面）")
        long_chat = lambda prompt, *_: three_lang_doc(
            **{"zh-Hans": "长" * (MODULE["MAX_LOCALE_CHARS"] + 1)})
        with tempfile.TemporaryDirectory() as tmp:
            result = MODULE["draft_release_notes"](FACTS, long_chat, tmp, "m", 0.2, banned)
            self.assertIn("error", result)
            self.assertIn("超长", result["error"])

    def test_facts_from_index(self):
        payload = {"catalogVersion": 11, "rootVersion": 3,
                   "models": [{"id": "whisper", "variant": "tiny", "bytes": 100},
                              {"id": "whisper", "variant": "base", "bytes": 200},
                              {"id": "qwen3", "variant": None, "bytes": 300}]}
        facts = MODULE["facts_from_index"](payload, tag="asr-models",
                                           repository="robinhoo1973/Resources")
        self.assertEqual(facts["tag"], "asr-models")
        self.assertEqual([a["name"] for a in facts["assets"]],
                         ["whisper-tiny", "whisper-base", "qwen3"])
        self.assertIn("catalogVersion=11", facts["extraFacts"])
        self.assertIn("家族 2", facts["extraFacts"])
        self.assertIn("档位 3", facts["extraFacts"])

    def test_non_json_rejected(self):
        banned = MODULE["load_banned_re"]()
        chat = lambda prompt, *_: "I cannot help with that."
        with tempfile.TemporaryDirectory() as tmp:
            result = MODULE["draft_release_notes"](FACTS, chat, tmp, "m", 0.2, banned)
            self.assertIn("error", result)

    def test_missing_locale_rejected(self):
        banned = MODULE["load_banned_re"]()
        chat = lambda prompt, *_: json.dumps({"zh-Hans": "x", "en": "y"})
        with tempfile.TemporaryDirectory() as tmp:
            result = MODULE["draft_release_notes"](FACTS, chat, tmp, "m", 0.2, banned)
            self.assertIn("error", result)
            self.assertIn("非三语", result["error"])


class ReadmeBlockTests(unittest.TestCase):
    def test_blocks_partition_and_rejects(self):
        banned = MODULE["load_banned_re"]()
        payload = {"intro": "离线大语言模型资源。",
                   "blocks": [
                       {"id": "medical-llm", "match": "medical-llm",
                        "displayName": "医疗文本抽取模型", "description": "专用模型"},
                       {"id": "broken", "match": "x", "displayName": "缺描述"},
                       {"id": "bad", "match": "y", "displayName": "y",
                        "description": "保证是最好"},
                   ]}
        chat = lambda prompt, *_: json.dumps(payload, ensure_ascii=False)
        with tempfile.TemporaryDirectory() as tmp:
            result = MODULE["draft_readme_block"](FACTS, chat, tmp, "m", 0.2, banned)
            self.assertEqual(len(result["doc"]["blocks"]), 1)
            self.assertEqual(result["doc"]["blocks"][0]["id"], "medical-llm")
            self.assertEqual(len(result["rejected"]), 2, result["rejected"])

    def test_intro_banned_rejects_all(self):
        banned = MODULE["load_banned_re"]()
        chat = lambda prompt, *_: json.dumps({"intro": "保证最好", "blocks": []},
                                             ensure_ascii=False)
        with tempfile.TemporaryDirectory() as tmp:
            result = MODULE["draft_readme_block"](FACTS, chat, tmp, "m", 0.2, banned)
            self.assertIn("error", result)
            self.assertIn("负清单", result["error"])


if __name__ == "__main__":
    unittest.main()
