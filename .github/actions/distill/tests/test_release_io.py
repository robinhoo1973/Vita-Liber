"""release_io 负测(2026-10-09 CPU 训练链)。stdlib;网络面全部 monkeypatch。

覆盖:pick 取最新/无匹配即抛/正则锚定、upload 幂等 skip、latest_run_asset 空集返回 False、
CLI pick 写入格式。真网络往返由 CI 训练任务首跑实证(不进单测)。
"""
import json
import os
import sys
import unittest
from pathlib import Path

DISTILL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DISTILL))

from gen import release_io  # noqa: E402

ASSETS = [
    {"name": "distill-corpus-sha256-aaa.jsonl", "created_at": "2026-10-08T11:26:00Z", "size": 1},
    {"name": "distill-corpus-sha256-bbb.jsonl", "created_at": "2026-10-08T13:39:00Z", "size": 2},
    {"name": "baseline-x.json", "created_at": "2026-10-08T14:00:00Z", "size": 3},
]


class ReleaseIoTests(unittest.TestCase):
    def setUp(self):
        os.environ.setdefault("GH_REPO", "o/r")

    def test_pick_latest_by_created(self):
        orig = release_io.list_assets
        release_io.list_assets = lambda rel: ASSETS
        try:
            a = release_io.pick("distill-corpus", r"corpus-sha256-.*\.jsonl$")
            self.assertEqual(a["name"], "distill-corpus-sha256-bbb.jsonl")
        finally:
            release_io.list_assets = orig

    def test_pick_regex_anchored(self):
        orig = release_io.list_assets
        release_io.list_assets = lambda rel: ASSETS
        try:
            with self.assertRaises(SystemExit):
                release_io.pick("distill-corpus", r"^corpus-sha256")   # 名前缀锚不上
        finally:
            release_io.list_assets = orig

    def test_pick_no_match_raises(self):
        orig = release_io.list_assets
        release_io.list_assets = lambda rel: []
        try:
            with self.assertRaises(SystemExit):
                release_io.pick("distill-corpus", "nope")
        finally:
            release_io.list_assets = orig

    def test_upload_idempotent_skip(self):
        calls = []
        orig_la, orig_draft, orig_run = release_io.list_assets, release_io.ensure_draft, release_io._run
        release_io.list_assets = lambda rel: [{"name": "ckpt.pt", "created_at": "x", "size": 1}]
        release_io.ensure_draft = lambda rel, title: 42
        release_io._run = lambda cmd, **kw: calls.append(cmd) or _ok()
        try:
            name = release_io.upload_asset("llama-models", Path("/tmp/ckpt.pt"))
            self.assertEqual(name, "ckpt.pt")
            self.assertEqual(calls, [])   # 幂等:未触任何命令
        finally:
            release_io.list_assets, release_io.ensure_draft, release_io._run = orig_la, orig_draft, orig_run

    def test_list_assets_uses_releases_list_draft_visible(self):
        # 2026-10-09 实证:by-tag REST 对 draft 404;列表路径可见。锁死读取通道。
        calls = []
        rel = {"tag_name": "llama-models",
               "assets": [{"name": "train-state-x.json", "created_at": "t", "size": 1}]}
        orig = release_io._run
        release_io._run = lambda cmd, **kw: calls.append(cmd) or _ok(
            stdout=json.dumps([{"tag_name": "distill-corpus", "assets": []}, rel]))
        try:
            assets = release_io.list_assets("llama-models")
        finally:
            release_io._run = orig
        self.assertEqual(assets, rel["assets"])
        self.assertIn("releases?per_page=100", calls[0][2])
        self.assertNotIn("releases/tags/", calls[0][2], "禁止回退 by-tag 路径(draft 404)")

    def test_fetch_asset_missing_optional_skip(self):
        orig = release_io.list_assets
        release_io.list_assets = lambda rel: []
        try:
            ok = release_io.fetch_asset("llama-models", "nope", Path("/tmp"), optional=True)
            self.assertFalse(ok)
            with self.assertRaises(SystemExit):
                release_io.fetch_asset("llama-models", "nope", Path("/tmp"))
        finally:
            release_io.list_assets = orig

    def test_latest_run_asset_empty(self):
        orig = release_io._run
        release_io._run = lambda cmd, **kw: _ok(stdout="[]")
        try:
            self.assertFalse(release_io.latest_run_asset("llm.yml", "corpus-entities",
                                                         Path("/tmp")))
        finally:
            release_io._run = orig

    def test_fetch_exit_code_optional_distinguishable(self):
        # 2026-10-09(CI 37858840825):optional 跳过必须 ≠0,否则 `if fetch --optional`
        # 与 `if ! fetch --optional` 条件两头皆误(mv 缺失文件 / 兜底死分支)
        self.assertEqual(release_io.fetch_exit_code(True, False), 0)
        self.assertEqual(release_io.fetch_exit_code(True, True), 0)
        self.assertEqual(release_io.fetch_exit_code(False, True), 3)
        self.assertEqual(release_io.fetch_exit_code(False, False), 1)


class _ok:
    def __init__(self, stdout="", stderr="", returncode=0):
        self.stdout, self.stderr, self.returncode = stdout, stderr, returncode


if __name__ == "__main__":
    unittest.main()
