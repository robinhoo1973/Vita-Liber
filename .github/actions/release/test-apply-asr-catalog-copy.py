#!/usr/bin/env python3
"""test-apply-asr-catalog-copy：文案投影器三面钉（2026-10-08 文案链批，纯离线）。

面 1 投影语义：字段投影/行为字段零触碰/保序/确定性/changeNote 修订键控；
面 2 fail-closed：覆盖缺口、三语不齐、负清单词、未知键一律硬错；
面 3 CLI 入口形状（教训族：测试必须绑生产 CLI 形状）：--check 等价/篡改判红；
另含**活体一致性**：仓库真实 copy 源对真实模板索引的覆盖完备（防漂移）。
"""
import base64
import json
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS
while ROOT != ROOT.parent and not (ROOT / "CoreKit" / "Sources" / "Domain").is_dir():
    ROOT = ROOT.parent

MODULE = runpy.run_path(str(TOOLS / "apply-asr-catalog-copy.py"))
L3 = {"zh-Hans": "值", "zh-Hant": "值", "en": "value"}


def _index():
    return {
        "schemaVersion": 1, "app": "vitaliber", "assetKind": "asr",
        "baseUrl": "https://cnb.cool/robinhoo1973/Resources/-/releases/download/asr-models",
        "families": [
            {"id": "whisper", "name": dict(L3), "hint": dict(L3),
             "languages": ["zh", "en"], "dialects": []},
        ],
        "models": [
            {"id": "whisper", "variant": "tiny", "version": "v1", "sha256": "a" * 64,
             "license": "MIT", "upstreamRevision": "rev-1",
             "tierName": dict(L3), "tierHint": dict(L3)},
            {"id": "whisper", "variant": "base", "version": "v1", "sha256": "b" * 64,
             "license": "MIT", "upstreamRevision": "rev-2",
             "tierName": dict(L3), "tierHint": dict(L3)},
        ],
    }


def _copy():
    return {
        "formatVersion": 1,
        "families": [
            {"id": "whisper", "name": dict(L3), "hint": dict(L3),
             "strengths": dict(L3), "limitations": dict(L3)},
        ],
        "tiers": [
            {"id": "whisper", "variant": "tiny", "tierName": dict(L3), "tierHint": dict(L3),
             "changeNote": {"revision": "rev-1", "text": {"zh-Hans": "新", "zh-Hant": "新", "en": "new"}}},
            {"id": "whisper", "variant": "base", "tierName": dict(L3), "tierHint": dict(L3),
             "changeNote": {"revision": "rev-OLD", "text": dict(L3)}},
        ],
    }


def _project(index=None, copy=None):
    return MODULE["project"](json.dumps(index or _index(), ensure_ascii=False).encode(),
                             json.dumps(copy or _copy(), ensure_ascii=False).encode())


class ProjectionTests(unittest.TestCase):
    def test_projection_semantics(self):
        merged = json.loads(_project())
        family = merged["families"][0]
        self.assertEqual(set(family.keys()) & {"strengths", "limitations"},
                         {"strengths", "limitations"}, "新字段必须投影")
        self.assertEqual(family["languages"], ["zh", "en"], "行为字段零触碰")
        self.assertEqual([f["id"] for f in merged["families"]], ["whisper"], "家族保序")
        tiny = merged["models"][0]
        self.assertEqual(tiny["changeNote"]["en"], "new", "revision 匹配 → 发射")
        self.assertNotIn("changeNote", merged["models"][1], "revision 失配 → 不发射")
        self.assertEqual(tiny["sha256"], "a" * 64, "身份字段零触碰")
        self.assertEqual(_project(), _project(), "确定性：两次投影逐字节相等")

    def test_fail_closed(self):
        copy = _copy()
        copy["families"] = []  # 覆盖缺口
        with self.assertRaises(ValueError):
            _project(copy=copy)
        copy = _copy()
        copy["families"][0]["strengths"] = {"zh-Hans": "值", "en": "value"}  # 三语不齐
        with self.assertRaises(ValueError):
            _project(copy=copy)
        copy = _copy()
        copy["families"][0]["strengths"] = {"zh-Hans": "最高品质", "zh-Hant": "值", "en": "value"}
        with self.assertRaises(ValueError):
            _project(copy=copy)
        copy = _copy()
        copy["tiers"][0]["variant"] = "unknown"  # 未知档位
        with self.assertRaises(ValueError):
            _project(copy=copy)

    def test_cli_entrypoint_shape(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            index_path = root / "index.json"
            index_path.write_bytes(json.dumps(_index(), ensure_ascii=False).encode())
            copy_path = root / "copy.json"
            copy_path.write_bytes(json.dumps(_copy(), ensure_ascii=False).encode())
            expected = root / "expected.json"
            expected.write_bytes(_project())
            ok = subprocess.run(["python3", str(TOOLS / "apply-asr-catalog-copy.py"),
                                 "--index", str(index_path), "--copy", str(copy_path),
                                 "--check", str(expected)], text=True, capture_output=True)
            self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
            index_path.write_bytes(b'{"broken": true')
            bad = subprocess.run(["python3", str(TOOLS / "apply-asr-catalog-copy.py"),
                                  "--index", str(index_path), "--copy", str(copy_path)],
                                 text=True, capture_output=True)
            self.assertEqual(bad.returncode, 1)
            self.assertIn("ASR-COPY-ERROR", bad.stderr)

    def test_live_copy_covers_live_template(self):
        # 活体一致性：真实 copy 源必须完整覆盖真实模板索引（防漂移；模板
        # 刷新后此测试率先暴露 copy 缺口）。
        envelope = json.loads((ROOT / "Resources" / "ASRModelUpdates" / "manifest.json").read_bytes())
        index = json.loads(base64.b64decode(envelope["payload"]))["index"]
        copy = json.loads((ROOT / ".github" / "config" / "asr" / "catalog-copy.json").read_bytes())
        MODULE["validate_copy"](copy, index)  # 不完备即 raise
        merged = MODULE["overlay"](index, copy)
        for family in merged["families"]:
            self.assertIn("strengths", family)
            self.assertIn("limitations", family)


if __name__ == "__main__":
    unittest.main()
