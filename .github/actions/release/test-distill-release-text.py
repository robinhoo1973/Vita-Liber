#!/usr/bin/env python3
"""test-distill-release-text：发布文案蒸馏纯离线面（2026-10-09）。

覆盖：LLM 全采纳 / 无建议纯确定性成稿 / 复检驳回（负清单、超长）/
逐语言混合 / 幂等 / readme-block 逐块门 / from-index 元回显。
"""
import json
from pathlib import Path
import runpy
import tempfile
import unittest

TOOL = Path(__file__).with_name("distill-release-text.py")
MODULE = runpy.run_path(str(TOOL))

SAMPLE_PAYLOAD = {"catalogVersion": 9, "rootVersion": 3,
                  "models": [{"id": "whisper", "variant": "tiny"}]}


def write_suggested(base, locale_prose, suggested_by="llm:mock@m"):
    suggested = base / "suggested"
    suggested.mkdir(exist_ok=True)
    (suggested / "release-notes.json").write_bytes(json.dumps({
        "formatVersion": 1, "suggestedBy": suggested_by, "locale": locale_prose,
        "cacheKey": "k" * 64, "cached": False,
    }, ensure_ascii=False).encode())
    return suggested


def run_distill(tmp, *, mode="release-notes", suggested=None, index_doc=None):
    out = Path(tmp) / "out"
    import sys
    argv = ["distill-release-text", "--mode", mode, "--out", str(out)]
    if suggested is not None:
        argv += ["--suggested", str(suggested)]
    if index_doc is not None:
        facts = Path(tmp) / "index.json"
        facts.write_bytes(json.dumps(index_doc, ensure_ascii=False).encode())
        argv += ["--from-index", str(facts)]
    saved = sys.argv
    sys.argv = argv
    try:
        return MODULE["main"](), out
    finally:
        sys.argv = saved


def read_json(path):
    return json.loads(path.read_bytes())


class DistillReleaseTextTests(unittest.TestCase):
    def test_llm_prose_adopted_with_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            suggested = write_suggested(base, {
                "zh-Hans": "本次更新内容。", "zh-Hant": "本次更新內容。",
                "en": "What's new."})
            rc, out = run_distill(tmp, suggested=suggested,
                                  index_doc=SAMPLE_PAYLOAD)
            self.assertEqual(rc, 0)
            final = read_json(out / "release-notes.final.json")
            self.assertEqual(final["locales"]["zh-Hans"]["proseSource"], "llm")
            self.assertEqual(final["locales"]["en"]["prose"], "What's new.")
            self.assertEqual(final["generatedFrom"]["payloadCatalogVersion"], 9)
            report = read_json(out / "distill-report.json")
            self.assertEqual(report["counts"],
                             {"llmProse": 3, "deterministicProse": 0, "rejected": 0,
                              "suspiciousNumbers": 0})

    def test_absence_is_all_deterministic_rc0(self):
        with tempfile.TemporaryDirectory() as tmp:
            rc, out = run_distill(tmp, suggested=Path(tmp) / "missing",
                                  index_doc=SAMPLE_PAYLOAD)
            self.assertEqual(rc, 0, "缺建议=确定性成稿,不是错误")
            final = read_json(out / "release-notes.final.json")
            for locale in ("zh-Hans", "zh-Hant", "en"):
                self.assertIsNone(final["locales"][locale]["prose"])
                self.assertEqual(final["locales"][locale]["proseSource"],
                                 "deterministic")

    def test_relint_rejects_banned_and_overlong(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            suggested = write_suggested(base, {
                "zh-Hans": "最好最快的版本。",
                "zh-Hant": "正常內容。",
                "en": "x" * (MODULE["MAX_LOCALE_CHARS"] + 5)})
            rc, out = run_distill(tmp, suggested=suggested)
            self.assertEqual(rc, 0)
            final = read_json(out / "release-notes.final.json")
            self.assertEqual(final["locales"]["zh-Hans"]["proseSource"],
                             "deterministic", "负清单复检驳回")
            self.assertEqual(final["locales"]["zh-Hant"]["proseSource"], "llm",
                             "逐语言混合:合法语言不受连坐")
            self.assertEqual(final["locales"]["en"]["proseSource"],
                             "deterministic", "超长复检驳回")
            report = read_json(out / "distill-report.json")
            reasons = {row["locale"]: row["reason"] for row in report["rejected"]}
            self.assertIn("负清单", reasons["zh-Hans"])
            self.assertIn("超长", reasons["en"])

    def test_suspicious_numbers_flag_but_not_reject(self):
        # 数字对拍（委员会增量,report-only）:版本型数字不在事实集 → 记 suspicious,
        # 但**不拒绝**（发布页可 PATCH;误伤代价高于收益）;事实内数字（rootVersion=3
        # 出现在 payload blob）不报。
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            suggested = write_suggested(base, {
                "zh-Hans": "版本 9.9.9 提前发布。", "zh-Hant": "版本 3 正常。",
                "en": "Root version 3 lineup."})
            rc, out = run_distill(tmp, suggested=suggested, index_doc=SAMPLE_PAYLOAD)
            self.assertEqual(rc, 0)
            final = read_json(out / "release-notes.final.json")
            self.assertEqual(final["locales"]["zh-Hans"]["proseSource"], "llm",
                             "对拍不拒绝")
            self.assertEqual(final["locales"]["zh-Hans"]["suspiciousNumbers"],
                             ["9.9.9"])
            self.assertEqual(final["locales"]["zh-Hant"]["suspiciousNumbers"], [])
            report = read_json(out / "distill-report.json")
            self.assertEqual(report["counts"]["suspiciousNumbers"], 1)
            self.assertEqual(report["suspiciousNumbers"][0]["token"], "9.9.9")

    def test_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            suggested = write_suggested(base, {"zh-Hans": "a", "zh-Hant": "b",
                                               "en": "c"})
            _, out1 = run_distill(tmp, suggested=suggested)
            first = (out1 / "release-notes.final.json").read_bytes()
            _, out2 = run_distill(tmp, suggested=suggested)
            self.assertEqual(first, (out2 / "release-notes.final.json").read_bytes())

    def test_readme_block_per_block_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            suggested = base / "suggested"
            suggested.mkdir()
            (suggested / "readme-block.suggested.json").write_bytes(json.dumps({
                "formatVersion": 1, "suggestedBy": "llm:mock@m",
                "intro": "资源仓库分节说明。",
                "blocks": [
                    {"id": "medical-llm", "match": "medical-llm",
                     "displayName": "医疗文本模型", "description": "专用模型"},
                    {"id": "broken", "match": "x", "displayName": "缺描述"},
                    {"id": "banned", "match": "y", "displayName": "y",
                     "description": "保证最好"},
                ]}, ensure_ascii=False).encode())
            rc, out = run_distill(tmp, mode="readme-block", suggested=suggested)
            self.assertEqual(rc, 0)
            final = read_json(out / "readme-block.final.json")
            self.assertEqual(final["intro"], "资源仓库分节说明。")
            self.assertEqual([b["id"] for b in final["blocks"]], ["medical-llm"])
            report = read_json(out / "distill-report.json")
            self.assertEqual(report["counts"],
                             {"adopted": 2, "deterministic": 2, "rejected": 2})

    def test_readme_block_absence(self):
        with tempfile.TemporaryDirectory() as tmp:
            rc, out = run_distill(tmp, mode="readme-block",
                                  suggested=Path(tmp) / "missing")
            self.assertEqual(rc, 0)
            final = read_json(out / "readme-block.final.json")
            self.assertIsNone(final["intro"])
            self.assertEqual(final["blocks"], [])


if __name__ == "__main__":
    unittest.main()
