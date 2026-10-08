"""行级结构噪声负测(round5 §2.2;stdlib 可跑)。

覆盖:恒等(clean)、丢行仅无 span、合并整行/双 span 拒绝、交织仅无 span、
切分仅无 span、确定性、跨种子不变量(span 值仍是映射行的逐字子串)。
率值经 mock 覆写以定向触发(不依赖真实带位概率)。
"""
import random
import unittest
from unittest import mock

from extract import line_ops
from extract.line_ops import apply_line_ops


def sp(key, value, li):
    return {"key": key, "value": value, "unit": None, "lineIndex": li}


def with_rates(band, rates):
    return mock.patch.dict(line_ops.BAND_LINE_RATES, {band: rates})


class LineOpsTests(unittest.TestCase):
    def test_clean_identity(self):
        lines = ["A 医院", "科室：心内科"]
        spans = [sp("hospital", "A 医院", 0), sp("department", "心内科", 1)]
        out, shared, rows, st = apply_line_ops(lines, list(spans), [], random.Random(1), band="clean")
        self.assertEqual(out, lines)
        self.assertEqual([s["lineIndex"] for s in shared], [0, 1])
        self.assertEqual(st, {"drop": 0, "merge": 0, "interleave": 0, "split": 0})

    def test_drop_only_no_span_lines(self):
        lines = ["A 医院", "中间噪声行", "科室：心内科"]
        shared = [sp("hospital", "A 医院", 0), sp("department", "心内科", 2)]
        with with_rates("light", {"drop": 1.0}):
            out, shared, _, st = apply_line_ops(lines, list(shared), [], random.Random(3), band="light")
        self.assertEqual(len(out), 2)
        self.assertEqual(st["drop"], 1)
        self.assertEqual(out, ["A 医院", "科室：心内科"])
        self.assertEqual([s["lineIndex"] for s in shared], [0, 1])

    def test_drop_never_touches_span_lines(self):
        lines = ["A 医院", "科室：心内科"]
        shared = [sp("hospital", "A 医院", 0), sp("department", "心内科", 1)]
        with with_rates("light", {"drop": 1.0}):
            out, shared, _, st = apply_line_ops(lines, list(shared), [], random.Random(3), band="light")
        self.assertEqual(st["drop"], 0)
        self.assertEqual(len(out), 2)

    def test_merge_joins_and_shares_index(self):
        lines = ["1. 阿莫西林胶囊", "每次1粒"]
        rows = [[sp("drug_name", "阿莫西林胶囊", 0)]]
        with with_rates("light", {"merge": 1.0}):
            out, _, rows, st = apply_line_ops(lines, [], rows, random.Random(5), band="light")
        self.assertEqual(st["merge"], 1)
        self.assertEqual(len(out), 1)
        s = rows[0][0]
        self.assertEqual(s["lineIndex"], 0)
        self.assertIn(s["value"], out[0])

    def test_merge_refused_when_both_spanned(self):
        lines = ["药品行", "用法行"]
        rows = [[sp("drug_name", "药品行", 0), sp("dosage", "用法行", 1)]]
        with with_rates("light", {"merge": 1.0}):
            out, _, rows, st = apply_line_ops(lines, [], rows, random.Random(5), band="light")
        self.assertEqual(st["merge"], 0)
        self.assertEqual(len(out), 2)
        self.assertIn(rows[0][1]["value"], out[rows[0][1]["lineIndex"]])

    def test_interleave_only_no_span_pairs(self):
        lines = ["A 医院", "噪声行一", "噪声行二"]
        shared = [sp("hospital", "A 医院", 0)]
        with with_rates("light", {"interleave": 1.0}):
            out, shared, _, st = apply_line_ops(lines, list(shared), [], random.Random(9), band="light")
        self.assertEqual(st["interleave"], 1)
        self.assertEqual(out[0], "A 医院")          # span 行不参与
        self.assertEqual(sorted(out[1:]), ["噪声行一", "噪声行二"])
        self.assertEqual(shared[0]["lineIndex"], 0)

    def test_interleave_needs_two_eligible(self):
        lines = ["A 医院", "唯一噪声行"]
        shared = [sp("hospital", "A 医院", 0)]
        with with_rates("light", {"interleave": 1.0}):
            out, shared, _, st = apply_line_ops(lines, list(shared), [], random.Random(9), band="light")
        self.assertEqual(st["interleave"], 0)
        self.assertEqual(out, lines)

    def test_split_only_no_span_lines(self):
        lines = ["A 医院", "噪声 行 甲 乙"]
        shared = [sp("hospital", "A 医院", 0)]
        with with_rates("light", {"split": 1.0}):
            out, shared, _, st = apply_line_ops(lines, list(shared), [], random.Random(11), band="light")
        self.assertEqual(st["split"], 1)
        self.assertEqual(len(out), 3)
        self.assertEqual(out[0], "A 医院")
        self.assertEqual(shared[0]["lineIndex"], 0)

    def test_split_skips_span_lines(self):
        lines = ["A 医院 门诊 处方"]
        shared = [sp("hospital", "A 医院", 0)]
        with with_rates("light", {"split": 1.0}):
            out, shared, _, st = apply_line_ops(lines, list(shared), [], random.Random(11), band="light")
        self.assertEqual(st["split"], 0)
        self.assertEqual(len(out), 1)

    def test_deterministic_same_seed(self):
        lines = ["A", "B", "C", "D", "E"]
        shared = [sp("k", "C", 2)]
        runs = []
        for _ in range(2):
            out, sh, _, st = apply_line_ops(list(lines), [dict(s) for s in shared], [],
                                            random.Random(42), band="extreme")
            runs.append((out, [s["lineIndex"] for s in sh], st))
        self.assertEqual(runs[0], runs[1])

    def test_verbatim_invariant_across_seeds(self):
        lines = ["仁济医院 门诊处方笺", "科室：心内科", "医师：王医生",
                 "阿莫西林胶囊 0.25g 每日两次 口服", "备注：饭后", "第二行噪声"]
        shared = [sp("hospital", "仁济医院", 0), sp("department", "心内科", 1)]
        rows = [[sp("drug_name", "阿莫西林胶囊", 3), sp("dosage", "每日两次", 3)]]
        for band in ("light", "medium", "heavy", "extreme"):
            for seed in range(60):
                out, sh, rw, _ = apply_line_ops(list(lines),
                                                [dict(s) for s in shared],
                                                [[dict(s) for s in r] for r in rows],
                                                random.Random(seed), band=band)
                for s in list(sh) + [s for r in rw for s in r]:
                    self.assertIn(s["value"], out[s["lineIndex"]],
                                  f"band={band} seed={seed} key={s['key']}")


if __name__ == "__main__":
    unittest.main()
