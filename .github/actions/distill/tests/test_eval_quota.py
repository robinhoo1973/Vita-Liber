"""eval 定额分配负测(round5 §2.2 数据批;stdlib 可跑)。

覆盖:比例主分配、定额补足、占比上限(微构建保 SFT)、quota=0 等价纯比例、
多单元隔离、逐位可复现、per-sample 键稳定性。用手造 draw 值(不依赖表)。
"""
import unittest

from extract.build_extraction_corpus import EVAL_MAX_SHARE, assign_eval_splits, sample_draw

THRESHOLD_003 = int(0.03 * (1 << 64))
BELOW = THRESHOLD_003 // 2      # 主分配命中
ABOVE = THRESHOLD_003 * 2       # 主分配未命中


def entries(cell, n_below, n_above):
    out, i = [], 0
    for j in range(n_below):
        out.append((cell, BELOW + j, f"{cell[0]}-{cell[1]}-b{j}"))
    for j in range(n_above):
        out.append((cell, ABOVE + j, f"{cell[0]}-{cell[1]}-a{j}"))
    i = n_below + n_above
    assert i == len(out)
    return out


class EvalQuotaTests(unittest.TestCase):
    CELL = ("prescription", "light")

    def test_quota_promotes_to_min(self):
        # 500 条主分 15 → 定额 60,上限 500*0.15=75 → 补 45 达标
        split, cells = assign_eval_splits(entries(self.CELL, 15, 485),
                                          eval_ratio=0.03, quota=60)
        cell = cells["prescription|light"]
        self.assertEqual(cell["eval"], 60)
        self.assertEqual(cell["promoted"], 45)
        self.assertEqual(cell["deficit"], 0)
        self.assertEqual(sum(1 for v in split.values() if v == "eval"), 60)

    def test_cap_bounds_promotion_on_small_cells(self):
        # 200 条主分 6 → 定额 60 但上限 30 → 只补到 30,deficit 如实登记
        split, cells = assign_eval_splits(entries(self.CELL, 6, 194),
                                          eval_ratio=0.03, quota=60)
        cell = cells["prescription|light"]
        self.assertEqual(cell["eval"], 30)
        self.assertEqual(cell["deficit"], 30)
        self.assertEqual(cell["total"], 200)

    def test_quota_zero_is_ratio_only(self):
        split, cells = assign_eval_splits(entries(self.CELL, 15, 485),
                                          eval_ratio=0.03, quota=0)
        self.assertEqual(cells["prescription|light"]["eval"], 15)
        self.assertEqual(cells["prescription|light"]["deficit"], 0)

    def test_cells_isolated(self):
        es = entries(("prescription", "light"), 5, 495) + entries(("medication", "heavy"), 0, 100)
        split, cells = assign_eval_splits(es, eval_ratio=0.03, quota=60)
        self.assertEqual(cells["prescription|light"]["eval"], 60)   # 上限 75,补足
        self.assertEqual(cells["medication|heavy"]["eval"], 15)     # 100*0.15,补足受上限
        self.assertEqual(cells["medication|heavy"]["deficit"], 45)

    def test_deterministic_repeat(self):
        es = entries(self.CELL, 15, 485)
        a, _ = assign_eval_splits(es, eval_ratio=0.03, quota=60)
        b, _ = assign_eval_splits(es, eval_ratio=0.03, quota=60)
        self.assertEqual(a, b)

    def test_eval_never_exceeds_cap_share(self):
        split, _ = assign_eval_splits(entries(self.CELL, 0, 50),
                                      eval_ratio=0.03, quota=60)
        n_eval = sum(1 for v in split.values() if v == "eval")
        self.assertLessEqual(n_eval, int(50 * EVAL_MAX_SHARE))

    def test_sample_draw_stable_and_seed_dependent(self):
        self.assertEqual(sample_draw(7, "extract-prescription-000001"),
                         sample_draw(7, "extract-prescription-000001"))
        self.assertNotEqual(sample_draw(7, "a"), sample_draw(8, "a"))
        self.assertLess(sample_draw(7, "a"), 1 << 64)

    def test_forced_eval_always_eval(self):
        # 值级 holdout 强制入 eval:即便 quota=0 且 draw 高于阈值
        es = entries(self.CELL, 0, 10)
        forced = {es[0][2], es[5][2]}
        split, cells = assign_eval_splits(es, eval_ratio=0.03, quota=0, forced_eval=forced)
        for k in forced:
            self.assertEqual(split[k], "eval")
        self.assertEqual(cells["prescription|light"]["eval"], 2)



if __name__ == "__main__":
    unittest.main()
