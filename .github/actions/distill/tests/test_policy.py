"""policy.json 读取器负测(2026-10-08 round5;判据单一事实源 fail-closed)。

覆盖:真文件可载入、必需段缺失/占比和不为1/带位集合不一致/红线可覆盖/
路径缺失各行必抛;sha256 形态。零第三方依赖。
"""
import copy
import unittest

from policy import get, load, policy_path, sha256_of, validate


class PolicyLoadTests(unittest.TestCase):
    def setUp(self):
        self.policy = load()

    def test_real_policy_loads(self):
        self.assertEqual(self.policy["schema_version"], 1)
        self.assertIn("extraction", self.policy["gates"])

    def test_get_dotted_scalar(self):
        self.assertEqual(get(self.policy, "gates.extraction.tau"), 0.03)
        self.assertEqual(get(self.policy, "publish.dialogue.publish"), False)

    def test_get_missing_path_raises(self):
        with self.assertRaises(KeyError):
            get(self.policy, "gates.nothing.here")

    def test_missing_top_section_raises(self):
        bad = copy.deepcopy(self.policy)
        del bad["noise"]
        with self.assertRaisesRegex(ValueError, "缺顶层字段"):
            validate(bad)

    def test_train_mix_sum_raises(self):
        bad = copy.deepcopy(self.policy)
        bad["noise"]["trainMix"]["clean"] = 0.5
        with self.assertRaisesRegex(ValueError, "占比和"):
            validate(bad)

    def test_band_set_mismatch_raises(self):
        bad = copy.deepcopy(self.policy)
        del bad["noise"]["spanDamageTargets"]["extreme"]
        with self.assertRaisesRegex(ValueError, "带位集合不一致"):
            validate(bad)

    def test_hard_zero_overridable_raises(self):
        bad = copy.deepcopy(self.policy)
        bad["gates"]["entlink"]["hardZero"]["overridable"] = True
        with self.assertRaisesRegex(ValueError, "红线不可运行期放宽"):
            validate(bad)

    def test_dialogue_change_requires_owner(self):
        bad = copy.deepcopy(self.policy)
        bad["publish"]["dialogue"]["publish"] = True
        bad["publish"]["dialogue"]["changeRequires"] = "ci"
        with self.assertRaisesRegex(ValueError, "业主裁决"):
            validate(bad)

    def test_sha256_shape_and_stability(self):
        first = sha256_of()
        self.assertEqual(first, sha256_of())
        self.assertEqual(len(first), 64)
        int(first, 16)

    def test_policy_path_exists(self):
        self.assertTrue(policy_path().is_file())


if __name__ == "__main__":
    unittest.main()
