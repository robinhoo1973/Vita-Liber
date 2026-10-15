"""目录链接装载:明确 legacy physical4--7 和 unified physical9。

v9 从 catalog_entry 读取实际 entity_uid，不从 source_id 反猜图身份；
两种格式均只消费 name/alias/match_status，不读取用法/价格/展示字段。
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

from catalog_contract import (SUPPORTED_SCHEMAS, inspect_connection, readonly_connection,
                              sha256_file, validate_source_descriptor, validate_sqlite)

SUPPORTED_SCHEMA_VERSIONS = {str(v) for v in SUPPORTED_SCHEMAS}

DOMAINS = ("drug", "hospital", "department", "exam", "diagnosis")


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
    storage_identity: dict | None = None

    def by_domain(self, domain: str) -> list[Entity]:
        return [e for e in self.entities if e.domain == domain]

    def stats(self) -> dict[str, int]:
        out: dict[str, int] = {}
        for e in self.entities:
            out[e.domain] = out.get(e.domain, 0) + 1
        return out


def alias_texts(value: object) -> tuple[str, ...]:
    """Project alias text without restricting type or rewriting the source JSON."""
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            return ()
    if isinstance(value, (list, tuple)):
        out = []
        for item in value:
            if isinstance(item, str) and item.strip():
                out.append(item.strip())
            elif isinstance(item, dict):
                text = item.get("text")
                if isinstance(text, str) and text.strip():
                    out.append(text.strip())
        return tuple(out)
    return ()


def _alias_list(aliases_json: str | None) -> tuple[str, ...]:
    return alias_texts(aliases_json)


# ---------------------------------------------------------------- JSONL 适配器
def load_jsonl(path: Path, domain: str, data_version: str = "legacy-jsonl") -> Catalog:
    """从 JSONL(每行一个实体)装载单域目录。

    字段契约(兼容 repos/medical-data 与 .lab 实测件):
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
            aliases = alias_texts(row.get("aliases"))
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


def load_entities_dump(path: Path) -> Catalog:
    """build_corpus.py --dump-entities 的产物(JSONL 首行 _meta 携带 dataVersion)。

    eval 侧据此以**与语料同形**的实体模型重建索引(免二次下载目录资产;
    实体模型同形是 dataVersion 之外的第二一致性断言)。
    """
    header: dict | None = None
    entities: list[Entity] = []
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except ValueError as exc:
                raise ValueError(f"{path}:{lineno} 非法 JSON: {exc}") from exc
            if header is None:
                meta = record.get("_meta")
                if not isinstance(meta, dict):
                    raise ValueError(f"{path}:{lineno} 首行缺 _meta(build --dump-entities 产物才有)")
                header = meta
                continue
            entities.append(Entity(domain=str(record["domain"]), entity_id=str(record["entity_id"]),
                                   region=str(record.get("region") or ""), names=dict(record.get("names") or {}),
                                   aliases=alias_texts(record.get("aliases"))))
    if header is None:
        raise ValueError(f"entities dump 为空: {path}")
    if not entities:
        raise ValueError(f"entities dump 无实体: {path}")
    storage = header.get("storage_identity")
    if storage is not None and not isinstance(storage, dict):
        raise ValueError("entities dump storage_identity must be an object")
    if storage is not None and storage.get("dataVersion") != header.get("data_version"):
        raise ValueError("entities dump storage_identity dataVersion mismatch")
    return Catalog(entities, data_version=str(header.get("data_version") or ""), source=str(path),
                   storage_identity=storage)


# ---------------------------------------------------------------- v4 SQLite 适配器
_TABLE_BY_DOMAIN = {
    "drug": "drug",
    "hospital": "hospital",
    "department": "department",
    "exam": "exam_item",
    "diagnosis": "diagnosis",
}


def load_sqlite_v4(path: Path, data_version: str = "", group_by_name: bool = False,
                   source_descriptor: Path | None = None) -> Catalog:
    """从 App 目录投影 SQLite(加密包解密后)装载目录实体。

    读取 catalog_meta 校验 schema 版本与 data_version;只消费
    name/alias/match_status 三族字段,usage/价格/展示字段一律不读
    (抽取语料构建器是另一消费者,其读数纪律见 .github/actions/distill/extract/catalog_source.py)。

    group_by_name=True:把同域同 name_zh 的**多行**合并为一个实体(别名并集)。
    生产目录的药品行按许可编号逐行物化(NHSA 273k 行 ≈ 40k 唯一名),逐行建实体
    会让「同名不同 id」全部落进冲突池——实体链接的金标被行级重复污染。
    合并 id = 组内 source_id 最小者(定序,可复现);评测侧必须用同一开关
    (build/eval 实体模型同形是 dataVersion 之外的第二个一致性断言)。
    """
    if not path.exists():
        raise FileNotFoundError(f"v4 SQLite 不存在: {path}")
    identity = validate_sqlite(path, data_version=data_version or None)
    file_sha256 = sha256_file(path)
    conn = readonly_connection(path)
    try:
        conn.execute("BEGIN")
        if inspect_connection(conn, data_version=data_version or None) != identity:
            raise ValueError("catalog identity changed while opening the entity snapshot")
        data_version = identity.data_version
        descriptor = None
        if source_descriptor is not None:
            descriptor = json.loads(source_descriptor.read_text(encoding="utf-8"))
            validate_source_descriptor(identity, descriptor, file_sha256)
        rows_all: list[tuple[str, dict]] = []
        # 投影逐表列差异(与 catalog_v4.sql 逐字对齐;v5–v7 该投影同形):
        #   drug: name_en;hospital: short_name;exam: name_en;department/diagnosis: 仅 name_zh
        #   match_status 仅 drug_reference/hospital/department/exam_item/diagnosis 携带
        _EXTRA_BY_DOMAIN = {"drug": ("name_en",), "hospital": ("short_name",), "exam": ("name_en",)}
        for domain, table in _TABLE_BY_DOMAIN.items():
            cols = {"name_zh", "aliases_json", "region", "source_id"}
            cols |= set(_EXTRA_BY_DOMAIN.get(domain, ()))
            if domain != "drug":
                cols.add("match_status")
            try:
                projection = ", ".join(f"d.{c}" for c in sorted(cols))
                if identity.schema == 9:
                    cur = conn.execute(
                        f"SELECT {projection}, c.entity_uid AS entity_id FROM {table} d "
                        "JOIN catalog_entry c ON c.table_name=? AND c.active=1 AND c.app_row_id=d.rowid "
                        "AND c.region=d.region AND c.source_id=d.source_id", (table,))
                else:
                    cur = conn.execute(f"SELECT {projection}, d.source_id AS entity_id FROM {table} d")
            except sqlite3.OperationalError as exc:
                # diagnosis 域自 v7 起物化:v4–v6 投影无此表 = 该域零实体(不拒载,
                # 历史资产仍可重放);v7 缺表 = 投影漂移,fail-closed(与其余表同)。
                if domain == "diagnosis" and identity.schema in (4, 5, 6):
                    continue
                raise ValueError(f"v4 投影缺表 {table}: {exc}") from exc
            colnames = [d[0] for d in cur.description]
            for row in cur.fetchall():
                rows_all.append((domain, dict(zip(colnames, row))))

        def _entity_from(domain: str, record: dict) -> Entity | None:
            names = {}
            for key in ("name_zh", "name_en", "short_name"):
                value = record.get(key)
                if isinstance(value, str) and value.strip():
                    names[key] = value.strip()
            if not names:
                return None
            return Entity(
                domain=domain,
                entity_id=str(record["entity_id"]),
                region=str(record.get("region") or ""),
                names=names,
                aliases=_alias_list(record.get("aliases_json")),
                match_status=record.get("match_status"),
            )

        entities: list[Entity] = []
        # Same spelling is not an identity merge in a graph. Explicit entry
        # bindings always win over this legacy/dev name-grouping switch.
        if not group_by_name or identity.schema == 9:
            for domain, record in rows_all:
                entity = _entity_from(domain, record)
                if entity is not None:
                    entities.append(entity)
        else:
            # (domain, name_zh) → 合并记录。别名并集保序去重;name_en/short_name 取
            # 排序后首个非空(与 id 选择同序,可复现)。折叠合并(全半角等)不做——
            # 折叠差异交给召回层噪声模型,目录层保持逐字可解释。
            groups: dict[tuple[str, str, str], dict] = {}
            for domain, record in rows_all:
                name = (record.get("name_zh") or "").strip()
                if not name:
                    continue
                key = (domain, str(record.get("region") or ""), name)
                sid = str(record["source_id"])
                group = groups.get(key)
                if group is None:
                    groups[key] = {"sid": sid, "record": record, "aliases": list(_alias_list(record.get("aliases_json")))}
                    continue
                if sid < group["sid"]:
                    group["sid"] = sid
                    # 主记录随最小 id(其 name_en/short_name/match_status 优先)
                    old = group["record"]
                    record = {**old, **{k: v for k, v in record.items() if v not in (None, "")}}
                    group["record"] = record
                for alias in _alias_list(record.get("aliases_json")):
                    if alias not in group["aliases"]:
                        group["aliases"].append(alias)
            for (domain, _, name), group in sorted(groups.items()):
                record = dict(group["record"])
                record["name_zh"] = name
                record["source_id"] = group["sid"]
                record["entity_id"] = group["sid"]
                entity = _entity_from(domain, record)
                if entity is None:
                    continue
                entities.append(Entity(
                    domain=entity.domain, entity_id=entity.entity_id, region=entity.region,
                    names=entity.names, aliases=tuple(group["aliases"]), match_status=entity.match_status,
                ))
        storage = {**identity.descriptor(), "sqliteSha256": file_sha256}
        if descriptor is not None and "signedPointerDigest" in descriptor:
            storage["signedPointerDigest"] = descriptor["signedPointerDigest"]
        return Catalog(entities, data_version=data_version, source=str(path),
                       license_hint="见 manifest license 字段", storage_identity=storage)
    finally:
        conn.close()
