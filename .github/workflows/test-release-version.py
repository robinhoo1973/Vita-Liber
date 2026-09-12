#!/usr/bin/env python3
"""Execute the real version step: a model Release must not decide the App version."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml


WORKFLOWS = Path(__file__).resolve().parent


class ReleaseVersionTests(unittest.TestCase):
    def run_step(self, version, *, ref_type="branch", ref_name="master"):
        document = yaml.safe_load((WORKFLOWS / "build-testflight.yml").read_text())
        step = next(s for s in document["jobs"]["version"]["steps"] if s.get("id") == "ver")
        script = step["run"].replace("${{ github.run_number }}", "27").replace("${{ github.run_attempt }}", "2")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            if version is not None:
                (root / "version.txt").write_text(version)
            helpers = root / ".github/workflows"
            helpers.mkdir(parents=True)
            for helper in WORKFLOWS.glob("*.py"):
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
        self.assertIn("build=027.2\n", output)
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
