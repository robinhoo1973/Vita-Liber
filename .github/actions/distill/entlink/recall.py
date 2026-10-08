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
    """确定性召回。build() 之后 search() 线程安全(只读索引)。

    E1 参数化(2026-10-08 round5 红队实证;默认=修复态,可通过参数回退旧行为):
    - fuzzy_max_len: fuzzy 索引键长上限。None=不设限(修复:旧实现 >24 字符长名
      被排除在 fuzzy 索引外,长药名/检查项名被 1 次编辑扰动后 exact/别名/拼音
      三层全失效、fuzzy 层又无索引 → 零候选;drug light 拒识 11.4% 全属此类);
      传 24 即精确回退旧行为(回归对拍用)。
    - layer_multi_owner: initials/pinyin 层是否收录同键全部属主。False=只保留
     首位(旧行为:56,573 家医院只有 43,309 个首字母键,碰撞键静默丢实体);
      True=全收录、同层同分、按 (词条,实体 id) 确定性排序(实验开关,配负测)。
    - layer_order: 层优先级可重排(默认 LAYER_ORDER);须为五层全集的排列。
      说明:红队反事实证明单点重排是零和(hospital medium +3.8pt ↔ diagnosis
      light −26.4pt),故仅作实验参数暴露,默认不变。
    """

    def __init__(self, max_edit: int = 2, *, fuzzy_max_len: int | None = None,
                 layer_multi_owner: bool = False, layer_order: tuple = LAYER_ORDER):
        if set(layer_order) != set(LAYER_ORDER) or len(layer_order) != len(LAYER_ORDER):
            raise ValueError(f"layer_order 须为 {LAYER_ORDER} 的排列,得到 {layer_order}")
        self.max_edit = max_edit
        self.fuzzy_max_len = fuzzy_max_len
        self.layer_multi_owner = layer_multi_owner
        self._layer_priority = {name: i for i, name in enumerate(layer_order)}
        self._by_domain: dict[str, list[Entity]] = {}
        self._exact: dict[str, dict[str, Entity]] = {}       # domain -> folded name -> entity
        self._alias: dict[str, dict[str, Entity]] = {}       # domain -> folded alias -> entity
        self._initials: dict[str, dict[str, list[Entity]]] = {}  # domain -> norm(initials) -> owners
        self._pinyin: dict[str, dict[str, list[Entity]]] = {}    # domain -> norm(pinyin) -> owners
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
            initials: dict[str, list[Entity]] = {}
            full_py: dict[str, list[Entity]] = {}

            def _add_owner(table: dict[str, list[Entity]], key: str, entity: Entity) -> None:
                owners = table.get(key)
                if owners is None:
                    table[key] = [entity]
                elif self.layer_multi_owner and entity not in owners:
                    owners.append(entity)
                # layer_multi_owner=False 时保留首位(旧行为)

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
                            _add_owner(initials, pinyin.norm_key(ini), entity)
                        full = pinyin.to_pinyin(raw)
                        if full:
                            _add_owner(full_py, pinyin.norm_key(full), entity)
            sym = CharSymSpell(max_edit=self.max_edit)
            sym.build([k for k in (*exact.keys(), *alias.keys())
                       if self.fuzzy_max_len is None or len(k) <= self.fuzzy_max_len])
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
                if prev is None or _better(cand, prev, self._layer_priority):
                    best[ckey] = cand
        ordered = sorted(best.values(), key=lambda c: _sort_key(c, self._layer_priority))
        return ordered[:top_k]

    def near_ties(self, query: str, domain: str | None = None, top_k: int = 10) -> list[RecallCandidate]:
        """对称歧义指示:与 rank1 同层同分的其余候选(确定性)。

        红队实证:light/medium 带多实体落入同一容差球时,rank1 由层优先与字典序
        决定——层序调参是零和,正确产品出口=候选列表+用户确认(clarify)。本方法
        给运行时提供"该问用户"的机器信号,不改 rank1 决策。
        """
        hits = self.search(query, domain=domain, top_k=top_k)
        if len(hits) < 2:
            return []
        rank1 = hits[0]
        return [c for c in hits[1:]
                if c.layer == rank1.layer and c.score == rank1.score]

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
            for owner in ini.get(norm_ini, ()):
                yield RecallCandidate(owner.entity_id, domain, owner.region, key, "initials", _LAYER_BASE_SCORE["initials"])
        full = self._pinyin.get(domain, {})
        if full:
            norm_full = pinyin.norm_key(pinyin.to_pinyin(key) or "")
            for owner in full.get(norm_full, ()):
                yield RecallCandidate(owner.entity_id, domain, owner.region, key, "pinyin", _LAYER_BASE_SCORE["pinyin"])
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
            "fuzzy_max_len": self.fuzzy_max_len,
            "layer_multi_owner": self.layer_multi_owner,
            "layer_order": [name for name, _ in sorted(self._layer_priority.items(), key=lambda kv: kv[1])],
        }


def _better(cand: RecallCandidate, prev: RecallCandidate, priority: dict) -> bool:
    """替换判定须与 _sort_key 同序:同层同分时,词条/实体 id 更靠前者胜。

    历史教训:旧实现只比 (layer, score),同层同分候选保留「先见」者,而
    先见者按 (层级, 分数, 词条) 排序恰恰更靠后——保留的 matched_term 决定
    top_k 落位,文档宣称的确定性排序与实际不符。
    """
    key_c, key_p = _sort_key(cand, priority), _sort_key(prev, priority)
    if key_c != key_p:
        return key_c < key_p
    return False  # 完全同键(跨域同 id 同词条)保留先见者


def _sort_key(cand: RecallCandidate, priority: dict):
    return (priority[cand.layer], -cand.score, cand.matched_term, cand.entity_id)
