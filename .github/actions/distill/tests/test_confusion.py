"""extract.confusion 混淆表装载负测(2026-10-08 数据批 D0;stdlib 可跑)。

覆盖:两表解析(表头/多列/多字符组)、层优先+hub cap 确定性、覆盖率、
真实表入仓件的基本可用性(medically 相关字符必须有镜像)。
"""
import tempfile
import unittest
from pathlib import Path

from extract.confusion import ConfusionTables, load_same_pinyin, load_same_stroke


def _write(dirpath: Path, name: str, text: str) -> Path:
    path = dirpath / name
    path.write_text(text, encoding="utf-8")
    return path


class LoadTests(unittest.TestCase):
    def test_stroke_group_expansion_and_pinyin_columns(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            _write(base, "same_stroke.txt", "#header\n甲甲\t乙\t丙\n")
            _write(base, "same_pinyin.txt", "#汉字\t同音同调\t同音异调\n丁\t戊\t己庚\n")
            stroke = load_same_stroke(base / "same_stroke.txt")
            pinyin = load_same_pinyin(base / "same_pinyin.txt")
            self.assertEqual(stroke["乙"], {"甲", "丙"})
            self.assertEqual(pinyin["丁"]["same_tone"], {"戊"})
            self.assertEqual(pinyin["丁"]["diff_tone"], {"己", "庚"})

    def test_empty_middle_column_keeps_column_semantics(self):
        """C5 负测(2026-10-09 W20):空列不得被过滤——丢列=右侧列左移错位。

        真表同型:`口\\t\\t寇扣`(同音同调空、同音异调=寇扣)。旧解析按 `if cell`
        丢空列 → ["口","寇扣"] → 寇/扣 误入 same_tone(全表 225 行同型:
        寸/丑/仍/内/水/牛/且/凹/北 …)。
        """
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            _write(base, "same_stroke.txt", "#header\n甲\t乙\n")
            _write(base, "same_pinyin.txt", "#汉字\t同音同调\t同音异调\n口\t\t寇扣\n水\t\t谁睡\n")
            pinyin = load_same_pinyin(base / "same_pinyin.txt")
            self.assertEqual(pinyin["口"]["same_tone"], set())
            self.assertEqual(pinyin["口"]["diff_tone"], {"寇", "扣"})
            self.assertEqual(pinyin["水"]["diff_tone"], {"谁", "睡"})

    def test_tier_priority_and_hub_cap_determinism(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            _write(base, "same_stroke.txt", "靶\t靶1\t靶2\n")
            _write(base, "same_pinyin.txt", "靶\t靶3\t靶4\n")
            tables = ConfusionTables.load(base, hub_cap=3)
            first = tables.mirrors_for("靶")
            self.assertEqual(len(first), 3)
            self.assertEqual(first[0][1], "stroke")  # 层优先:形近在前
            self.assertEqual(tables.mirrors_for("靶"), first)  # 确定性(重复调用同值)

    def test_coverage_and_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            _write(base, "same_stroke.txt", "甲\t乙\n")
            _write(base, "same_pinyin.txt", "甲\t丙\n")
            tables = ConfusionTables.load(base)
            self.assertEqual(tables.coverage("甲乙丙丁"), 0.75)
            self.assertEqual(tables.coverage(""), 0.0)


class RealTablesTests(unittest.TestCase):
    """入仓两表(Apache-2.0,见 tables/PROVENANCE.md)可用性冒烟。"""

    def test_medical_chars_have_mirrors(self):
        tables = ConfusionTables.load()
        for ch in "阿莫西胶硝地林":
            self.assertTrue(tables.mirrors_for(ch), f"{ch} 无镜像——表覆盖异常")
        self.assertGreater(len(tables._stroke), 1000)
        self.assertGreater(len(tables._pinyin), 1000)

    def test_kou_row_classified_as_diff_tone(self):
        """C5 钉死(2026-10-09 W20):真表 `口` 行空同音同调列——寇/扣 必须=diff_tone。

        分类错会让同音异调字混入同音族(hub 语义/噪声分布双错;同型 225 行)。
        """
        pinyin = load_same_pinyin()
        self.assertEqual(pinyin["口"]["same_tone"], set())
        self.assertIn("寇", pinyin["口"]["diff_tone"])
        self.assertIn("扣", pinyin["口"]["diff_tone"])


if __name__ == "__main__":
    unittest.main()
