"""分层确定性召回引擎(计划文档 §6 S1 / §10 数据基线对照臂的执行体)。

分层(编号即优先级,低层命中优先于高层):
  L0 精确命中:查询折叠后 == 名称折叠后
  L1 别名命中:查询折叠后 == 别名折叠后
  L2 首字母命中:拼音首字母串相等(pypinyin 不可用时本层自动缺位)
  L3 全拼命中:全拼串相等(同上)
  L4 编辑距离 ≤2:CharSymSpell 候选 + Levenshtein 验证(字符级)

纪律:
- 查询与词条**必须**同过 fold();引擎对输入一律折叠,不做原始文本匹配。
- 输出确定性(同输入同输出):候选按 (层级, 分数, 词条) 排序后取 top_k。
- 域过滤:search(domain=...) 只搜该域索引;不传则四域全搜(评测带×域须按域搜)。
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable

from . import pinyin
from .catalog import Catalog, Entity
from .fold import fold
from .fuzzy import CharSymSpell

LAYER_ORDER = ("exact", "alias", "initials", "pinyin", "fuzzy")

_LAYER_PRIORITY = {name: i for i, name in enumerate(LAYER_ORDER)}

_LAYER_BASE_SCORE = {"exact": 1.0, "alias": 1.0, "initials": 0.95, "pinyin": 0.9, "fuzzy": 0.8}


@dataclass(frozen=True)
class RecallCandidate:
    entity_id: str
    domain: str
    region: str
    matched_term: str  # 目录侧被命中的词条(原始形态,便于展示「目录相近条目」)
    layer: str
    score: float
    dist: int | None = None


class RecallEngine:
    """确定性召回。build() 之后 search() 线程安全(只读索引)。"""

    def __init__(self, max_edit: int = 2):
        self.max_edit = max_edit
        self._by_domain: dict[str, list[Entity]] = {}
        self._exact: dict[str, dict[str, Entity]] = {}       # domain -> folded name -> entity
        self._alias: dict[str, dict[str, Entity]] = {}       # domain -> folded alias -> entity
        self._initials: dict[str, dict[str, Entity]] = {}    # domain -> norm(initials) -> entity
        self._pinyin: dict[str, dict[str, Entity]] = {}      # domain -> norm(pinyin) -> entity
        self._fuzzy: dict[str, CharSymSpell] = {}
        self.pinyin_available = False

    # ------------------------------------------------------------ 构建
    def build(self, catalog: Catalog) -> "RecallEngine":
        self.pinyin_available = pinyin.available()
        # 重建前必须清空全部索引:同实例二次 build 若新目录缺某域,旧域索引会
        # 残留造成跨目录串档(历史教训:build 幂等≠可安全重建)。
        self._by_domain, self._exact, self._alias = {}, {}, {}
        self._initials, self._pinyin, self._fuzzy = {}, {}, {}
        grouped: dict[str, list[Entity]] = {}
        for entity in catalog.entities:
            grouped.setdefault(entity.domain, []).append(entity)
        for domain, entities in grouped.items():
            exact: dict[str, Entity] = {}
            alias: dict[str, Entity] = {}
            initials: dict[str, Entity] = {}
            full_py: dict[str, Entity] = {}
            for entity in entities:
                for kind in ("name_zh", "short_name", "name_en"):
                    raw = entity.names.get(kind)
                    if raw:
                        key = fold(raw)
                        if key:
                            exact.setdefault(key, entity)
                for raw_alias in entity.aliases:
                    key = fold(raw_alias)
                    if key:
                        alias.setdefault(key, entity)
                if self.pinyin_available:
                    for raw in (entity.names.get("name_zh"), entity.names.get("short_name")):
                        if not raw:
                            continue
                        ini = pinyin.to_initials(raw)
                        if ini:
                            initials.setdefault(pinyin.norm_key(ini), entity)
                        full = pinyin.to_pinyin(raw)
                        if full:
                            full_py.setdefault(pinyin.norm_key(full), entity)
            sym = CharSymSpell(max_edit=self.max_edit)
            sym.build([k for k in (*exact.keys(), *alias.keys()) if len(k) <= 24])
            self._by_domain[domain] = entities
            self._exact[domain] = exact
            self._alias[domain] = alias
            self._initials[domain] = initials
            self._pinyin[domain] = full_py
            self._fuzzy[domain] = sym
        return self

    # ------------------------------------------------------------ 查询
    def search(self, query: str, domain: str | None = None, top_k: int = 10, max_dist: int | None = None) -> list[RecallCandidate]:
        key = fold(query)
        if not key:
            return []
        domains = [domain] if domain else list(self._by_domain.keys())
        # 去重键必须含 domain:source_id 仅按表内 UNIQUE,跨域同 id 的实体存在;
        # 裸 entity_id 去重会互相压掉对方(历史教训:四域全搜静默丢一域)。
        best: dict[tuple[str, str], RecallCandidate] = {}
        for dom in domains:
            for cand in self._search_domain(key, dom, max_dist):
                ckey = (cand.domain, cand.entity_id)
                prev = best.get(ckey)
                if prev is None or _better(cand, prev):
                    best[ckey] = cand
        ordered = sorted(best.values(), key=_sort_key)
        return ordered[:top_k]

    def _search_domain(self, key: str, domain: str, max_dist: int | None) -> Iterable[RecallCandidate]:
        exact = self._exact.get(domain, {})
        alias = self._alias.get(domain, {})
        entity = exact.get(key)
        if entity is not None:
            yield RecallCandidate(entity.entity_id, domain, entity.region, entity.names.get("name_zh", key), "exact", _LAYER_BASE_SCORE["exact"])
        entity = alias.get(key)
        if entity is not None:
            yield RecallCandidate(entity.entity_id, domain, entity.region, key, "alias", _LAYER_BASE_SCORE["alias"])
        ini = self._initials.get(domain, {})
        if ini:
            norm_ini = pinyin.norm_key(pinyin.to_initials(key) or "")
            entity = ini.get(norm_ini)
            if entity is not None:
                yield RecallCandidate(entity.entity_id, domain, entity.region, key, "initials", _LAYER_BASE_SCORE["initials"])
        full = self._pinyin.get(domain, {})
        if full:
            norm_full = pinyin.norm_key(pinyin.to_pinyin(key) or "")
            entity = full.get(norm_full)
            if entity is not None:
                yield RecallCandidate(entity.entity_id, domain, entity.region, key, "pinyin", _LAYER_BASE_SCORE["pinyin"])
        for term, dist in self._fuzzy.get(domain, CharSymSpell()).lookup(key, max_dist=max_dist):
            owner = exact.get(term) or alias.get(term)
            if owner is None:
                continue
            score = _LAYER_BASE_SCORE["fuzzy"] + 0.2 * (1.0 - dist / max(len(term), 1))
            yield RecallCandidate(owner.entity_id, domain, owner.region, term, "fuzzy", score, dist)

    # ------------------------------------------------------------ 报告
    def describe(self) -> dict:
        return {
            "domains": sorted(self._by_domain.keys()),
            "entities": {d: len(v) for d, v in self._by_domain.items()},
            "exact_keys": {d: len(v) for d, v in self._exact.items()},
            "alias_keys": {d: len(v) for d, v in self._alias.items()},
            "initials_keys": {d: len(v) for d, v in self._initials.items()},
            "pinyin_keys": {d: len(v) for d, v in self._pinyin.items()},
            "fuzzy_terms": {d: len(v) for d, v in self._fuzzy.items()},
            "pinyin_available": self.pinyin_available,
            "pinyin_reason": pinyin.unavailable_reason(),
            "max_edit": self.max_edit,
        }


def _better(cand: RecallCandidate, prev: RecallCandidate) -> bool:
    """替换判定须与 _sort_key 同序:同层同分时,词条/实体 id 更靠前者胜。

    历史教训:旧实现只比 (layer, score),同层同分候选保留「先见」者,而
    先见者按 (层级, 分数, 词条) 排序恰恰更靠后——保留的 matched_term 决定
    top_k 落位,文档宣称的确定性排序与实际不符。
    """
    key_c, key_p = _sort_key(cand), _sort_key(prev)
    if key_c != key_p:
        return key_c < key_p
    return False  # 完全同键(跨域同 id 同词条)保留先见者


def _sort_key(cand: RecallCandidate):
    return (_LAYER_PRIORITY[cand.layer], -cand.score, cand.matched_term, cand.entity_id)
