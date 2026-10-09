"""简繁转换表(OpenCC 钉版)回归——2026-10-08 字节批。

背景(round2 H4/X1):手抄 _S2T_PAIRS 仅 113 有效字,TW/HK 版式样本 13.6–62% 漏转
(门診費→門診費 混排)。换 OpenCC STCharacters+地区变体表后必须:①表在场且可载;
②H4 实测漏转字集全数转换;③TW 变体链(裏→裡)生效;④CN 恒等。
"""
import sys
import unittest
from pathlib import Path

EXTRACT = Path(__file__).resolve().parents[1] / "extract"
sys.path.insert(0, str(EXTRACT))


class S2TTablesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from build_extraction_corpus import _HK_VARIANTS, _S2T_OTC, _TW_VARIANTS, L
        cls.L = staticmethod(L)
        cls.st, cls.tw, cls.hk = _S2T_OTC, _TW_VARIANTS, _HK_VARIANTS

    def test_tables_loaded(self):
        self.assertGreater(len(self.st), 3000, "STCharacters 表缺失/过小(回落到兜底?)")
        self.assertGreater(len(self.tw), 10)
        self.assertGreater(len(self.hk), 10)

    def test_h4_leak_chars_all_convert(self):
        # H4 实测漏转字(表外简体):必须全部转换
        src = "阴产伤图电团银会阳传门费药检报单"
        out = self.L("TW", src)
        for a, b in zip(src, out):
            self.assertNotEqual(a, b, f"{a} 未转换")

    def test_tw_variant_chain(self):
        self.assertEqual(self.L("TW", "裏面"), "裡面")   # ST 后无需变,原繁变体
        self.assertEqual(self.L("TW", "门诊费用"), "門診費用")

    def test_cn_identity(self):
        self.assertEqual(self.L("CN", "门诊费用-基础健康体检"), "门诊费用-基础健康体检")


if __name__ == "__main__":
    unittest.main()
