#!/usr/bin/env python3
"""Execute the real version step: a model Release must not decide the App version."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

# 仓库根探测:锚点向上搜索,禁止按固定层级假设(同 l0-container-id-mask.py 纪律)
REPO = Path(__file__).resolve().parent
while REPO != REPO.parent and not (REPO / "CoreKit" / "Sources" / "Domain").is_dir():
    REPO = REPO.parent
WORKFLOWS = REPO / ".github" / "workflows"
CLUSTER = Path(__file__).resolve().parent  # 助手脚本与本测试同簇(.github/actions/release/)

HELPER_RE = re.compile(r"python3\s+([^\s\\]+\.py)")


class ReleaseVersionTests(unittest.TestCase):
    def run_direct(self, version: str, build_state: str, floor: int | None = None) -> subprocess.CompletedProcess:
        """直接跑 release-version.py（不经 workflow 文本解析）——BUILD_STATE 语义用例。"""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "version.txt").write_text(version)
            out = root / "out.txt"
            command = ["python3", str(Path(__file__).with_name("release-version.py")),
                       "--version-file", str(root / "version.txt"),
                       "--run-number", "27", "--build-state", build_state,
                       "--code-hash", "abcdef12", "--output", str(out)]
            if floor is not None:
                command.extend(["--floor-build", str(floor)])
            result = subprocess.run(command, capture_output=True, text=True)
            return subprocess.CompletedProcess(result.args, result.returncode,
                                                stdout=(out.read_text() if out.exists() else ""),
                                                stderr=result.stderr)

    def test_build_state_match_uses_stored_build(self):
        # release 一致 → 沿用变量里的 build（失败 run 不消耗语义的另一半）
        result = self.run_direct("0.0.1", '{"release": "0.0.1", "build": 749}')
        self.assertEqual(result.returncode, 0)
        self.assertIn("build=749\n", result.stdout)
        self.assertIn("state_reset=false\n", result.stdout)

    def test_build_state_release_mismatch_resets_to_one(self):
        # release 不一致 → build 归 1 + state_reset=true（workflow 据此重置变量）
        result = self.run_direct("0.0.2", '{"release": "0.0.1", "build": 749}')
        self.assertEqual(result.returncode, 0)
        self.assertIn("build=001\n", result.stdout)
        self.assertIn("state_reset=true\n", result.stdout)

    def test_build_state_corrupt_falls_back_to_run_number(self):
        # 空/损坏状态 → 回落 run_number（零回退风险）
        result = self.run_direct("0.0.1", "not-json")
        self.assertEqual(result.returncode, 0)
        self.assertIn("build=027\n", result.stdout)
        self.assertIn("state_reset=false\n", result.stdout)

    def test_asc_floor_overrides_stale_counter(self):
        # 2026-10-18：BUILD_STATE 停在 751 而 ASC 已登记 752 → 下界 753 胜出。
        result = self.run_direct("0.0.1", '{"release": "0.0.1", "build": 751}', floor=753)
        self.assertEqual(result.returncode, 0)
        self.assertIn("build=753\n", result.stdout)

    def test_asc_floor_never_lowers_computed_build(self):
        result = self.run_direct("0.0.1", '{"release": "0.0.1", "build": 751}', floor=700)
        self.assertEqual(result.returncode, 0)
        self.assertIn("build=751\n", result.stdout)

    def test_release_mismatch_still_resets_but_floor_wins_when_registered(self):
        # release 变更 → 归 1；但同一新 version 已有登记 build（如上一轮在别处上传）
        # 时必须服从 ASC，防重号。
        result = self.run_direct("0.0.2", '{"release": "0.0.1", "build": 751}', floor=5)
        self.assertEqual(result.returncode, 0)
        self.assertIn("build=005\n", result.stdout)
        self.assertIn("state_reset=true\n", result.stdout)

    def test_workflow_wires_asc_floor_before_version_step(self):
        document = yaml.safe_load((WORKFLOWS / "testflight.yml").read_text())
        # L1 job 也有一个 id=ver 的步骤（仅解析版本）；取带 asc-floor 的 build job。
        steps = next(job["steps"] for job in document["jobs"].values()
                     if any(s.get("id") == "asc-floor" for s in job.get("steps", [])))
        ver_index = next(i for i, s in enumerate(steps) if s.get("id") == "ver")
        asc_index = next(i for i, s in enumerate(steps) if s.get("id") == "asc-floor")
        self.assertLess(asc_index, ver_index, "ASC 下界必须先于版本号步骤")
        self.assertIn("asc-max-build.py", steps[asc_index]["run"])
        self.assertIn("--floor-build", steps[ver_index]["run"])

    def test_build_state_step_matches_script_arguments(self):
        # 2026-10-18 CI 39138730803：上传成功后 job 仍红——调用点传了脚本已删除的
        # --app-sha256，并引用不存在的 hash-check 步骤。调用契约在此固定。
        document = yaml.safe_load((WORKFLOWS / "testflight.yml").read_text())
        invocation = next(s["run"] for job in document["jobs"].values()
                         for s in job.get("steps", [])
                         if "build-state.py" in s.get("run", "") and "--reset" not in s.get("run", ""))
        accepted = set(re.findall(r'"--([a-z-]+)"', Path(__file__).with_name("build-state.py").read_text()))
        used = set(re.findall(r"--([a-z-]+)", invocation)) - {"build"}
        self.assertTrue(used <= accepted, f"workflow 传给 build-state.py 未定义参数: {sorted(used - accepted)}")
        self.assertIn("--commit-sha", invocation, "写回必须记录已发布提交（源码不变闸依据）")
        self.assertNotIn("hash-check", invocation)

    def run_build_state(self, gh_exit: int) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "version.txt").write_text("0.0.1\n")
            binaries = root / "bin"
            binaries.mkdir()
            (binaries / "gh").write_text(f"#!/bin/sh\nexit {gh_exit}\n")
            (binaries / "gh").chmod(0o755)
            env = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}",
                       GH_TOKEN="stub-token", GITHUB_REPOSITORY="fixture/app")
            return subprocess.run([sys.executable, str(Path(__file__).with_name("build-state.py")),
                                   "--build", "752", "--commit-sha", "a" * 40],
                                  cwd=root, env=env, capture_output=True, text=True)

    def test_build_state_write_failure_warns_without_failing_release(self):
        # 上传已成功；记账失败只告警（ASC 下界使下一次 run 自愈），不得把发布判红。
        result = self.run_build_state(gh_exit=1)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("::warning::BUILD_STATE 写回失败", result.stdout)

    def test_build_state_success_is_green(self):
        result = self.run_build_state(gh_exit=0)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("BUILD_STATE →", result.stdout)

    def run_step(self, version, *, ref_type="branch", ref_name="master"):
        document = yaml.safe_load((WORKFLOWS / "testflight.yml").read_text())
        # 2026-10-07 P2：version job 已内联进 build job——按步骤 id 跨 job 定位，
        # 不再绑定 job 名（jobs.version KeyError 是本测试的历史断点：
        # 步骤搬迁后测试滞后，ASR 发布链的「版本规则回归」步会连带必红）。
        step = next(s for job in document["jobs"].values()
                    for s in job.get("steps", []) if s.get("id") == "ver")
        script = step["run"].replace("${{ github.run_number }}", "27")
        match = HELPER_RE.search(script)
        if not match:
            self.fail("ver 步骤中未找到 python3 助手脚本路径——工作流与测试脱钩,先修工作流")
        helper_path = Path(match.group(1))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            if version is not None:
                (root / "version.txt").write_text(version)
            helpers = root / helper_path.parent
            helpers.mkdir(parents=True)
            for helper in CLUSTER.glob("*.py"):
                if not helper.name.startswith("test-"):
                    shutil.copy2(helper, helpers / helper.name)
            binaries = root / "bin"
            binaries.mkdir()
            # Only external executables are substituted. The workflow and its helper are real.
            (binaries / "gh").write_text("#!/bin/sh\nprintf 'asr-models\\n'\n")
            (binaries / "git").write_text("#!/bin/sh\nprintf 'deadbeef\\n'\n")
            for executable in binaries.iterdir():
                executable.chmod(0o755)
            output = root / "outputs"
            env = dict(os.environ, PATH=f"{binaries}:{os.environ['PATH']}", GITHUB_OUTPUT=str(output),
                       GITHUB_RUN_NUMBER="27", GITHUB_RUN_ATTEMPT="2", GITHUB_REF_TYPE=ref_type,
                       GITHUB_REF_NAME=ref_name, GITHUB_REPOSITORY="fixture/app")
            result = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail"],
                                    input=script, cwd=root, env=env, text=True, capture_output=True)
            return result, output.read_text() if output.exists() else ""

    def test_model_release_cannot_replace_version_file(self):
        result, output = self.run_step("3.4.5\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("version=3.4.5\n", output)
        self.assertIn("build=027\n", output)
        self.assertIn("hash=deadbeef\n", output)

    def test_tag_does_not_override_version_file(self):
        result, output = self.run_step("3.4.5\n", ref_type="tag", ref_name="v9.9.9")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("version=3.4.5\n", output)

    def test_bom_and_final_newline(self):
        result, output = self.run_step("\ufeff0.0.1\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("version=0.0.1\n", output)

    def test_missing_or_invalid_file_fails_before_outputs(self):
        for value in (None, "", "1.2.3\n4.5.6", "v1.2.3", "1.2.3-rc1", "1.2", "01.2.3", "1.2.3; true"):
            with self.subTest(value=value):
                result, output = self.run_step(value)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output, "")


if __name__ == "__main__":
    unittest.main()
