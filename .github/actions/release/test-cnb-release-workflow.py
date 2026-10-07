#!/usr/bin/env python3
"""Workflow contract regression: ASR publishing has no GitHub Release writer and
the CNB token is mapped only in the publish step (2026-10-03 plan Task 5).

Parses workflow YAML with the pinned PyYAML dependency; never executes a workflow.
"""
from pathlib import Path
import unittest
import yaml

def _repo_root() -> Path:
    # 仓库根探测：逐级向上找 CoreKit/Sources/Domain 锚点（禁 parents[N] 固定层级——
    # 2026-10-07 簇迁 .github/actions/ 后旧索引必坏，漂移实测族）。
    probe = Path(__file__).resolve().parent
    while probe != probe.parent and not (probe / "CoreKit" / "Sources" / "Domain").is_dir():
        probe = probe.parent
    return probe


WORKFLOWS = _repo_root() / ".github" / "workflows"


def workflow_text(name):
    return (WORKFLOWS / name).read_text(encoding="utf-8")


def workflow_yaml(name):
    return yaml.safe_load(workflow_text(name))


class PublicReleaseWorkflowTests(unittest.TestCase):
    def test_active_asr_publisher_has_no_github_release_write(self):
        text = workflow_text("asr.yml")
        self.assertNotIn("gh release upload", text)
        self.assertNotIn("gh release create", text)
        self.assertNotIn("GH_TOKEN", text)
        self.assertIn("CNB_RESOURCE_TOKEN", text)
        self.assertIn("CNB_RESOURCE_REPOSITORY", text)

    def test_cnb_token_is_only_mapped_in_the_publish_step(self):
        workflow = workflow_yaml("asr.yml")
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
                        "发布 ASR Release 至 CNB（不可变资产；回读核对）",
                        "CNB 令牌前置校验（发布是本链的既定终点）",
                    ))
                else:
                    self.assertNotIn("CNB_TOKEN", env)

    def test_publish_step_has_bounded_retry_and_fails_hard(self):
        text = workflow_text("asr.yml")
        self.assertIn("for attempt in 1 2 3", text)
        self.assertIn("exit 1", text)
        self.assertIn("publish-asr-release.py publish", text)

    def test_prepare_step_uses_anonymous_cnb_repository(self):
        workflow = workflow_yaml("asr.yml")
        steps = workflow["jobs"]["models"]["steps"]
        prepare = next(s for s in steps if "prepare-asr-source" in s.get("run", ""))
        self.assertNotIn("GH_TOKEN", prepare.get("env", {}) or {})
        self.assertIn("CNB_RESOURCE_REPOSITORY", prepare["run"])

    def test_asr_workflow_decoupled_from_testflight(self):
        # 2026-10-06 业主指令:ASR 构建从 TestFlight 链退役(模型运行时下载),
        # build-testflight 不再调用 release-asr-models;调用面仅剩 workflow_dispatch,
        # CNB 令牌只经 release-asr-models 自身的发布步。
        # 2026-10-07 收窄为白名单语义（平台席二轮）：原「不得有任何 job 级 uses」
        # 过宽——立法意图=不调 ASR/发布类；build-testflight 允许的唯一本地 reusable
        # = l0-static-gate.yml（gates 单源，消双副本），新增任何其它 uses 必须
        # 过评审（本断言即评审闸）。
        workflow = workflow_yaml("testflight.yml")
        # job 级 uses 恒空（2026-10-07 起 gates 执行体为 composite action,非 reusable）。
        uses_refs = [job.get("uses") for job in workflow.get("jobs", {}).values() if job.get("uses")]
        self.assertEqual(uses_refs, [], "build-testflight 不得有 job 级 uses（不调 ASR 构建工作流）")
        # 接线证明（贴标签≠接线）：gates job 的步骤必须真实调用本地 L0 门禁 composite。
        step_uses = [step.get("uses", "")
                     for job in workflow.get("jobs", {}).values()
                     for step in job.get("steps", [])]
        self.assertIn("./.github/actions/l0-gate", step_uses,
                      "gates job 必须以 composite action 形式接线 L0 门禁")
        callable_workflow = workflow_yaml("asr.yml")
        call = callable_workflow.get(True, {}).get("workflow_call", {})
        self.assertIn("CNB_RESOURCE_TOKEN", call.get("secrets", {}))

    def test_seed_script_is_the_only_github_release_read_face(self):
        # seed-cnb-assets.yml 已删除（业主 2026-10-07：本地离线执行完成，不再需要
        # yml）。GitHub Release 读取面策略保留在脚本层：仅 seed-cnb-model-assets.py
        # 允许 gh release download（本地低频迁移工具）。
        seed_text = (Path(__file__).with_name("seed-cnb-model-assets.py")).read_text(encoding="utf-8")
        self.assertIn('"gh", "release", "download"', seed_text)


if __name__ == "__main__":
    unittest.main()
