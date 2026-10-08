"""噪声常量 ↔ policy.json 单一事实源同步负测(2026-10-08 D1 批)。

背景:extract/extraction_noise.py 的运行期常量(训练机副本无 policy.json 布局,
不能运行期依赖文件)必须与 .github/config/distill/policy.json 逐值相等,否则
语料按一套分布产出、门禁按另一套判。builder main 已有 fail-closed 交叉断言;
本测试把同一断言左移到测试期(不等到产出时才红)。

覆盖:bandTargets↔BAND_CER、trainMix↔DEFAULT_TRAIN_MIX、version↔NOISE_VERSION、
ASR 份额带位完备且每带归一。零第三方依赖。
"""
import unittest

from extract.extraction_noise import (ASR_BAND_SHARES, BAND_CER, DEFAULT_TRAIN_MIX,
                                      NOISE_VERSION)
from policy import load


class NoisePolicySyncTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.noise = load()["noise"]

    def test_band_targets_match(self):
        self.assertEqual(self.noise["bandTargets"], BAND_CER,
                         "BAND_CER 与 policy.noise.bandTargets 不一致——先同步两处")

    def test_train_mix_match(self):
        self.assertEqual(self.noise["trainMix"], DEFAULT_TRAIN_MIX,
                         "DEFAULT_TRAIN_MIX 与 policy.noise.trainMix 不一致(注意口径:分数)")

    def test_version_match(self):
        self.assertEqual(self.noise["version"], NOISE_VERSION)

    def test_asr_shares_cover_nonclean_bands_and_sum_to_one(self):
        bands = set(BAND_CER) - {"clean"}
        self.assertEqual(set(ASR_BAND_SHARES), bands,
                         "ASR 份额带位与 bandTargets(除 clean)不一致")
        for band, shares in ASR_BAND_SHARES.items():
            self.assertAlmostEqual(sum(shares.values()), 1.0, places=6,
                                   msg=f"{band} 族份额和≠1")

    def test_train_mix_does_not_leak_into_asr_shares(self):
        # 防回归:曾出现 trainMix 用百分数(15/30/…)与 policy 分数(0.15)失配
        for band, weight in DEFAULT_TRAIN_MIX.items():
            self.assertLessEqual(weight, 1.0, f"trainMix[{band}] 疑似百分数口径")


if __name__ == "__main__":
    unittest.main()
