"""CharSymSpell:暴力对拍(召回完整性与距离正确性)+ 边界。"""
import itertools
import unittest

from entlink.fuzzy import CharSymSpell, levenshtein


def brute_levenshtein(a, b):
    if a == b:
        return 0
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + (ca != cb), prev[j - 1] + (ca != cb), cur[-1] + 1))
        prev = cur
    return prev[-1]


class LevenshteinTests(unittest.TestCase):
    def test_matches_brute(self):
        rng_words = ["阿莫西林", "阿西莫林", "内科", "内咳", "血常规", "血常規", "abc", "abd", ""]
        for a, b in itertools.product(rng_words, repeat=2):
            self.assertEqual(levenshtein(a, b), brute_levenshtein(a, b), f"{a!r} vs {b!r}")

    def test_max_dist_prunes(self):
        self.assertEqual(levenshtein("abcdef", "zzzzzz", max_dist=2), 3)

    def test_shortcut_equal(self):
        self.assertEqual(levenshtein("阿莫西林", "阿莫西林"), 0)


class CharSymSpellTests(unittest.TestCase):
    TERMS = ["阿莫西林", "阿莫西林克拉维酸钾", "阿司匹林", "内科", "外科", "血常规", "全血细胞计数"]

    def _sym(self, max_edit=2):
        s = CharSymSpell(max_edit=max_edit)
        s.build(self.TERMS)
        return s

    def test_exact(self):
        hits = self._sym().lookup("阿莫西林")
        self.assertEqual(hits[0], ("阿莫西林", 0))

    def test_one_edit(self):
        hits = self._sym().lookup("阿莫西淋")  # 林→淋 替换,dist=1
        self.assertEqual(hits[0], ("阿莫西林", 1))

    def test_two_edit_sorted_by_term(self):
        hits = self._sym().lookup("阿西莫林")  # 与阿莫西林/阿司匹林均为 dist2,按词条排序
        self.assertIn(("阿莫西林", 2), hits)
        self.assertIn(("阿司匹林", 2), hits)
        self.assertTrue(all(dist <= 2 for _, dist in hits))

    def test_recall_parity_with_brute(self):
        """SymSpell delete 索引的召回完整性:≤2 距离的候选不得漏。"""
        sym = self._sym()
        for query in self.TERMS:
            expected = [(t, brute_levenshtein(query, t)) for t in self.TERMS if brute_levenshtein(query, t) <= 2]
            got = set(sym.lookup(query))
            for term, dist in expected:
                self.assertIn((term, dist), got, f"漏召回: {query!r} → {term!r}")

    def test_max_edit_one(self):
        sym = CharSymSpell(max_edit=1)
        sym.build(["内科", "外科"])
        # 内咳→内科 替换距离 1,属合法召回;内咳→外科 距离 2,超 max_edit 被剪枝
        self.assertEqual(sym.lookup("内咳", max_dist=1), [("内科", 1)])
        # 精确命中置顶,距离 1 的邻居(外科)一并召回且排序确定
        self.assertEqual(sym.lookup("内科", max_dist=1), [("内科", 0), ("外科", 1)])

    def test_deterministic_order(self):
        sym = self._sym()
        first = sym.lookup("阿莫西林")
        for _ in range(5):
            self.assertEqual(sym.lookup("阿莫西林"), first)

    def test_max_edit_bounds(self):
        with self.assertRaises(ValueError):
            CharSymSpell(max_edit=3)


if __name__ == "__main__":
    unittest.main()
