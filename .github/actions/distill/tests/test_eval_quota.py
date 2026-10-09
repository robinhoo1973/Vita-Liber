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


class EvalQuotaKindUnitTests(unittest.TestCase):
    """kind 单元(C 批 2026-10-09 W20):声称的 eval 数必须=实落数。

    回归对象:曾 `for cell, draw, key in entries: by_kind[cell[0]].extend(by_cell[cell])`
    ——按条目重放整 cell → N² 放大:total 虚高;提升沿同一键的相邻副本推进把
    promote 配额耗光 → 声称 937/实落 831(冒烟 声称 60/实落 1)。
    """

    def _run(self, cells_spec, quota=60, ratio=0.03):
        es = []
        for cell, n_below, n_above in cells_spec:
            es.extend(entries(cell, n_below, n_above))
        split, cells = assign_eval_splits(es, eval_ratio=ratio, quota=quota, quota_unit="kind")
        actual = sum(1 for v in split.values() if v == "eval")
        return split, cells, actual

    def test_kind_claim_equals_actual_no_primary(self):
        # 全在阈值上(主分配 0):补足受 max_share 限(100×0.15=15),
        # 关键不变量=声称数=实落数(旧 N² 形态声称 60 而实落 0)
        split, cells, actual = self._run([(("prescription", "light"), 0, 100)])
        self.assertEqual(cells["kind:prescription"]["eval"], 15)
        self.assertEqual(actual, 15)
        self.assertEqual(cells["kind:prescription"]["promoted"], 15)
        self.assertEqual(cells["kind:prescription"]["deficit"], 45)
        self.assertEqual(cells["kind:prescription"]["total"], 100)   # 真总数(非 100×100)

    def test_kind_claim_equals_actual_multi_cell(self):
        # 350 条主分 5;cap=int(350×0.15)=52 → 补 47,缺口 8 如实登记
        split, cells, actual = self._run([(("prescription", "light"), 5, 95),
                                          (("prescription", "heavy"), 0, 200),
                                          (("prescription", "clean"), 0, 50)])
        self.assertEqual(cells["kind:prescription"]["eval"], actual)
        self.assertEqual(actual, 52)
        self.assertEqual(cells["kind:prescription"]["promoted"], 47)
        self.assertEqual(cells["kind:prescription"]["deficit"], 8)

    def test_kind_total_is_true_entry_count(self):
        # N² 回归:5 带各 n 条 → total 必须=n 的和,不是 n² 的和
        spec = [(("prescription", b), 0, n) for b, n in
                (("clean", 30), ("light", 25), ("medium", 15), ("heavy", 8), ("extreme", 3))]
        _, cells, _ = self._run(spec)
        self.assertEqual(cells["kind:prescription"]["total"], 81)
        self.assertEqual(cells["prescription|light"]["total"], 25)

    def test_kind_promoted_counter_counts_distinct_keys(self):
        split, cells, actual = self._run([(("medication", "light"), 0, 100)])
        self.assertEqual(cells["kind:medication"]["promoted"], actual)
        self.assertEqual(sum(1 for v in split.values() if v == "eval"),
                         cells["kind:medication"]["eval"])



if __name__ == "__main__":
    unittest.main()
