"""workflow ↔ policy.json 漂移守卫(round2 质询席 C 裁决 2026-10-08)。

背景:llm.yml 曾散抄 policy.json 的值(counts/entlinkMaxSamples/minAccepts/
未登记常量)且发生真实漂移(policy.seed=20261007 vs 实跑 argparse 默认 42)。
本测试把"workflow 只经 policy.py 取值"固化为机械断言:①关键字面量不得留;
②接线字符串必须在;③接线后的取值为真(子进程真跑 policy.py)。

训练机平铺布局无 workflow → skip。
"""
import pathlib
import subprocess
import sys
import unittest

DISTILL = pathlib.Path(__file__).resolve().parents[1]
ROOT = DISTILL.parents[2]          # .github/actions/distill → repo root
WORKFLOW = ROOT / ".github" / "workflows" / "llm.yml"
POLICY = DISTILL / "policy.py"


@unittest.skipUnless(WORKFLOW.is_file(), "CI 布局无 workflow(训练机)——跳过")
class WorkflowPolicyDriftTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")

    def test_no_hardcoded_policy_copies(self):
        for literal in ('default: "27000"', 'default: "40000"', 'default: "4000"',
                        "drug=200000", "--max-terms-per-entity 3",
                        "--exclude-domains department"):
            self.assertNotIn(literal, self.text,
                             f"llm.yml 残留 policy 值副本: {literal}(改经 policy.py)")

    def test_wiring_present(self):
        for needle in ("$POLICY --get corpus.counts.sft",
                       "$POLICY --get corpus.counts.pretrain",
                       "$POLICY --get corpus.counts.dialogue",
                       "$POLICY --get-joined corpus.entlinkMaxSamples",
                       "$POLICY --get gates.entlink.minAcceptsPerBandDomain",
                       "$POLICY --get corpus.entlinkBuild.maxTermsPerEntity",
                       "$POLICY --get corpus.entlinkBuild.excludeDomains",
                       "$POLICY --get corpus.seed",
                       "$POLICY --get corpus.budget",
                       '--budget "$BUDGET"',
                       '--seed "$SEED"'):
            self.assertIn(needle, self.text, f"llm.yml 缺 policy 接线: {needle}")

    def test_budget_single_source_matches_builder_default(self):
        # W21 B 批:预算=policy 单源(llm.yml 经 policy.py 取;训练载荷无 policy.json 时用 builder 默认)
        out = subprocess.run([sys.executable, str(POLICY), "--get", "corpus.budget"],
                             capture_output=True, text=True, cwd=str(DISTILL))
        self.assertEqual(out.returncode, 0, msg=out.stderr)
        self.assertEqual(out.stdout.strip(), "2000")
        sys.path.insert(0, str(DISTILL / "extract"))
        import importlib
        bec = importlib.import_module("build_extraction_corpus")
        self.assertEqual(bec.DEFAULT_BUDGET, int(out.stdout.strip()),
                         "builder DEFAULT_BUDGET 与 policy.corpus.budget 分叉——先同步两处")

    def test_get_joined_returns_cli_string(self):
        out = subprocess.run([sys.executable, str(POLICY), "--get-joined",
                              "corpus.entlinkMaxSamples"],
                             capture_output=True, text=True, cwd=str(DISTILL))
        self.assertEqual(out.returncode, 0, msg=out.stderr)
        self.assertEqual(out.stdout.strip(),
                         "drug=200000,hospital=80000,diagnosis=60000,exam=30000")

    def test_get_joined_rejects_non_dict(self):
        out = subprocess.run([sys.executable, str(POLICY), "--get-joined",
                              "corpus.seed"],
                             capture_output=True, text=True, cwd=str(DISTILL))
        self.assertEqual(out.returncode, 1)

    def test_policy_seed_matches_expected(self):
        out = subprocess.run([sys.executable, str(POLICY), "--get", "corpus.seed"],
                             capture_output=True, text=True, cwd=str(DISTILL))
        self.assertEqual(out.returncode, 0, msg=out.stderr)
        self.assertEqual(out.stdout.strip(), "20261007")

    def test_required_kinds_plus_deferred_equals_registry(self):
        # 声明式网格一致性:requiredKinds ∪ deferredKinds 必须恰等于 builder REGISTRY 键集
        sys.path.insert(0, str(DISTILL / "extract"))
        import importlib
        bec = importlib.import_module("build_extraction_corpus")
        reg = set(bec.REGISTRY.keys())
        sys.path.insert(0, str(DISTILL))
        import policy as _policy
        pol = _policy.load()
        required = set(pol["corpus"]["requiredKinds"])
        deferred = set(pol["corpus"]["deferredKinds"])
        self.assertEqual(required | deferred, reg)
        self.assertEqual(required & deferred, set())


if __name__ == "__main__":
    unittest.main()
