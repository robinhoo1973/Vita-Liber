"""字符级容错候选查找:SymSpell 风格 delete 索引 + 验证距离。

为什么自己实现而非依赖 symspellpy(成熟实现优先原则的例外登记):
- 核心逻辑约百行,候选生成唯一性可用暴力对拍在 CI 秒级证明(test_fuzzy.py);
- 零第三方依赖 ⟹ L0/本地评测基线零供应链面,checkpoint 可复现;
- symspellpy 面向词频拼写纠正(词级),本场景是**字符级** CJK 词条召回
  (编辑距离 ≤2 的形近/丢字/粘连),词条无词频概念。

算法:SymSpell 的 delete-only 候选生成(SymSpell: 100万倍加速的拼写
纠正, Garbe 2012)——对词典每个词条预生成距离 ≤d 的所有 delete 变体,
查询时对查询串做同样 delete,取交集候选后用 Levenshtein 验证。
"""
from __future__ import annotations

from collections import defaultdict
from typing import Iterable


def levenshtein(a: str, b: str, max_dist: int | None = None) -> int:
    """标准 Levenshtein 距离(两行滚动数组);max_dist 给定时提前剪枝。

    用于 OCR 形近/丢字/粘连场景,不做 transposition 优惠(Damerau 的
    交换步对中文识别噪声无意义,还会把「阿莫西林/阿西莫林」类真错判近)。
    """
    if a == b:
        return 0
    if max_dist is not None and abs(len(a) - len(b)) > max_dist:
        return max_dist + 1
    if len(a) > len(b):
        a, b = b, a
    prev = list(range(len(a) + 1))
    for i, cb in enumerate(b, 1):
        cur = [i]
        row_min = i
        for j, ca in enumerate(a, 1):
            cost = prev[j - 1] + (0 if ca == cb else 1)
            cost = min(cost, prev[j] + 1, cur[j - 1] + 1)
            cur.append(cost)
            row_min = min(row_min, cost)
        if max_dist is not None and row_min > max_dist:
            return max_dist + 1
        prev = cur
    return prev[-1]


def _deletes(word: str, max_edit: int) -> set[str]:
    """delete-only 候选生成(SymSpell 原算法:每层对上一层结果继续删)。"""
    result = {word}
    frontier = {word}
    for _ in range(max_edit):
        nxt = set()
        for w in frontier:
            for i in range(len(w)):
                nxt.add(w[:i] + w[i + 1 :])
        frontier = nxt - result
        result |= nxt
    return result


class CharSymSpell:
    """字符级 delete 索引词典:build() 后 lookup() 返回 (term, dist) 列表。

    词条须**先经 fold()** 再入词典(查询侧同样折叠后查询)。
    """

    def __init__(self, max_edit: int = 2):
        if not 1 <= max_edit <= 2:
            raise ValueError("max_edit must be 1 or 2 (SymSpell delete 索引的合理上界)")
        self.max_edit = max_edit
        self._index: dict[str, set[str]] = defaultdict(set)
        self._terms: set[str] = set()

    def build(self, terms: Iterable[str]) -> None:
        for term in terms:
            if term in self._terms:
                continue
            self._terms.add(term)
            for variant in _deletes(term, self.max_edit):
                if len(variant) >= 1:
                    self._index[variant].add(term)

    def __len__(self) -> int:
        return len(self._terms)

    def lookup(self, query: str, max_dist: int | None = None) -> list[tuple[str, int]]:
        """返回候选 [(term, dist)],按距离升序、词条升序(确定性输出)。"""
        limit = self.max_edit if max_dist is None else min(max_dist, self.max_edit)
        candidates: set[str] = set()
        for variant in _deletes(query, limit):
            candidates |= self._index.get(variant, set())
        hits = []
        for term in candidates:
            dist = levenshtein(query, term, max_dist=limit)
            if dist <= limit:
                hits.append((term, dist))
        hits.sort(key=lambda pair: (pair[1], pair[0]))
        return hits
