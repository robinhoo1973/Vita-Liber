#!/usr/bin/env python3
"""test-asr-config-projection：config → 源清单投影三面钉（2026-10-07 config 批，纯离线）。

面 1 逐字节复现：生成器输出 == 仓库已提交源清单（**迁移验收基准**——不相等
即视为迁移失败）；
面 2 schema 完备：每条目带合法 watch/versionPolicy，文件 member/url 恰一；
面 3 CLI 入口形状（教训族「重构删 import 漏改使用点族」：测试必须绑生产
CLI 形状）：--check 等价 rc=0、篡改 rc=1 且错误结构化。
"""
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

CONFIG = ROOT / ".github" / "config" / "asr" / "models.json"
MANIFEST = ROOT / "Resources" / "ASRModels" / "manifest.json"
GENERATOR = TOOLS / "generate-asr-source-manifest.py"

MODULE = runpy.run_path(str(GENERATOR))


class ProjectionTests(unittest.TestCase):
    def test_projection_reproduces_committed_manifest_byte_for_byte(self):
        config = json.loads(CONFIG.read_bytes())
        data = MODULE["manifest_bytes"](MODULE["project"](config))
        self.assertEqual(data, MANIFEST.read_bytes(),
                         "config 投影必须与已提交源清单逐字节相等（迁移验收基准）")

    def test_config_completeness(self):
        config = json.loads(CONFIG.read_bytes())
        self.assertTrue(config["models"])
        for entry in config["models"]:
            where = "%s.%s" % (entry["id"], entry.get("variant"))
            self.assertIn(entry["watch"]["kind"], MODULE["WATCH_KINDS"], where)
            self.assertIn("versionPolicy", entry, where)
            for item in entry.get("files", []):
                self.assertEqual(("member" in item) + ("url" in item), 1, where)
        for shared in config["shared"]:
            self.assertIn(shared["watch"]["kind"], MODULE["WATCH_KINDS"], shared["path"])

    def test_cli_check_entrypoint(self):
        ok = subprocess.run(["python3", str(GENERATOR), "--check", str(MANIFEST)],
                            text=True, capture_output=True)
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        config = json.loads(CONFIG.read_bytes())
        entry = next(e for e in config["models"] if e.get("files"))
        entry["files"][0]["sha256"] = "0" * 64
        with tempfile.TemporaryDirectory() as td:
            tampered = Path(td) / "models.json"
            tampered.write_bytes(json.dumps(config, ensure_ascii=False, indent=2).encode())
            bad = subprocess.run(["python3", str(GENERATOR), "--config", str(tampered),
                                  "--check", str(MANIFEST)], text=True, capture_output=True)
            self.assertEqual(bad.returncode, 1, bad.stdout + bad.stderr)
            self.assertIn("ASR-GEN-ERROR", bad.stderr)


if __name__ == "__main__":
    unittest.main()
