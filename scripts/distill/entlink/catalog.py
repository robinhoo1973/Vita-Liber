"""四域目录装载:JSONL 适配器(legacy/dev)与 v4 SQLite 适配器(Phase B 后 Release 资产)。

Release 资产的物理 schema 由私仓 Go producer 管理:当前发布 v5/v6
(physical user_version/schema_version;App 侧安装器契约「只接受物理 v5/v6,
v7+ 拒绝」见私仓 MEDICAL_DATA_RELEASE.md)。本装载器只消费 App 可见投影列
(name/alias/match_status 三族),物理 v4/v5/v6 该投影同形(promote 对投影列做
逐列校验),故 schema 闸接受 4/5/6、拒 7+。**用法/价格/展示字段一律不读**
(usage_ref_json 等在物理库中仍物化存在,读取纪律在列选择层而非投影层)。
装载结果统一为 Catalog/Entity 纯数据形态,recall 与语料构建器只依赖本形态。

许可纪律:调用方(语料构建器)必须把 manifest 的 license 字段随来源登记
(TFDAO OGDL v1 顯名等,见 lexicon-data-sources.md §2)——本模块只搬运数据,不背书许可。
"""
from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

# 投影兼容的物理 schema 版本(App 侧安装器同口径:物理 v5/v6,v7+ 拒);
# 不匹配即拒载(fail-closed,防格式漂移静默错配)。历史教训:只收 "4" 时,
# 生产 Release 资产已是 v6——闸门会拒绝唯一的真实资产。
SUPPORTED_SCHEMA_VERSIONS = {"4", "5", "6"}

DOMAINS = ("drug", "hospital", "department", "exam")


def parse_catalog_jsonl(spec: str) -> dict[str, Path]:
    """解析 CLI 的 --catalog-jsonl `domain=path,...` 规格(供各 CLI 共用,
    杜绝 build_corpus/eval_entlink 各写一份解析的漂移)。
    抛 ValueError——argparse 对 type= 函数同样渲染为干净错误。
    """
    out: dict[str, Path] = {}
    for pair in spec.split(","):
        if "=" not in pair:
            raise ValueError(f"--catalog-jsonl 条目须为 domain=path: {pair}")
        domain, path = pair.split("=", 1)
        if domain not in DOMAINS:
            raise ValueError(f"未知域: {domain}")
        out[domain] = Path(path)
    return out


@dataclass(frozen=True)
class Entity:
    """目录实体:四域统一形态。names 以 kind 区分(priority 层优先序)。"""

    domain: str
    entity_id: str
    region: str
    names: dict[str, str] = field(default_factory=dict)  # kind -> 原始文本
    aliases: tuple[str, ...] = ()
    match_status: str | None = None  # exact/candidate/conflict/unmatched


@dataclass
class Catalog:
    """四域目录快照。meta 携带数据版本与来源,供 manifest 回写。"""

    entities: list[Entity]
    data_version: str = ""
    source: str = ""
    license_hint: str = ""
    pinyin_available: bool = False

    def by_domain(self, domain: str) -> list[Entity]:
        return [e for e in self.entities if e.domain == domain]

    def stats(self) -> dict[str, int]:
        out: dict[str, int] = {}
        for e in self.entities:
            out[e.domain] = out.get(e.domain, 0) + 1
        return out


def _alias_list(aliases_json: str | None) -> tuple[str, ...]:
    if not aliases_json:
        return ()
    try:
        data = json.loads(aliases_json)
    except (ValueError, TypeError):
        return ()
    if isinstance(data, list):
        return tuple(str(x) for x in data if isinstance(x, str) and x.strip())
    return ()


# ---------------------------------------------------------------- JSONL 适配器
def load_jsonl(path: Path, domain: str, data_version: str = "legacy-jsonl") -> Catalog:
    """从 JSONL(每行一个实体)装载单域目录。

    字段契约(兼容 refactor/tools/medical-data 与 .lab 实测件):
      drug:       name_zh/name_en/aliases(数组或串)/region/source_id
      hospital:   name_zh/short_name/aliases/region/source_id
      department: name_zh/aliases/region/source_id
      exam:       name_zh/name_en/aliases/region/source_id
    """
    if domain not in DOMAINS:
        raise ValueError(f"unknown domain: {domain}")
    entities: list[Entity] = []
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError as exc:
                raise ValueError(f"{path}:{lineno} 非法 JSON: {exc}") from exc
            names: dict[str, str] = {}
            for key in ("name_zh", "name_en", "short_name"):
                value = row.get(key)
                if isinstance(value, str) and value.strip():
                    names[key] = value.strip()
            aliases = tuple(row.get("aliases", ()) or ()) if isinstance(row.get("aliases"), (list, tuple)) else _alias_list(str(row.get("aliases", "") or ""))
            entity_id = str(row.get("source_id") or row.get("id") or f"{domain}-{lineno}")
            region = str(row.get("region") or "")
            if not names:
                raise ValueError(f"{path}:{lineno} 无名称字段(name_zh/name_en/short_name)")
            entities.append(Entity(domain, entity_id, region, names, tuple(aliases)))
    return Catalog(entities, data_version=data_version, source=str(path), license_hint="见 lexicon-data-sources.md §2")


def load_jsonl_set(path_by_domain: dict[str, Path], data_version: str = "legacy-jsonl") -> Catalog:
    """按域装载多个 JSONL 并合并为四域 Catalog(域文件缺省=该域零实体)。"""
    merged: list[Entity] = []
    for domain in DOMAINS:
        path = path_by_domain.get(domain)
        if path is None:
            continue
        merged.extend(load_jsonl(path, domain, data_version=data_version).entities)
    return Catalog(merged, data_version=data_version, source=",".join(str(p) for p in path_by_domain.values()))


# ---------------------------------------------------------------- v4 SQLite 适配器
_TABLE_BY_DOMAIN = {
    "drug": "drug",
    "hospital": "hospital",
    "department": "department",
    "exam": "exam_item",
}


def load_sqlite_v4(path: Path, data_version: str = "") -> Catalog:
    """从 App v4 投影 SQLite(加密包解密后)装载四域目录。

    读取 catalog_meta 校验 schema 版本与 data_version;只消费
    name/alias/match_status 三族字段,usage/价格/展示字段一律不读。
    """
    if not path.exists():
        raise FileNotFoundError(f"v4 SQLite 不存在: {path}")
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        meta = dict(conn.execute("SELECT key, value FROM catalog_meta").fetchall())
        schema_version = meta.get("schema_version", "4")
        if schema_version not in SUPPORTED_SCHEMA_VERSIONS:
            raise ValueError(f"不支持的 schema_version={schema_version}(支持: {sorted(SUPPORTED_SCHEMA_VERSIONS)})")
        data_version = data_version or meta.get("data_version", "")
        entities: list[Entity] = []
        # v4 投影逐表列差异(与 catalog_v4.sql 逐字对齐):
        #   drug: name_en;hospital: short_name;exam: name_en;department: 仅 name_zh
        #   match_status 仅 drug_reference/hospital/department/exam_item 携带
        _EXTRA_BY_DOMAIN = {"drug": ("name_en",), "hospital": ("short_name",), "exam": ("name_en",)}
        for domain, table in _TABLE_BY_DOMAIN.items():
            cols = {"name_zh", "aliases_json", "region", "source_id"}
            cols |= set(_EXTRA_BY_DOMAIN.get(domain, ()))
            if domain != "drug":
                cols.add("match_status")
            try:
                cur = conn.execute(f"SELECT {', '.join(sorted(cols))} FROM {table}")
            except sqlite3.OperationalError as exc:
                raise ValueError(f"v4 投影缺表 {table}: {exc}") from exc
            colnames = [d[0] for d in cur.description]
            for row in cur.fetchall():
                record = dict(zip(colnames, row))
                names = {}
                for key in ("name_zh", "name_en", "short_name"):
                    value = record.get(key)
                    if isinstance(value, str) and value.strip():
                        names[key] = value.strip()
                entity = Entity(
                    domain=domain,
                    entity_id=str(record["source_id"]),
                    region=str(record.get("region") or ""),
                    names=names,
                    aliases=_alias_list(record.get("aliases_json")),
                    match_status=record.get("match_status"),
                )
                entities.append(entity)
        return Catalog(entities, data_version=data_version, source=str(path), license_hint="见 manifest license 字段")
    finally:
        conn.close()
