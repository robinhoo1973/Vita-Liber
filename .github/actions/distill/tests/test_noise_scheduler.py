"""extract.noise_scheduler 负测(2026-10-08 数据批;stdlib 可跑)。

覆盖:确定性(同种子同输出)、期望 CER 收敛(随机取整保真)、delete 保底长度、
span_damage_stats 数学、空文本透传。统计断言用足够种子数(200)压方差。
"""
import random
import unittest

from extract.confusion import ConfusionTables
from extract.noise_scheduler import (levenshtein, noisify_segment, span_damage_stats)

SAMPLE = "阿莫西林胶囊 0.25g 每日两次 口服 7天"


class SchedulerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tables = ConfusionTables.load()

    def _run(self, band, target, seeds=200):
        return [noisify_segment(SAMPLE, band=band, cer_target=target,
                                rng=random.Random(s), tables=self.tables)
                for s in range(seeds)]

    def test_deterministic_same_seed(self):
        a = noisify_segment(SAMPLE, band="heavy", cer_target=0.10,
                            rng=random.Random(7), tables=self.tables)
        b = noisify_segment(SAMPLE, band="heavy", cer_target=0.10,
                            rng=random.Random(7), tables=self.tables)
        self.assertEqual(a, b)

    def test_expected_cer_converges_near_target(self):
        for band, target in (("light", 0.02), ("medium", 0.05), ("heavy", 0.10)):
            metas = [m for _, m in self._run(band, target)]
            mean = sum(m["cer_measured"] for m in metas) / len(metas)
            self.assertLess(abs(mean - target), 0.015,
                            f"{band}: mean_cer={mean:.4f} 偏离目标 {target} 超容差")

    def test_light_not_dead_on_short_text(self):
        # 修复回归:整数取整曾把短段 light 预算恒归零——随机取整后 200 种子须有伤害
        pairs = [(SAMPLE, noisy) for noisy, _ in self._run("light", 0.02)]
        self.assertGreater(span_damage_stats(pairs)["damaged"], 0)

    def test_delete_keeps_nonempty(self):
        for s in range(50):
            noisy, _ = noisify_segment("药", band="extreme", cer_target=0.18,
                                       rng=random.Random(s), tables=self.tables)
            self.assertTrue(noisy)

    def test_span_damage_stats_math(self):
        stats = span_damage_stats([("甲", "甲"), ("乙", "乙2"), ("丙", "丙")])
        self.assertEqual(stats, {"spans": 3, "damaged": 1, "rate": round(1 / 3, 4)})
        self.assertEqual(span_damage_stats([]), {"spans": 0, "damaged": 0, "rate": 0.0})

    def test_empty_text_passthrough(self):
        noisy, meta = noisify_segment("", band="heavy", cer_target=0.10,
                                      rng=random.Random(1), tables=self.tables)
        self.assertEqual(noisy, "")
        self.assertEqual(meta["cer_measured"], 0.0)

    def test_levenshtein_basic(self):
        self.assertEqual(levenshtein("abc", "abc"), 0)
        self.assertEqual(levenshtein("abc", "abd"), 1)
        self.assertEqual(levenshtein("abc", "ab"), 1)
        self.assertEqual(levenshtein("abc", "abcd"), 1)


if __name__ == "__main__":
    unittest.main()
