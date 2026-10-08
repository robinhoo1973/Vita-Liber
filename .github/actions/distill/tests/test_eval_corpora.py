"""eval_corpora 回归:e.g. check_dialogue 必须把行数写回 stats[corpus.name] 本体键。

2026-10-08 教训(首跑 CI 37710699326):check_dialogue 只写 ".modes" 子键,而
空切分判据查的是本体键 `stats["dialogue_sft.jsonl"]`——判据恒真,verdict 恒
fail,publish 永被阻断(「永红闸」族)。本测试钉住本体键契约。
"""
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
while REPO_ROOT != REPO_ROOT.parent and not (REPO_ROOT / "CoreKit" / "Sources" / "Domain").is_dir():
    REPO_ROOT = REPO_ROOT.parent

from eval_corpora import check_dialogue  # noqa: E402
from gate.wording import WordingGuard, export_wording_blacklist  # noqa: E402


def _write_fixture(tmp: Path) -> tuple[Path, Path]:
    rows = [
        {"conversations": [
            {"role": "user", "content": "这个药怎么吃?"},
            {"role": "assistant", "content": json.dumps({"mode": "emergency"}, ensure_ascii=False)},
        ]},
        {"conversations": [
            {"role": "user", "content": "帮我看看这个检查?"},
            {"role": "assistant", "content": json.dumps(
                {"mode": "refuse", "refusal": "insufficient"}, ensure_ascii=False)},
        ]},
    ]
    corpus = tmp / "dialogue_sft.jsonl"
    corpus.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")
    sha = hashlib.sha256(corpus.read_bytes()).hexdigest()
    manifest = tmp / "dialogue_manifest.json"
    manifest.write_text(json.dumps(
        {"files": {corpus.name: {"sha256": sha}},
         "licenses": {"TFDA": {"class": "tw-ogdl-v1", "attribution": "OGDL v1 顯名"}}},
        ensure_ascii=False), encoding="utf-8")
    return corpus, manifest


class DialogueStatsKeyTests(unittest.TestCase):
    def test_stats_contains_corpus_key(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            corpus, manifest = _write_fixture(tmp)
            guard = WordingGuard(export_wording_blacklist(
                REPO_ROOT / "CoreKit" / "Sources" / "Domain" / "AlertEngine.swift")["entries"])
            failures: list[str] = []
            stats: dict = {}
            check_dialogue(corpus, manifest, guard, failures, stats)
            self.assertEqual(failures, [])
            # 本体键=行数(空切分判据依赖它);.modes 子键保留为观测面
            self.assertEqual(stats.get(corpus.name), 2)
            self.assertEqual(stats.get(f"{corpus.name}.modes"), {"emergency": 1, "refuse": 1})

    def test_missing_licenses_block_fails_closed(self):
        # round2 E 裁决:manifest 无 licenses 块 = 判红(此前三面 manifest 各缺该字段)
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            corpus, manifest = _write_fixture(tmp)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            del data["licenses"]
            manifest.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
            guard = WordingGuard(export_wording_blacklist(
                REPO_ROOT / "CoreKit" / "Sources" / "Domain" / "AlertEngine.swift")["entries"])
            failures: list[str] = []
            check_dialogue(corpus, manifest, guard, failures, {})
            self.assertTrue(any("licenses" in f for f in failures), failures)

    def test_unregistered_license_source_fails(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            corpus, manifest = _write_fixture(tmp)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["licenses"]["RandomSource"] = {"class": "x", "attribution": "y"}
            manifest.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
            guard = WordingGuard(export_wording_blacklist(
                REPO_ROOT / "CoreKit" / "Sources" / "Domain" / "AlertEngine.swift")["entries"])
            failures: list[str] = []
            check_dialogue(corpus, manifest, guard, failures, {})
            self.assertTrue(any("RandomSource" in f for f in failures), failures)


if __name__ == "__main__":
    unittest.main()
