"""policy.json 读取器负测(2026-10-08 round5;判据单一事实源 fail-closed)。

覆盖:真文件可载入、必需段缺失/占比和不为1/带位集合不一致/红线可覆盖/
路径缺失各行必抛;sha256 形态。零第三方依赖。
"""
import copy
import json
import unittest

from policy import catalog_path, get, load, policy_path, sha256_of, validate


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


# —— 许可准入矩阵(H5 合规席 2026-10-08)——
    def test_unknown_license_class_rejected(self):
        bad = copy.deepcopy(self.policy)
        bad["licenses"]["sources"]["TFDA"]["class"] = "made-up-class"
        with self.assertRaisesRegex(ValueError, "不在准入矩阵"):
            validate(bad)

    def test_prohibited_class_in_sources_rejected(self):
        bad = copy.deepcopy(self.policy)
        bad["licenses"]["sources"]["Wikipedia"] = {"class": "cc-by-sa", "attribution": "x"}
        with self.assertRaisesRegex(ValueError, "禁再分发"):
            validate(bad)

    def test_missing_attribution_for_required_class_rejected(self):
        bad = copy.deepcopy(self.policy)
        del bad["licenses"]["sources"]["TFDA"]["attribution"]
        with self.assertRaisesRegex(ValueError, "缺 attribution"):
            validate(bad)

    def test_licenses_change_requires_owner(self):
        bad = copy.deepcopy(self.policy)
        bad["licenses"]["changeRequires"] = "ci"
        with self.assertRaisesRegex(ValueError, "业主裁决"):
            validate(bad)

    def test_cc0_needs_no_attribution(self):
        ok = copy.deepcopy(self.policy)
        ok["licenses"]["sources"]["Wikidata"] = {"class": "cc0", "attribution": None}
        validate(ok)  # 不抛即通过


# —— weights.modelId 目标件对齐(E2;2026-10-09)——
    def test_weights_model_id_in_app_catalog(self):
        catalog = json.loads(catalog_path().read_text(encoding="utf-8"))
        entry_ids = [m["id"] for m in catalog["models"]]
        self.assertTrue(entry_ids, "App LLMCatalog 条目集为空——对齐判据失效")
        self.assertIn(self.policy["weights"]["modelId"], entry_ids,
                      "weights.modelId 不在 App LLMCatalog——训练目标件必须=部署件(E2)")

    def test_weights_model_id_off_catalog_rejected(self):
        bad = copy.deepcopy(self.policy)
        bad["weights"]["modelId"] = "medical-llm-64m-q4-k-m"   # E2 错位复现
        with self.assertRaisesRegex(ValueError, "不在 App LLMCatalog"):
            validate(bad)

    def test_weights_model_id_missing_rejected(self):
        bad = copy.deepcopy(self.policy)
        del bad["weights"]["modelId"]
        with self.assertRaisesRegex(ValueError, "非空字符串"):
            validate(bad)


if __name__ == "__main__":
    unittest.main()
