"""gate.extraction_gate 负测(2026-10-08 round5;评分器自身正确性纪律)。

覆盖: identity 自证(gold 当 pred → F1=1 硬零=0)、近形值→partial 0.5、
错键→miss、非法 JSON→H1、非逐字→H2、文法字符→H3、硬负例建行→H4、结构错→H5、
worst_cell 取最差不补偿、underpowered 标记、tripwire 全拒识。零第三方依赖。
"""
import json
import unittest

from gate.extraction_gate import aggregate, score_sample, worst_cell


def _gold():
    return {
        "shared": [{"key": "hospital", "value": "某某医院", "lineIndex": 0}],
        "rows": [[{"key": "drug_name", "value": "阿莫西林", "lineIndex": 1},
                  {"key": "dosage", "value": "1片", "lineIndex": 1}]],
    }


def _pred(data):
    return json.dumps(data, ensure_ascii=False)


class ScoreSampleTests(unittest.TestCase):
    def test_identity_arm_all_green(self):
        res = score_sample(gold=_gold(), pred_text=_pred(_gold()))
        self.assertEqual(res["strict_tp"], 3)
        self.assertEqual(res["gold"], 3)
        self.assertEqual(sum(res["hard_zero"].values()), 0)

    def test_near_value_partial_credit(self):
        pred = _gold()
        pred["rows"][0][0]["value"] = "阿莫西"  # 子串
        res = score_sample(gold=_gold(), pred_text=_pred(pred))
        self.assertEqual(res["strict_tp"], 2)
        self.assertEqual(res["partial_n"], 1)
        self.assertEqual(res["hard_zero"]["non_verbatim"], 0)

    def test_wrong_key_is_miss(self):
        pred = _gold()
        pred["rows"][0][0]["key"] = "spec"
        res = score_sample(gold=_gold(), pred_text=_pred(pred))
        self.assertEqual(res["strict_tp"], 2)
        self.assertEqual(res["partial_n"], 0)

    def test_invalid_json_h1(self):
        res = score_sample(gold=_gold(), pred_text="不是 JSON")
        self.assertEqual(res["hard_zero"]["json_invalid"], 1)
        self.assertEqual(res["strict_tp"], 0)
        self.assertEqual(res["pred"], 0)

    def test_non_verbatim_h2(self):
        pred = _gold()
        pred["rows"][0][0]["value"] = "阿莫西林胶囊"  # 行内不存在该词面
        lines = ["某某医院", "阿莫西林 1片"]
        res = score_sample(gold=_gold(), pred_text=_pred(pred), lines=lines)
        self.assertEqual(res["hard_zero"]["non_verbatim"], 1)

    def test_unreachable_char_h3_input_side(self):
        res = score_sample(gold=_gold(), pred_text=_pred(_gold()),
                           unreachable_chars={"莫"})
        self.assertEqual(res["hard_zero"]["grammar_char"], 1)

    def test_negative_row_h4(self):
        pred = _gold()
        pred["rows"][0].append({"key": "drug_name", "value": "青霉素", "lineIndex": 7})
        res = score_sample(gold=_gold(), pred_text=_pred(pred), neg_lines={7})
        self.assertEqual(res["hard_zero"]["negative_row"], 1)

    def test_structure_error_h5(self):
        res = score_sample(gold=_gold(),
                           pred_text=json.dumps({"shared": [{"key": 1}], "rows": "bad"}))
        self.assertGreaterEqual(res["hard_zero"]["structure"], 1)


def _cell(f1, samples, under=False):
    cell = {"samples": samples, "strict": {"p": 0, "r": 0, "f1": f1},
            "partial": {"p": 0, "r": 0, "f1": f1},
            "hard_zero": {"json_invalid": 0}, "tripwire": {"accepts": 0}}
    if under:
        cell["underpowered"] = True
    return cell


class AggregateTests(unittest.TestCase):
    def test_worst_cell_min_no_compensation(self):
        cells = {"light|prescription": _cell(0.99, 100),
                 "extreme|metric_sample": _cell(0.71, 100)}
        worst = worst_cell(cells, min_samples=50)
        self.assertEqual(worst["cell"], "extreme|metric_sample")
        self.assertEqual(worst["f1_strict"], 0.71)

    def test_underpowered_excluded(self):
        cells = {"a|b": _cell(0.10, 80, under=True), "c|d": _cell(0.80, 80)}
        worst = worst_cell(cells, min_samples=50)
        self.assertEqual(worst["cell"], "c|d")

    def test_aggregate_groups_and_partial_formula(self):
        r1 = {"strict_tp": 2, "partial_n": 1, "gold": 3, "pred": 3,
              "hard_zero": {"json_invalid": 0},
              "meta": {"band": "light", "kind": "prescription"}}
        r2 = {"strict_tp": 3, "partial_n": 0, "gold": 3, "pred": 3,
              "hard_zero": {"json_invalid": 0},
              "meta": {"band": "light", "kind": "prescription"}}
        cells = aggregate([r1, r2], by=("band", "kind"), min_samples=1)
        cell = cells["light|prescription"]
        self.assertEqual(cell["samples"], 2)
        # strict: tp=5/6 → R=5/6; partial: (5+0.5)/6
        self.assertAlmostEqual(cell["partial"]["r"], 5.5 / 6, places=6)

    def test_tripwire_all_rejected(self):
        r = {"strict_tp": 0, "partial_n": 0, "gold": 3, "pred": 0,
             "hard_zero": {"json_invalid": 0}, "meta": {"band": "light", "kind": "x"}}
        cell = aggregate([r], min_samples=1)["light|x"]
        self.assertTrue(cell["tripwire"]["all_rejected"])
        self.assertFalse(cell["strict"]["r"] > 0)


if __name__ == "__main__":
    unittest.main()
