"""corpus.manifest:生成/校验/篡改检测/TFDA 顯名义务强制。"""
import json
import tempfile
import unittest
from pathlib import Path

from corpus.manifest import build_manifest, verify_manifest, write_manifest


def _make(tmp: Path) -> tuple[Path, dict]:
    corpus = tmp / "corpus.jsonl"
    corpus.write_text('{"id":"x"}\n', encoding="utf-8")
    manifest = build_manifest(
        corpus_path=corpus, catalog_data_version="v1", catalog_source="test",
        noise_model={"noise_version": "1.0", "tables": {}},
        pinyin_available=False, pinyin_reason="test env",
        split_rule={"version": "1.0", "master_seed": 1},
        licenses={"TFDA": {"attribution": "OGDL v1 顯名"}}, counts={"drug:light:eval": 5},
    )
    write_manifest(tmp / "manifest.json", manifest)
    return corpus, manifest


class ManifestTests(unittest.TestCase):
    def test_roundtrip_verify(self):
        tmp = Path(tempfile.mkdtemp())
        corpus, manifest = _make(tmp)
        loaded = verify_manifest(tmp / "manifest.json", corpus)
        self.assertEqual(loaded["corpus_sha256"], manifest["corpus_sha256"])

    def test_tampered_corpus_detected(self):
        tmp = Path(tempfile.mkdtemp())
        corpus, _ = _make(tmp)
        corpus.write_text('{"id":"y"}\n', encoding="utf-8")
        with self.assertRaises(ValueError):
            verify_manifest(tmp / "manifest.json", corpus)

    def test_tampered_manifest_detected(self):
        tmp = Path(tempfile.mkdtemp())
        corpus, _ = _make(tmp)
        path = tmp / "manifest.json"
        data = json.loads(path.read_text(encoding="utf-8"))
        data["counts"]["drug:light:eval"] = 999
        path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        with self.assertRaises(ValueError):
            verify_manifest(path, corpus)

    def test_tfda_attribution_mandatory(self):
        tmp = Path(tempfile.mkdtemp())
        corpus = tmp / "corpus.jsonl"
        corpus.write_text('{"id":"x"}\n', encoding="utf-8")
        manifest = build_manifest(
            corpus_path=corpus, catalog_data_version="v1", catalog_source="test",
            noise_model={}, pinyin_available=False, pinyin_reason=None,
            split_rule={}, licenses={"TFDA": {"covers": ["TW"]}}, counts={},
        )
        write_manifest(tmp / "manifest.json", manifest)
        with self.assertRaises(ValueError):
            verify_manifest(tmp / "manifest.json", corpus)

    def test_tfda_attribution_elsewhere_not_accepted(self):
        # 回归:TFDA 顯名检查须按 licenses["TFDA"].attribution 字段判定,不得在
        # 整份 licenses 的 JSON 串里搜 "attribution" 子串(他源 note 含该字样
        # 曾假绿放行,OGDL v1 义务被静默绕过)
        tmp = Path(tempfile.mkdtemp())
        corpus = tmp / "corpus.jsonl"
        corpus.write_text('{"id":"x"}\n', encoding="utf-8")
        manifest = build_manifest(
            corpus_path=corpus, catalog_data_version="v1", catalog_source="test",
            noise_model={}, pinyin_available=False, pinyin_reason=None,
            split_rule={}, counts={},
            licenses={"TFDA": {"covers": ["TW"]},
                      "NHSA": {"note": "attribution 字样只在他源 note"}},
        )
        write_manifest(tmp / "manifest.json", manifest)
        with self.assertRaises(ValueError):
            verify_manifest(tmp / "manifest.json", corpus)


if __name__ == "__main__":
    unittest.main()
