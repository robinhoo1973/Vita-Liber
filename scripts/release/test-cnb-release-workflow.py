#!/usr/bin/env python3
"""Workflow contract regression: ASR publishing has no GitHub Release writer and
the CNB token is mapped only in the publish step (2026-10-03 plan Task 5).

Parses workflow YAML with the pinned PyYAML dependency; never executes a workflow.
"""
from pathlib import Path
import unittest
import yaml

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"


def workflow_text(name):
    return (WORKFLOWS / name).read_text(encoding="utf-8")


def workflow_yaml(name):
    return yaml.safe_load(workflow_text(name))


class PublicReleaseWorkflowTests(unittest.TestCase):
    def test_active_asr_publisher_has_no_github_release_write(self):
        text = workflow_text("release-asr-models.yml")
        self.assertNotIn("gh release upload", text)
        self.assertNotIn("gh release create", text)
        self.assertNotIn("GH_TOKEN", text)
        self.assertIn("CNB_RESOURCE_TOKEN", text)
        self.assertIn("CNB_RESOURCE_REPOSITORY", text)

    def test_cnb_token_is_only_mapped_in_the_publish_step(self):
        workflow = workflow_yaml("release-asr-models.yml")
        call = workflow.get(True, {}).get("workflow_call", {})
        self.assertIn("CNB_RESOURCE_TOKEN", call.get("secrets", {}))
        for job in workflow.get("jobs", {}).values():
            self.assertNotIn("CNB_RESOURCE_TOKEN", job.get("env", {}))
            for step in job.get("steps", []):
                env = step.get("env", {}) or {}
                if "CNB_TOKEN" in env:
                    self.assertEqual(env["CNB_TOKEN"], "${{ secrets.CNB_RESOURCE_TOKEN }}")
                    # 合法注入面 = 发布步 + 发布前置校验步(2026-10-05 required 降级后
                    # 空值硬错移入 job 内,前置校验必须可见令牌才能判空)。
                    self.assertIn(step["name"], (
                        "发布 ASR Release 至 CNB（不可变资产；回读核对；无需签名私钥）",
                        "发布前置校验（publish=true 必须有 CNB 令牌）",
                    ))
                else:
                    self.assertNotIn("CNB_TOKEN", env)

    def test_publish_step_has_bounded_retry_and_fails_hard(self):
        text = workflow_text("release-asr-models.yml")
        self.assertIn("for attempt in 1 2 3", text)
        self.assertIn("exit 1", text)
        self.assertIn("publish-asr-release.py publish", text)

    def test_prepare_step_uses_anonymous_cnb_repository(self):
        workflow = workflow_yaml("release-asr-models.yml")
        steps = workflow["jobs"]["models"]["steps"]
        prepare = next(s for s in steps if "prepare-asr-source" in s.get("run", ""))
        self.assertNotIn("GH_TOKEN", prepare.get("env", {}) or {})
        self.assertIn("CNB_RESOURCE_REPOSITORY", prepare["run"])

    def test_asr_workflow_decoupled_from_testflight(self):
        # 2026-10-06 业主指令:ASR 构建从 TestFlight 链退役(模型运行时下载),
        # build-testflight 不再调用 release-asr-models;调用面仅剩 workflow_dispatch,
        # CNB 令牌只经 release-asr-models 自身的发布步。
        workflow = workflow_yaml("build-testflight.yml")
        self.assertFalse(any(job.get("uses") for job in workflow.get("jobs", {}).values()),
                         "build-testflight 不得再调用 ASR 构建工作流")
        callable_workflow = workflow_yaml("release-asr-models.yml")
        call = callable_workflow.get(True, {}).get("workflow_call", {})
        self.assertIn("CNB_RESOURCE_TOKEN", call.get("secrets", {}))

    def test_seed_workflow_is_the_only_github_release_read_face(self):
        text = workflow_text("seed-cnb-assets.yml")
        self.assertIn("CNB_RESOURCE_TOKEN", text)
        self.assertNotIn("gh release upload", text)
        self.assertNotIn("gh release create", text)
        # GitHub 读取面只在一次性 seed 脚本内(定案 Task 5:gh release download 仅限此处)
        seed_text = (Path(__file__).with_name("seed-cnb-model-assets.py")).read_text(encoding="utf-8")
        self.assertIn('"gh", "release", "download"', seed_text)
        workflow = workflow_yaml("seed-cnb-assets.yml")
        steps = workflow["jobs"]["seed"]["steps"]
        run_step = next(s for s in steps if "seed-cnb-model-assets" in s.get("run", ""))
        self.assertEqual(run_step["env"]["CNB_TOKEN"], "${{ secrets.CNB_RESOURCE_TOKEN }}")


if __name__ == "__main__":
    unittest.main()
