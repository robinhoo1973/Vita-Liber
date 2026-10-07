#!/usr/bin/env python3
"""ASR 发布页正文渲染回归（委员会 S3，2026-10-07）。

确定性（同输入=同字节）/ 三语顺序 简→繁→英 / 家族×档位统计取自签名载荷 /
增量行四态（无基线省略/同版本省略/无变化句/增删改）/ 禁用词与禁用形态
（不列文件名/URL/哈希）负样例。全程离线。
"""
import importlib.util
import unittest
from pathlib import Path

TOOL = Path(__file__).with_name("asr_release_page.py")
_spec = importlib.util.spec_from_file_location("asr_release_page", TOOL)
module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(module)

FAMILIES = [
    {"id": "whisper", "name": {"zh-Hans": "Whisper", "zh-Hant": "Whisper", "en": "Whisper"}},
    {"id": "moonshine", "name": {"zh-Hans": "Moonshine", "zh-Hant": "Moonshine", "en": "Moonshine"}},
]


def model(family, variant, sha, tier_names, size=1024):
    return {"id": family, "variant": variant, "sha256": sha, "bytes": size,
            "tierName": tier_names}


def models_v8():
    return [
        model("whisper", "tiny", "a" * 64, {"zh-Hans": "极小", "zh-Hant": "極小", "en": "Tiny"}),
        model("whisper", "base", "b" * 64, {"zh-Hans": "基础", "zh-Hant": "基礎", "en": "Base"}),
        model("moonshine", "tiny", "c" * 64, {"zh-Hans": "极小", "zh-Hant": "極小", "en": "Tiny"}),
    ]


def payload_doc(catalog_version=8, root_version=2, models=None):
    return {
        "schemaVersion": 1, "role": "catalog", "catalogVersion": catalog_version,
        "rootVersion": root_version, "issuedAt": "2026-10-06T04:52:53Z",
        "index": {"updatedAt": "2026-10-06T03:00:00Z",
                  "families": FAMILIES, "models": models if models is not None else models_v8()},
    }


PERMANENT = "# ASR model packages\n\n<trilingual permanent header>"

BANNED_WORDS = ["来源", "來源", "采集", "採集", "抓取", "爬取", "数据源", "資料來源",
                "NMPA", "NHSA", "NHI", "TFDA", "unassigned", "partial", "失败", "被封", "不可达"]


class ReleasePageRenderTests(unittest.TestCase):
    def render(self, payload=None, previous=None):
        return module.render_release_body(PERMANENT, payload or payload_doc(), previous)

    def test_deterministic_bytes(self):
        self.assertEqual(self.render(), self.render())

    def test_trilingual_order_and_version_triple(self):
        body = self.render()
        simplified = body.index("### 简体中文")
        traditional = body.index("### 繁體中文")
        english = body.index("### English")
        self.assertLess(simplified, traditional)
        self.assertLess(traditional, english)
        for want in ("目录版本: v8（信任根版本: v2）",
                     "目錄版本: v8（信任根版本: v2）",
                     "catalog version: v8 (trust root version: v2)",
                     "构建时间: 2026-10-06T03:00:00Z (UTC)",
                     "簽發時間: 2026-10-06T04:52:53Z (UTC)"):
            self.assertIn(want, body)

    def test_stats_table_from_payload(self):
        body = self.render()
        self.assertIn("家族与档位（2 个家族 / 3 个档位）:", body)
        self.assertIn("| Whisper | 极小 / 基础 | 2 KiB |", body)
        self.assertIn("families and tiers (2 families / 3 tiers):", body)
        self.assertIn("| Moonshine | Tiny | 1 KiB |", body)

    def test_delta_omitted_without_baseline_and_same_version(self):
        self.assertNotIn("与上一版", self.render())
        same = payload_doc(catalog_version=8, models=[model("whisper", "tiny", "x" * 64,
                                                             {"zh-Hans": "极小", "zh-Hant": "極小", "en": "Tiny"})])
        self.assertNotIn("与上一版", self.render(payload=payload_doc(), previous=same))

    def test_delta_unchanged_sentence(self):
        previous = payload_doc(catalog_version=7)
        body = self.render(previous=previous)
        for want in ("**与上一版(v7)相比**:档位集合与内容无变化。",
                     "**與上一版(v7)相比**:檔位集合與內容無變化。",
                     "**Compared with the previous release (v7)**: tier set and content unchanged."):
            self.assertIn(want, body)

    def test_delta_added_updated_removed(self):
        previous_models = [
            model("whisper", "tiny", "a" * 64, {"zh-Hans": "极小", "zh-Hant": "極小", "en": "Tiny"}),
            model("whisper", "base", "OLD" * 20 + "X", {"zh-Hans": "基础", "zh-Hant": "基礎", "en": "Base"}),
        ]
        previous = payload_doc(catalog_version=7, models=previous_models)
        body = self.render(previous=previous)
        self.assertIn("**与上一版(v7)相比**:新增 1 个档位（Moonshine·极小）；更新 1 个档位（Whisper·基础）。", body)
        self.assertIn("**Compared with the previous release (v7)**: 1 tier added (Moonshine·Tiny); 1 tier updated (Whisper·Base).", body)

    def test_delta_removed_uses_previous_family_display_name(self):
        # 移除条目只存在于上一版载荷；显示名表须并入上一版家族名（评审实证的回退修复）
        previous_families = FAMILIES + [
            {"id": "sense-voice", "name": {"zh-Hans": "灵犀", "zh-Hant": "靈犀", "en": "SenseVoice"}},
        ]
        previous_models = models_v8() + [
            model("sense-voice", "small", "d" * 64, {"zh-Hans": "小", "zh-Hant": "小", "en": "Small"})]
        previous = payload_doc(catalog_version=7, models=previous_models)
        previous["index"]["families"] = previous_families
        body = self.render(previous=previous)
        self.assertIn("移除 1 个档位（灵犀·小）", body)
        self.assertIn("1 tier removed (SenseVoice·Small)", body)
        self.assertNotIn("sense-voice", body)

    def test_forbidden_shapes_absent(self):
        body = self.render(previous=payload_doc(catalog_version=7))
        self.assertNotIn(".zip", body)
        self.assertNotIn("cnb.cool", body)
        self.assertNotIn("sha256", body.lower())
        for word in BANNED_WORDS:
            self.assertNotIn(word, body, "banned word %r leaked into release body" % word)
        # 负样例:正当词不得误伤
        self.assertEqual([w for w in BANNED_WORDS if w in "语音识别模型,家族与档位统计。"], [])

    def test_human_size(self):
        self.assertEqual(module.human_size(0), "0 B")
        self.assertEqual(module.human_size(1536), "1.5 KiB")
        self.assertEqual(module.human_size(62083183), "59.2 MiB")


if __name__ == "__main__":
    unittest.main()
