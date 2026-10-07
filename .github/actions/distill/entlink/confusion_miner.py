"""混淆对动态挖掘:噪声模型表从目录数据派生,而非手写有限 hardcode。

两族可挖、一族不可挖(原因登记):
- VARIANT(繁简/区域变体):同一实体的名称与别名之间只差字符替换的成对词条,
  按字符替换对计数、阈值过滤——HK 医院别名含简体形态、药品别名含区域形态,
  监督信号就在目录自身(数据席实测确认 v4 投影三列俱在)。
- HOMOPHONE(同音):目录全量词条按拼音分组,同拼音不同字的高频共现对。
- LOOKALIKE(形近):**无合法数据源**——真实 OCR 形近错误对只能来自用户识别
  回执(零 PHI 纪律禁采),合成噪声器无法自举形近分布;保留人工种子表,
  阈值与来源在 manifest 登记。真实噪声迁移验证依赖计划文档 §10 的
  去标识 pilot 集(推翻条件:与合成集分带 recall 差 <15pt)。

产物:MinedConfusions(变体对/同音池,含计数),供 builder 与种子表合并;
合并后的有效噪声模型整体写入语料 manifest(版本+sha256),评测逐字节复现。
"""
from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass, field

from . import pinyin
from .catalog import Catalog
from .fold import fold

MINER_VERSION = "1.0"


@dataclass
class MinedConfusions:
    variant_pairs: Counter = field(default_factory=Counter)       # (char_a, char_b) -> count
    homophone_pools: dict[str, Counter] = field(default_factory=dict)  # pinyin -> {char: count}
    version: str = MINER_VERSION
    pinyin_available: bool = False

    def trimmed_variants(self, min_count: int = 2, max_pairs: int = 500) -> dict[str, str]:
        """对称变体表(双向),按计数截断。"""
        out: dict[str, str] = {}
        for (a, b), count in self.variant_pairs.most_common():
            if count < min_count or len(out) >= max_pairs:
                break
            out[a] = b
            out[b] = a
        return out

    def trimmed_homophones(self, min_count: int = 2, max_chars_per_pinyin: int = 6) -> dict[str, tuple[str, ...]]:
        out: dict[str, tuple[str, ...]] = {}
        for py, counter in sorted(self.homophone_pools.items()):
            chars = tuple(ch for ch, count in counter.most_common(max_chars_per_pinyin) if count >= min_count)
            if len(chars) >= 2:
                out[py] = chars
        return out


def _substitution_pairs(a: str, b: str) -> list[tuple[str, str]]:
    """等长词条间只差字符替换的位置对;长度不等返回空(删除/插入不参与挖掘)。"""
    if len(a) != len(b) or not a:
        return []
    return [(ca, cb) for ca, cb in zip(a, b) if ca != cb]


def mine_variants(catalog: Catalog) -> Counter:
    """同实体名称/别名两两配对,字符替换对计数(繁简/区域变体监督信号)。"""
    pairs: Counter = Counter()
    for entity in catalog.entities:
        terms = []
        for kind in ("name_zh", "short_name", "name_en"):
            raw = entity.names.get(kind)
            if raw:
                terms.append(raw)
        terms.extend(entity.aliases)
        folded = [fold(t) for t in terms]
        for i in range(len(terms)):
            for j in range(i + 1, len(terms)):
                for a, b in _substitution_pairs(folded[i], folded[j]):
                    pairs[(a, b)] += 1
    return pairs


def mine_homophones(catalog: Catalog) -> dict[str, Counter]:
    """全量词条按字符拼音分组,同拼音多字符共现池(ASR 同音混淆候选)。"""
    if not pinyin.available():
        return {}
    pools: dict[str, Counter] = defaultdict(Counter)
    for entity in catalog.entities:
        for kind in ("name_zh", "short_name"):
            raw = entity.names.get(kind)
            if not raw:
                continue
            for ch in raw:
                if "一" <= ch <= "鿿":
                    py = pinyin.to_pinyin(ch)
                    if py:
                        pools[pinyin.norm_key(py)][ch] += 1
    return dict(pools)


def mine(catalog: Catalog) -> MinedConfusions:
    return MinedConfusions(
        variant_pairs=mine_variants(catalog),
        homophone_pools=mine_homophones(catalog),
        pinyin_available=pinyin.available(),
    )
