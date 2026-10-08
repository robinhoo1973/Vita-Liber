#!/usr/bin/env python3
"""test-distill-asr-metadata：蒸馏合并纯离线面（2026-10-08）。

覆盖：确定性在场→保留（建议记 shadowed）· LLM 填空缺采纳（provenance）·
字符串化 null 归一驳回 · 置信度阈值 · 负清单驳回（同源）· 三语完整性 ·
幂等（双跑同字节）· 侧车缺失优雅降级 · 孤儿建议 · CLI 往返与报告形状。
"""
import json
from pathlib import Path
import runpy
import tempfile
import unittest

TOOL = Path(__file__).with_name("distill-asr-metadata.py")
MODULE = runpy.run_path(str(TOOL))

TRILINGUAL = {"zh-Hans": "新家族 轻量", "zh-Hant": "新家族 輕量", "en": "Newfam Lite"}


def candidates_fixture():
    return {
        "formatVersion": 1, "bundledModels": [], "shared": [],
        "models": [
            {"id": "knownfam", "variant": "small", "license": "MIT",
             "revision": "a" * 40, "source": "https://example.invalid/known",
             "watch": {"kind": "hf-repo", "repo": "csukuangfj/knownfam-small"},
             "versionPolicy": {"prefix": "int8", "dateSource": "filename"},
             "files": []},
            {"id": "newfam", "variant": "small", "license": "REVIEW",
             "revision": "",
             "watch": {"kind": "hf-repo", "repo": "csukuangfj/newfam-zh-en"},
             "versionPolicy": {"prefix": "", "dateSource": "commit"},
             "files": []},
        ],
    }


def copy_fixture():
    return {
        "formatVersion": 1,
        "families": [
            {"id": "knownfam", "name": {"en": "Known", "zh-Hans": "已知", "zh-Hant": "已知"},
             "hint": {"en": "h", "zh-Hans": "h", "zh-Hant": "h"},
             "strengths": {"en": "s", "zh-Hans": "s", "zh-Hant": "s"},
             "limitations": {"en": "l", "zh-Hans": "l", "zh-Hant": "l"}},
            {"id": "newfam", "name": {"en": "", "zh-Hans": "", "zh-Hant": ""},
             "hint": {"en": "", "zh-Hans": "", "zh-Hant": ""},
             "strengths": {"en": "", "zh-Hans": "", "zh-Hant": ""},
             "limitations": {"en": "", "zh-Hans": "", "zh-Hant": ""}},
        ],
        "tiers": [
            {"id": "newfam", "variant": "small",
             "tierName": {"en": "", "zh-Hans": "", "zh-Hant": ""},
             "tierHint": {"en": "", "zh-Hans": "", "zh-Hant": ""}},
        ],
    }


def suggestion(value, confidence=None):
    row = {"value": value, "cacheKey": "k" * 64, "cached": False}
    if confidence is not None:
        row["confidence"] = confidence
    return row


def write_dirs(base, *, models_sugg=b"", copy_sugg=b"", with_sidecar=True):
    candidates, suggested = base / "candidates", base / "suggested"
    candidates.mkdir()
    (candidates / "models.json").write_bytes(
        json.dumps(candidates_fixture(), ensure_ascii=False, indent=2).encode() + b"\n")
    (candidates / "catalog-copy.json").write_bytes(
        json.dumps(copy_fixture(), ensure_ascii=False, indent=2).encode() + b"\n")
    if with_sidecar:
        suggested.mkdir()
        if models_sugg:
            (suggested / "models.suggested.json").write_bytes(models_sugg)
        if copy_sugg:
            (suggested / "catalog-copy.suggested.json").write_bytes(copy_sugg)
    return candidates, (suggested if with_sidecar else base / "absent")


def run_distill(candidates, suggested, out, min_confidence=0.6):
    argv = ["distill", "--candidates", str(candidates), "--out", str(out),
            "--min-confidence", str(min_confidence)]
    if suggested is not None:
        argv += ["--suggested", str(suggested)]
    import sys
    saved = sys.argv
    sys.argv = argv
    try:
        return MODULE["main"]()
    finally:
        sys.argv = saved


def read_json(path):
    return json.loads(path.read_bytes())


class DistillTests(unittest.TestCase):
    def test_deterministic_wins_and_llm_fills_gaps(self):
        models_sugg = json.dumps({
            "formatVersion": 1, "suggestedBy": "llm:mock",
            "entries": [
                {"id": "knownfam", "variant": "small", "suggestions": {
                    "license": suggestion("NotThis", 0.99)}},
                {"id": "newfam", "variant": "small", "suggestions": {
                    "license": suggestion("Apache-2.0", 0.9),
                    "versionPolicy.prefix": suggestion("zh-en", 0.95)}},
            ]}, ensure_ascii=False).encode()
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            candidates, suggested = write_dirs(base, models_sugg=models_sugg)
            out = base / "out"
            self.assertEqual(run_distill(candidates, suggested, out), 0)
            models = read_json(out / "models.json")
            by_id = {m["id"]: m for m in models["models"]}
            self.assertEqual(by_id["knownfam"]["license"], "MIT",
                             "确定性在场→保留（LLM 建议不得覆盖）")
            self.assertEqual(by_id["newfam"]["license"], "Apache-2.0")
            self.assertEqual(by_id["newfam"]["versionPolicy"]["prefix"], "zh-en")
            report = read_json(out / "distill-report.json")
            adopted = {(row["where"], row["field"]) for row in report["adopted"]}
            self.assertIn(("newfam/small", "license"), adopted)
            self.assertIn(("newfam/small", "versionPolicy.prefix"), adopted)
            shadowed = {(row["where"], row["field"]) for row in report["shadowed"]}
            self.assertIn(("knownfam/small", "license"), shadowed,
                          "确定性在场+建议存在→记 shadowed 仅参考")
            for row in report["adopted"]:
                self.assertEqual(row["source"], "llm")
                self.assertEqual(row["suggestedBy"], "llm:mock")

    def test_stringified_null_normalized_and_rejected(self):
        models_sugg = json.dumps({
            "formatVersion": 1, "suggestedBy": "llm:mock",
            "entries": [{"id": "newfam", "variant": "small", "suggestions": {
                "versionPolicy.prefix": suggestion("null", 0.9)}}]},
            ensure_ascii=False).encode()
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            candidates, suggested = write_dirs(base, models_sugg=models_sugg)
            out = base / "out"
            self.assertEqual(run_distill(candidates, suggested, out), 0)
            models = read_json(out / "models.json")
            newfam = [m for m in models["models"] if m["id"] == "newfam"][0]
            self.assertEqual(newfam["versionPolicy"]["prefix"], "",
                             "字符串化 null 归一为无效,字段保持空缺")
            report = read_json(out / "distill-report.json")
            rejected = [row for row in report["rejected"]
                        if row["field"] == "versionPolicy.prefix"]
            self.assertTrue(rejected and "归一" in rejected[0]["reason"])

    def test_low_confidence_rejected(self):
        models_sugg = json.dumps({
            "formatVersion": 1, "suggestedBy": "llm:mock",
            "entries": [{"id": "newfam", "variant": "small", "suggestions": {
                "license": suggestion("Apache-2.0", 0.3)}}]},
            ensure_ascii=False).encode()
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            candidates, suggested = write_dirs(base, models_sugg=models_sugg)
            out = base / "out"
            self.assertEqual(run_distill(candidates, suggested, out), 0)
            models = read_json(out / "models.json")
            newfam = [m for m in models["models"] if m["id"] == "newfam"][0]
            self.assertEqual(newfam["license"], "REVIEW")
            report = read_json(out / "distill-report.json")
            self.assertTrue(any("置信度不足" in row["reason"]
                                for row in report["rejected"]))

    def test_banned_copy_rejected_and_valid_adopted(self):
        copy_sugg = json.dumps({
            "formatVersion": 1, "suggestedBy": "llm:mock",
            "families": [{"id": "newfam", "suggestions": {
                "name": suggestion({**TRILINGUAL, "zh-Hans": "最好 新家族"}),
                "hint": suggestion(TRILINGUAL)}}],
            "tiers": [{"id": "newfam", "variant": "small", "suggestions": {
                "tierName": suggestion(TRILINGUAL),
                "tierHint": suggestion({"zh-Hans": "只有中文"})}}],
            "rejected": []}, ensure_ascii=False).encode()
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            candidates, suggested = write_dirs(base, copy_sugg=copy_sugg)
            out = base / "out"
            self.assertEqual(run_distill(candidates, suggested, out), 0)
            copy_doc = read_json(out / "catalog-copy.json")
            newfam = [f for f in copy_doc["families"] if f["id"] == "newfam"][0]
            self.assertEqual(newfam["name"]["zh-Hans"], "", "负清单命中→不采纳")
            self.assertEqual(newfam["hint"]["zh-Hans"], TRILINGUAL["zh-Hans"])
            tier = copy_doc["tiers"][0]
            self.assertEqual(tier["tierName"]["en"], TRILINGUAL["en"])
            self.assertEqual(tier["tierHint"]["zh-Hans"], "", "三语缺失→不采纳")
            report = read_json(out / "distill-report.json")
            reasons = {(row["field"], row["reason"]) for row in report["rejected"]}
            self.assertTrue(any("负清单" in reason for _, reason in reasons))
            self.assertTrue(any("缺 zh-Hant" in reason for _, reason in reasons))

    def test_idempotent_double_run_identical_bytes(self):
        models_sugg = json.dumps({
            "formatVersion": 1, "suggestedBy": "llm:mock",
            "entries": [{"id": "newfam", "variant": "small", "suggestions": {
                "license": suggestion("Apache-2.0", 0.9)}}]},
            ensure_ascii=False).encode()
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            candidates, suggested = write_dirs(base, models_sugg=models_sugg)
            first, second = base / "out1", base / "out2"
            self.assertEqual(run_distill(candidates, suggested, first), 0)
            self.assertEqual(run_distill(candidates, suggested, second), 0)
            for name in ("models.json", "catalog-copy.json"):
                self.assertEqual((first / name).read_bytes(),
                                 (second / name).read_bytes(), name)
            self.assertEqual(run_distill(candidates, suggested, first), 0)
            for name in ("models.json", "catalog-copy.json"):
                self.assertEqual((first / name).read_bytes(),
                                 (second / name).read_bytes(),
                                 "同目录覆写仍幂等: " + name)

    def test_missing_sidecar_graceful(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            candidates, suggested = write_dirs(base, with_sidecar=False)
            out = base / "out"
            self.assertEqual(run_distill(candidates, suggested, out), 0)
            models = read_json(out / "models.json")
            source = candidates_fixture()
            self.assertEqual(models, source, "无侧车→纯确定性成稿（原样）")
            report = read_json(out / "distill-report.json")
            self.assertFalse(report["generatedFrom"]["sidecarPresent"])
            self.assertEqual(report["counts"]["adopted"], 0)
            self.assertTrue(report["leftOpen"])

    def test_orphan_suggestions_recorded(self):
        models_sugg = json.dumps({
            "formatVersion": 1, "suggestedBy": "llm:mock",
            "entries": [{"id": "ghost", "variant": None, "suggestions": {
                "license": suggestion("MIT", 0.9)}}]},
            ensure_ascii=False).encode()
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            candidates, suggested = write_dirs(base, models_sugg=models_sugg)
            out = base / "out"
            self.assertEqual(run_distill(candidates, suggested, out), 0)
            report = read_json(out / "distill-report.json")
            self.assertEqual([row["id"] for row in report["orphans"]], ["ghost"])
            self.assertEqual(report["counts"]["adopted"], 0)

    def test_malformed_shapes_rejected(self):
        models_sugg = json.dumps({
            "formatVersion": 1, "suggestedBy": "llm:mock",
            "entries": [{"id": "newfam", "variant": "small", "suggestions": {
                "license": suggestion({"oops": True}, 0.9)}}]},
            ensure_ascii=False).encode()
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            candidates, suggested = write_dirs(base, models_sugg=models_sugg)
            out = base / "out"
            self.assertEqual(run_distill(candidates, suggested, out), 0)
            models = read_json(out / "models.json")
            newfam = [m for m in models["models"] if m["id"] == "newfam"][0]
            self.assertEqual(newfam["license"], "REVIEW")
            report = read_json(out / "distill-report.json")
            self.assertTrue(any("负清单" in row["reason"] or "形态" in row["reason"]
                                for row in report["rejected"]),
                            "非字符串 license 被驳回: %r" % report["rejected"])


if __name__ == "__main__":
    unittest.main()
