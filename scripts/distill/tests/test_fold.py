"""fold() 折叠归一化测试:宽度/大小写/标点/幂等。"""
import unittest

from entlink.fold import fold


class FoldTests(unittest.TestCase):
    def test_fullwidth_converges(self):
        self.assertEqual(fold("ＡＢＣ１２３"), "abc123")

    def test_lowercase(self):
        self.assertEqual(fold("AbC"), "abc")

    def test_cjk_punct_stripped(self):
        # 、。《》「」类 CJK 标点剥离;空格剥离
        self.assertEqual(fold("香港大學、深圳《醫院》"), "香港大學深圳醫院")

    def test_fullwidth_paren_converges_to_ascii(self):
        # 全角括号经 NFKC 收敛为 ASCII 括号,ASCII 括号有语义(保留)
        self.assertEqual(fold("香港大學深圳醫院（港大深圳醫院）"), "香港大學深圳醫院(港大深圳醫院)")
        self.assertEqual(fold("香港大學深圳醫院 港大深圳醫院"), "香港大學深圳醫院港大深圳醫院")

    def test_ascii_semantic_punct_kept(self):
        # 连字符/斜杠/括号有语义(复方制剂、浓度),不得折叠
        self.assertIn("-", fold("阿莫西林-克拉维酸钾"))
        self.assertIn("/", fold("10mg/ml"))
        self.assertIn("(", fold("阿莫西林(颗粒)"))

    def test_idempotent(self):
        text = "ＡｂＣ，。醫 院"
        once = fold(text)
        self.assertEqual(fold(once), once)

    def test_empty(self):
        self.assertEqual(fold(""), "")
        self.assertEqual(fold("　"), "")


if __name__ == "__main__":
    unittest.main()
