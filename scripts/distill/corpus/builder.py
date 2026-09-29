"""语料构建核心(纯 stdlib,可测):目录 → 正对/硬负例/噪声增广 → 冻结 JSONL+manifest。

纪律(计划文档 §7.6/§10 + 数据席四轮评审):
- 质量过滤:公司名后缀假别名(有限公司/Limited/集團,实测 211 条)剔除;
  别名折叠后与他实体名碰撞者只入 conflict 池;zh 别名 <2 字剔除。
- 金标碰撞守卫:加噪后 query 折叠若命中**他实体**的别名/名 → 重掷(次数上限),
  仍碰撞则丢弃样本——评测集不得存在歧义金标。
- 切分:按 canonical 实体哈希(train/eval),同实体的全部别名同落一侧(防泄漏)。
- 硬负例:conflict 行(同别名多 canonical)+ 确定性采样同域他实体。
- 逐样本种子 = hash(master_seed, sample_id):与样本顺序无关、可复现。
- 动态混淆挖掘默认开启(confusion_miner),有效噪声模型整体进 manifest。
"""
from __future__ import annotations

import hashlib
import json
import random
from dataclasses import dataclass, field
from pathlib import Path

from entlink import pinyin
from entlink.catalog import Catalog, Entity
from entlink.confusion_miner import MinedConfusions, mine as mine_confusions
from entlink.fold import fold
from entlink.noise import NoiseSimulator

from .manifest import build_manifest, write_manifest

BANDS = ("light", "medium", "heavy", "extreme")

# 公司名后缀假别名过滤(数据席实测 211 条;括号变体剥离后常露出公司主体名)
_COMPANY_SUFFIXES = ("有限公司", "股份有限公司", "集團", "集团", "Limited", "Ltd", "Corporation", "Inc")

SPLIT_RULE_VERSION = "1.0"


@dataclass
class BuildConfig:
    master_seed: int = 20260929
    split_ratio: float = 0.85          # 实体级 train 占比
    bands: tuple[str, ...] = BANDS
    negatives_per_sample: int = 4
    min_alias_chars: int = 2           # zh 别名最小长度(过滤单字噪声)
    min_eval_entities: int = 200       # 每带×域评测实体下限(计划文档 §10)
    re_roll_attempts: int = 4          # 金标碰撞重掷上限
    mine_confusions: bool = True
    variant_min_count: int = 2
    homophone_min_count: int = 2


@dataclass
class BuildReport:
    manifest: dict = field(default_factory=dict)
    dropped_collision: int = 0
    dropped_empty: int = 0
    alias_filtered: dict = field(default_factory=dict)


def _split_key(entity_id: str, master_seed: int) -> int:
    return int(hashlib.sha256(f"{master_seed}:{entity_id}".encode()).hexdigest()[:8], 16)


def _is_train(entity_id: str, master_seed: int, ratio: float) -> bool:
    return _split_key(entity_id, master_seed) < int(ratio * 0xFFFFFFFF)


def _sample_seed(master_seed: int, sample_id: str) -> int:
    return int(hashlib.sha256(f"{master_seed}:{sample_id}".encode()).hexdigest()[:8], 16)


def _clean_alias(alias: str, min_chars: int = 2) -> str | None:
    """别名质量过滤:空/短(折叠后 < min_chars)/公司名后缀假别名 → None。

    min_chars 来自 BuildConfig.min_alias_chars(写入 manifest split_rule);
    历史教训:该配置项曾被硬编码 2 架空——调配置不生效且 manifest 谎报。
    """
    text = alias.strip()
    if len(fold(text)) < min_chars:
        return None
    if any(text.endswith(suffix) for suffix in _COMPANY_SUFFIXES):
        return None
    return text


def _query_terms(entity: Entity, min_alias_chars: int = 2) -> list[tuple[str, str]]:
    """(term, kind) 查询源:别名 + 简称 + 英文名;主名不做查询源(金标)。"""
    out = []
    name_key = fold(entity.names.get("name_zh", ""))
    for alias in entity.aliases:
        cleaned = _clean_alias(alias, min_alias_chars)
        if cleaned and fold(cleaned) != name_key:
            out.append((cleaned, "alias"))
    short = entity.names.get("short_name")
    if short and fold(short) != name_key:
        out.append((short, "short_name"))
    en = entity.names.get("name_en")
    if en and fold(en) != name_key:
        out.append((en, "name_en"))
    return out


def _owner_map(catalog: Catalog, min_alias_chars: int = 2) -> dict[str, set[str]]:
    """folded 名(含简称/英文名)/别名 → 拥有该键的实体集合(冲突检测)。

    名称三字段(name_zh/short_name/name_en)必须全部登记——recall 索引同样覆盖
    三字段,守卫漏掉任一字段就会放行跨实体同名歧义(历史教训:英文名同名
    歧义金标曾漏过守卫,评测集存在不唯一金标)。
    """
    owners: dict[str, set[str]] = {}
    for entity in catalog.entities:
        keys = {fold(v) for k, v in entity.names.items() if v}
        keys |= {fold(a) for a in entity.aliases if _clean_alias(a, min_alias_chars)}
        keys.discard("")
        for key in keys:
            owners.setdefault(key, set()).add(entity.entity_id)
    return owners


def _conflict_entities(catalog: Catalog, owners: dict[str, set[str]]) -> dict[str, set[str]]:
    """同别名多 canonical → conflict 池(硬负例来源,数据席 281 条实测)。

    先建一次 实体 → 折叠键集 倒排(O(E) 次 fold),再按多属主键聚合——
    禁止对每个多属主键重扫全目录(旧实现 O(K×E):生产目录 40k+ 实体下
    每千个共享键耗时分钟级,fold 还被重复计算)。
    """
    entity_keys: dict[str, set[str]] = {}
    for entity in catalog.entities:
        keys = {fold(entity.names.get("name_zh", ""))}
        keys |= {fold(a) for a in entity.aliases}
        keys.discard("")
        entity_keys[entity.entity_id] = keys
    by_id = {e.entity_id: e for e in catalog.entities}
    by_domain: dict[str, set[str]] = {}
    for key, ids in owners.items():
        if len(ids) < 2:
            continue
        for eid in ids:
            entity = by_id.get(eid)
            if entity is not None and key in entity_keys.get(eid, ()):
                by_domain.setdefault(entity.domain, set()).add(eid)
    return by_domain


def build_corpus(catalog: Catalog, out_path: Path, config: BuildConfig | None = None) -> BuildReport:
    config = config or BuildConfig()
    report = BuildReport()
    mined: MinedConfusions | None = None
    mined_var: dict[str, str] = {}
    mined_homo: dict[str, tuple[str, ...]] = {}
    if config.mine_confusions:
        mined = mine_confusions(catalog)
        mined_var = mined.trimmed_variants(min_count=config.variant_min_count)
        mined_homo = mined.trimmed_homophones(min_count=config.homophone_min_count)
        report.alias_filtered["mined_variant_pairs"] = len(mined_var)
        report.alias_filtered["mined_homophone_pools"] = len(mined_homo)
    simulator = NoiseSimulator(seed=config.master_seed, mined_variants=mined_var, mined_homophones=mined_homo)

    owners = _owner_map(catalog, config.min_alias_chars)
    conflict = _conflict_entities(catalog, owners)
    by_domain: dict[str, list[Entity]] = {}
    for entity in catalog.entities:
        by_domain.setdefault(entity.domain, []).append(entity)

    # 评测实体下限断言(逐带×域;不达标即 fail-closed,防评测集空转假绿)
    for domain, entities in sorted(by_domain.items()):
        eval_count = sum(1 for e in entities if not _is_train(e.entity_id, config.master_seed, config.split_ratio))
        if eval_count < config.min_eval_entities:
            raise ValueError(
                f"评测实体数不足: {domain} 仅 {eval_count} 个评测实体(下限 {config.min_eval_entities})——"
                f"调大目录或调低 --min-eval-entities,禁止在不足集上跑闸门"
            )

    counts: dict[str, int] = {}
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        for domain, entities in sorted(by_domain.items()):
            others = [e.entity_id for e in entities]
            conflict_ids = conflict.get(domain, set())
            for entity in entities:
                terms = _query_terms(entity, config.min_alias_chars)
                if not terms:
                    continue
                is_train = _is_train(entity.entity_id, config.master_seed, config.split_ratio)
                for band in config.bands:
                    for term, kind in terms:
                        sample_id = f"{domain}:{entity.entity_id}:{band}:{term}"
                        query, applied = _noise_with_guard(
                            simulator, term, band, _sample_seed(config.master_seed, sample_id),
                            owners, entity.entity_id, config.re_roll_attempts, report,
                        )
                        if query is None:
                            continue
                        negatives = []
                        for nid in _deterministic_negatives(others, entity.entity_id, _sample_seed(config.master_seed, sample_id + ":neg"), config.negatives_per_sample):
                            negatives.append({"entity_id": nid, "hard": "conflict" if nid in conflict_ids else "sampled"})
                        line = {
                            "id": f"{domain}-{entity.entity_id}-{band}-{fold(term)[:12]}-{_sample_seed(config.master_seed, sample_id) % 1000000:06d}",
                            "domain": domain,
                            "band": band,
                            "split": "train" if is_train else "eval",
                            "query": query,
                            "gold": {"entity_id": entity.entity_id, "term": term, "kind": kind},
                            "negatives": negatives,
                            "seed": _sample_seed(config.master_seed, sample_id),
                        }
                        fh.write(json.dumps(line, ensure_ascii=False) + "\n")
                        key = f"{domain}:{band}:{'train' if is_train else 'eval'}"
                        counts[key] = counts.get(key, 0) + 1

    noise_model = simulator.effective_tables()
    noise_model["noise_model_sha256"] = hashlib.sha256(
        json.dumps(noise_model, ensure_ascii=False, sort_keys=True).encode("utf-8")
    ).hexdigest()
    licenses = {
        "TFDA": {"attribution": "藥品許可證資料集(OGDL v1 顯名聲明,三語)", "covers": ["TW"]},
        "NHSA": {"note": "医保药品目录批次数据;频控纪律见 lexicon-data-sources.md §2", "covers": ["CN"]},
        "HK": {"note": "data.gov.hk / HA 公開數據", "covers": ["HK"]},
    }
    manifest = build_manifest(
        corpus_path=out_path,
        catalog_data_version=catalog.data_version,
        catalog_source=catalog.source,
        noise_model=noise_model,
        pinyin_available=pinyin.available(),
        pinyin_reason=pinyin.unavailable_reason(),
        split_rule={"version": SPLIT_RULE_VERSION, "master_seed": config.master_seed,
                    "split_ratio": config.split_ratio, "min_alias_chars": config.min_alias_chars},
        licenses=licenses,
        counts=counts,
    )
    write_manifest(out_path.with_suffix(out_path.suffix + ".manifest.json"), manifest)
    report.manifest = manifest
    return report


def _noise_with_guard(simulator: NoiseSimulator, term: str, band: str, seed: int,
                      owners: dict[str, set[str]], gold_id: str,
                      attempts: int, report: BuildReport) -> tuple[str | None, bool]:
    """加噪 + 金标碰撞守卫:噪声后折叠键只允许归金标所有(或无主)。"""
    for attempt in range(attempts):
        rng = random.Random(seed + attempt)
        query, _ = simulator.apply(term, band, rng=rng)
        key = fold(query)
        if not key:
            report.dropped_empty += 1
            continue
        holders = owners.get(key, set())
        if holders and holders != {gold_id}:
            continue  # 撞了他实体 → 重掷
        return query, True
    report.dropped_collision += 1
    return None, False


def _deterministic_negatives(all_ids: list[str], gold_id: str, seed: int, k: int) -> list[str]:
    rng = random.Random(seed)
    pool = [i for i in all_ids if i != gold_id]
    if len(pool) <= k:
        return pool
    return rng.sample(pool, k)
