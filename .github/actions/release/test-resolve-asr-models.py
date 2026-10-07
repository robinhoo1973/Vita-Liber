#!/usr/bin/env python3
"""test-resolve-asr-models：上游解析三面钉（2026-10-07 全自动批，纯离线）。

面 1 计划正确性：up-to-date / update / unknown（fetch 失败保留 pin）；
面 2 应用语义：内容有变才滚动 pin；内容等值（元数据类提交）回滚 pin 防全量重建；
面 3 CLI 入口形状：空 config 零网络 rc=0；缺失文件 rc=1 且错误结构化。
"""
import hashlib
import json
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parent
MODULE = runpy.run_path(str(TOOLS / "resolve-asr-models.py"))
ResolveError = MODULE["ResolveError"]


def _config():
    return {
        "formatVersion": 1, "bundledModels": [],
        "shared": [],
        "models": [
            {"id": "whisper", "variant": "tiny", "license": "MIT",
             "revision": "a" * 40, "source": "https://github.com/openai/whisper",
             "watch": {"kind": "hf-repo", "repo": "csukuangfj/sherpa-onnx-whisper-tiny"},
             "versionPolicy": {"prefix": "int8", "dateSource": "commit"},
             "files": [{"role": "encoder", "path": "whisper/tiny-encoder.int8.onnx",
                        "member": "tiny-encoder.int8.onnx", "bytes": 10, "sha256": "1" * 64},
                       {"role": "notice", "path": "whisper/tiny/LICENSE",
                        "url": "https://raw.githubusercontent.com/openai/whisper/" + "b" * 40 + "/LICENSE",
                        "bytes": 5, "sha256": "2" * 64}]},
            {"id": "qwen3", "variant": "medium", "license": "Apache-2.0",
             "revision": "0.6B-int8-2026-03-25", "source": "https://github.com/QwenLM/Qwen3-ASR",
             "watch": {"kind": "github-release", "repo": "k2-fsa/sherpa-onnx",
                       "asset": "sherpa-onnx-qwen3-asr-*.tar.bz2",
                       "versionRegex": r"^sherpa-onnx-qwen3-asr-(.+)\.tar\.bz2$"},
             "versionPolicy": {"prefix": "0.6b-int8", "dateSource": "filename"},
             "files": [],
             "archive": {"url": "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
                                "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2",
                         "bytes": 100, "sha256": "3" * 64, "root": "x", "parts": []}},
        ],
    }


def _payload(content):
    return len(content), hashlib.sha256(content).hexdigest()


class ResolveTests(unittest.TestCase):
    def test_plan_up_to_date(self):
        config = _config()

        def fetch(url):
            if "huggingface.co" in url:
                return {"sha": "a" * 40}
            return [{"assets": [{"name": "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2",
                                 "browser_download_url": "u"}]}]

        updated, report = MODULE["resolve_all"](config, fetch_json=fetch, download=None,
                                                workdir=Path("/tmp/never"))
        self.assertEqual([r["status"] for r in report], ["up-to-date", "up-to-date"])
        self.assertEqual(updated, config, "无变化不得改写任何字段")

    def test_update_rolls_pins_only_when_content_changes(self):
        config = _config()
        new_sha = "c" * 40
        downloads = {}

        def fetch(url):
            if "huggingface.co" in url:
                return {"sha": new_sha}
            return [{"assets": [{"name": "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2",
                                 "browser_download_url": "u"}]}]

        def download(url, destination):
            content = downloads.get(url, b"NEW-CONTENT")
            Path(destination).write_bytes(content)
            return _payload(content)

        updated, report = MODULE["resolve_all"](config, fetch_json=fetch, download=download,
                                                workdir=Path(tempfile.mkdtemp()))
        whisper = updated["models"][0]
        self.assertEqual(whisper["revision"], new_sha)
        self.assertEqual(whisper["files"][0]["sha256"], _payload(b"NEW-CONTENT")[1])
        # 次源锁定文件（显式 url）不得被动
        self.assertEqual(whisper["files"][1]["sha256"], "2" * 64)
        self.assertEqual(report[0]["status"], "update")

    def test_metadata_only_change_keeps_pins(self):
        config = _config()
        old_sha = hashlib.sha256(b"SAME").hexdigest()

        def fetch(url):
            return {"sha": "d" * 40}

        def download(url, destination):
            content = b"SAME"
            Path(destination).write_bytes(content)
            return _payload(content)

        config["models"] = [config["models"][0]]
        config["models"][0]["files"] = [config["models"][0]["files"][0]]
        config["models"][0]["files"][0]["bytes"] = len(b"SAME")
        config["models"][0]["files"][0]["sha256"] = old_sha
        updated, report = MODULE["resolve_all"](config, fetch_json=fetch, download=download,
                                                workdir=Path(tempfile.mkdtemp()))
        self.assertEqual(report[0]["status"], "up-to-date")
        self.assertEqual(updated["models"][0]["revision"], "a" * 40, "内容等值不得滚动 pin")

    def test_fetch_failure_keeps_pin_with_unknown(self):
        config = _config()

        def fetch(url):
            raise OSError("network down")

        updated, report = MODULE["resolve_all"](config, fetch_json=fetch, download=None,
                                                workdir=Path("/tmp/never"))
        self.assertEqual([r["status"] for r in report], ["unknown", "unknown"])
        self.assertEqual(updated, config)

    def test_cli_entrypoint_shape(self):
        with tempfile.TemporaryDirectory() as td:
            empty = Path(td) / "empty.json"
            empty.write_text(json.dumps({"formatVersion": 1, "bundledModels": [],
                                         "shared": [], "models": []}))
            ok = subprocess.run(["python3", str(TOOLS / "resolve-asr-models.py"),
                                 "--config", str(empty)], text=True, capture_output=True)
            self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
            missing = subprocess.run(["python3", str(TOOLS / "resolve-asr-models.py"),
                                      "--config", str(Path(td) / "nope.json")],
                                     text=True, capture_output=True)
            self.assertEqual(missing.returncode, 1)
            self.assertIn("ASR-RESOLVE-ERROR", missing.stderr)


if __name__ == "__main__":
    unittest.main()
