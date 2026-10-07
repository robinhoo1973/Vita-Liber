#!/usr/bin/env python3
"""目录 SQLite → 抽取语料构建器输入(data-dir 物化适配层)。

角色:build_extraction_corpus.py 是训练机正本(输入 = 本机抓取工作区的 data/*.jsonl)。
本适配层是 **CI 侧唯一的新焊点**——把 CNB Release 发布的目录 SQLite(加密包解密后)
物化成构建器逐字节期待的同一套输入文件,使"同一构建器 + 新数据源"成立,
构建器本体(C 面)零改。

数据读取纪律(与 entlink/catalog.py 的"投影三列"纪律分属两个消费者,互不放松):
- entlink 装载器只读 name/alias/match_status(实体链接消费);
- 本适配层读详情列(spec/dosage_form/usage_text/indications)与参考域列——
  抽取语料的**目标就是**这些字段,它们是 App 目录的可展示列,不是患者数据;
- 永不读 fetch_* 抓取元数据表(来源指纹/原始载荷)。

物化契约(逐文件对应构建器 load_* 的读取点):
  drugs_cn.jsonl        CN 非 NHSA 行:{name_zh, specification, dosage_form, usage_text}
  drugs_nhsa.jsonl      CN NHSA 行:{name_zh, region_specific:{spec, dosage_form}}
  tw_records.jsonl      TW 行:{name_zh, specification, dosage_form, usage_text, source_id}
  hk_records.jsonl      HK 行:{name_zh, name_en, specification, dosage_form, usage_text}
  medical_details.jsonl 全行:{source_id, indications, usage_text}(单遍流式消费者)
  medical_index.json    {index: {alias: [source_id]}}(别名↔同 id 组;抽样封顶)
  ref/hospital_<r>.jsonl {name_zh, depts:[{name_zh}]}(TW 科别派生用)
  ref/department_<r>.jsonl / ref/diagnosis_<r>.jsonl / ref/exam_<r>.jsonl {name_zh[, unit]}
  facts/<域>.jsonl       对话语料事实面:{region, name, ...可复述字段}(dialog builder 消费)
  training_feed_manifest.json 血缘(构建器随语料 manifest 收录)

用法:
  python3 scripts/distill/extract/catalog_source.py \
      --catalog-sqlite corpus-assets/catalog.sqlite --out-dir extract-data \
      [--source-json corpus-assets/source.json]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import sys
import time
from pathlib import Path

# medical_index:全量物化(2026-10-07 实测:别名文本大量与主名同形,去重后键数远小于行数;
# 采样会引入 source_id 序偏置,取消上限)。消费侧 load_aliases 自带上限(24000/8000)。
INDEX_MAX_ALIASES_PER_ROW = 6
USAGE_CAP = 160
INDICATIONS_CAP = 600


def _alias_texts(aliases_json: str | None) -> list[str]:
    """别名列双形态:v4 投影 = ["str"],v7 = [{"text": ..., "type": ...}]。均取文本。"""
    if not aliases_json:
        return []
    try:
        data = json.loads(aliases_json)
    except (ValueError, TypeError):
        return []
    out = []
    if isinstance(data, list):
        for item in data:
            if isinstance(item, str) and item.strip():
                out.append(item.strip())
            elif isinstance(item, dict):
                text = item.get("text")
                if isinstance(text, str) and text.strip():
                    out.append(text.strip())
    return out


def _rs_spec_form(row) -> tuple[str, str]:
    """region_specific_json 里的 spec/dosage_form(CN 医保行常无;缺则回退主列)。"""
    spec = (row["spec"] or "").strip()
    form = (row["dosage_form"] or "").strip()
    raw = row["region_specific_json"]
    if raw and (not spec or not form):
        try:
            data = json.loads(raw)
            if isinstance(data, dict):
                spec = spec or str(data.get("spec") or "").strip()
                form = form or str(data.get("dosage_form") or "").strip()
        except (ValueError, TypeError):
            pass
    return spec, form


def _write_jsonl(path: Path, rows):
    count = 0
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")
            count += 1
    return count


def materialize(sqlite_path: Path, out_dir: Path) -> dict:
    conn = sqlite3.connect(f"file:{sqlite_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        meta = dict(conn.execute("SELECT key, value FROM catalog_meta").fetchall())
        details = {row["source_id"]: row for row in
                   conn.execute("SELECT source_id, usage_text, indications FROM drug_detail")}

        def usage_of(sid: str) -> str:
            row = details.get(sid)
            return (row["usage_text"] or "")[:USAGE_CAP] if row else ""

        counts: dict[str, int] = {}
        cn_rows, nhsa_rows, tw_rows, hk_rows = [], [], [], []
        for row in conn.execute(
                "SELECT region, source_id, name_zh, name_en, dosage_form, spec, region_specific_json "
                "FROM drug"):
            spec, form = _rs_spec_form(row)
            sid = row["source_id"]
            name = (row["name_zh"] or "").strip()
            if row["region"] == "CN":
                if sid.startswith("CN-NHSA-"):
                    nhsa_rows.append({"name_zh": name, "region_specific": {"spec": spec, "dosage_form": form}})
                else:
                    cn_rows.append({"name_zh": name, "specification": spec, "dosage_form": form,
                                    "usage_text": usage_of(sid)})
            elif row["region"] == "TW":
                tw_rows.append({"name_zh": name, "specification": spec, "dosage_form": form,
                                "usage_text": usage_of(sid), "source_id": sid})
            elif row["region"] == "HK":
                hk_rows.append({"name_zh": name, "name_en": (row["name_en"] or "").strip(),
                                "specification": spec, "dosage_form": form, "usage_text": usage_of(sid)})

        counts["drugs_cn.jsonl"] = _write_jsonl(out_dir / "drugs_cn.jsonl", cn_rows)
        counts["drugs_nhsa.jsonl"] = _write_jsonl(out_dir / "drugs_nhsa.jsonl", nhsa_rows)
        counts["tw_records.jsonl"] = _write_jsonl(out_dir / "tw_records.jsonl", tw_rows)
        counts["hk_records.jsonl"] = _write_jsonl(out_dir / "hk_records.jsonl", hk_rows)

        def detail_rows():
            for row in conn.execute("SELECT source_id, usage_text, indications FROM drug_detail"):
                yield {"source_id": row["source_id"],
                       "usage_text": (row["usage_text"] or "")[:USAGE_CAP],
                       "indications": (row["indications"] or "")[:INDICATIONS_CAP]}
        counts["medical_details.jsonl"] = _write_jsonl(out_dir / "medical_details.jsonl", detail_rows())

        # medical_index:别名 → [source_id](抽样封顶;定序保证可复现)
        index: dict[str, list[str]] = {}
        sampled = 0
        for row in conn.execute(
                "SELECT source_id, name_zh, aliases_json FROM drug WHERE aliases_json IS NOT NULL "
                "AND aliases_json NOT IN ('', '[]') ORDER BY source_id"):
            sampled += 1
            sid = row["source_id"]
            texts = [t for t in _alias_texts(row["aliases_json"]) if 3 <= len(t) <= 26]
            name = (row["name_zh"] or "").strip()
            if 3 <= len(name) <= 26 and name not in texts:
                texts.insert(0, name)
            for text in texts[:INDEX_MAX_ALIASES_PER_ROW]:
                ids = index.setdefault(text, [])
                if sid not in ids:
                    ids.append(sid)
        index_path = out_dir / "medical_index.json"
        index_path.write_text(json.dumps({"index": index}, ensure_ascii=False) + "\n", encoding="utf-8")
        counts["medical_index.json"] = len(index)

        # 对话语料事实面(facts/):转述层的「资料」来源,逐字段逐字取自目录列。
        # 与 ref/ 分开:ref/ 服务抽取名称池(名称为主),facts/ 服务对话转述(带类型/等级/用法等可复述字段)。
        fact_specs = (
            ("drug",
             "SELECT d.region, d.name_zh, d.spec, d.dosage_form, t.usage_text "
             "FROM drug d LEFT JOIN drug_detail t ON t.source_id = d.source_id",
             (("name", "name_zh"), ("spec", "spec"), ("form", "dosage_form"), ("usage", "usage_text")), 160),
            ("hospital",
             "SELECT region, name_zh, type_zh, level_zh, admin_area FROM hospital",
             (("name", "name_zh"), ("type", "type_zh"), ("level", "level_zh"), ("area", "admin_area")), 60),
            ("department", "SELECT region, name_zh, category_zh FROM department",
             (("name", "name_zh"), ("category", "category_zh")), 60),
            ("diagnosis", "SELECT region, name_zh, chapter_zh FROM diagnosis",
             (("name", "name_zh"), ("chapter", "chapter_zh")), 60),
            ("exam", "SELECT region, name_zh, category, specimen, unit FROM exam_item",
             (("name", "name_zh"), ("category", "category"), ("specimen", "specimen"), ("unit", "unit")), 60),
        )
        for fact_type, sql, fields, cap in fact_specs:
            rows = []
            for row in conn.execute(sql):
                item = {"region": row["region"]}
                for field, col in fields:
                    value = (row[col] or "").strip()
                    if value:
                        item[field] = value[:cap]
                if item.get("name"):
                    rows.append(item)
            counts[f"facts/{fact_type}.jsonl"] = _write_jsonl(out_dir / "facts" / f"{fact_type}.jsonl", rows)

        # 参考域(按地区小写;构建器 load_ref_pool 的 cell.files 逐字对应)
        for table, rel_tpl, derive_depts in (("hospital", "ref/hospital_{r}.jsonl", True),
                                             ("department", "ref/department_{r}.jsonl", False),
                                             ("diagnosis", "ref/diagnosis_{r}.jsonl", False),
                                             ("exam_item", "ref/exam_{r}.jsonl", False)):
            for region in ("CN", "HK", "TW"):
                if table == "hospital":
                    rows = []
                    for row in conn.execute("SELECT name_zh, depts_json FROM hospital WHERE region=?", (region,)):
                        item = {"name_zh": (row["name_zh"] or "").strip()}
                        if derive_depts and row["depts_json"] and row["depts_json"] not in ("[]", ""):
                            try:
                                depts = json.loads(row["depts_json"])
                                names = [{"name_zh": (d.get("name_zh") or "").strip()}
                                         for d in depts if isinstance(d, dict) and (d.get("name_zh") or "").strip()]
                                if names:
                                    item["depts"] = names
                            except (ValueError, TypeError):
                                pass
                        rows.append(item)
                elif table == "exam_item":
                    rows = [{"name_zh": (row["name_zh"] or "").strip(), "name_en": (row["name_en"] or "").strip(),
                             "unit": (row["unit"] or "").strip()}
                            for row in conn.execute("SELECT name_zh, name_en, unit FROM exam_item WHERE region=?", (region,))]
                else:
                    rows = [{"name_zh": (row["name_zh"] or "").strip()}
                            for row in conn.execute(f"SELECT name_zh FROM {table} WHERE region=?", (region,))]
                rel = rel_tpl.format(r=region.lower())
                counts[rel] = _write_jsonl(out_dir / rel, rows)

        descriptor = {
            "catalog_data_version": meta.get("data_version", ""),
            "catalog_schema_version": meta.get("schema_version", ""),
            "index_sampled_rows": sampled,
            "counts": counts,
        }
        return descriptor
    finally:
        conn.close()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog-sqlite", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--source-json", type=Path, default=None,
                        help="fetch_catalog.py 的 source.json(血缘随 training_feed_manifest 写入)")
    args = parser.parse_args()

    if not args.catalog_sqlite.exists():
        print(f"FAILED: 目录 SQLite 不存在: {args.catalog_sqlite}", file=sys.stderr)
        return 1
    args.out_dir.mkdir(parents=True, exist_ok=True)
    try:
        descriptor = materialize(args.catalog_sqlite, args.out_dir)
    except (sqlite3.Error, OSError, ValueError) as exc:
        print(f"FAILED: 物化失败: {exc}", file=sys.stderr)
        return 1

    source = {}
    if args.source_json is not None and args.source_json.exists():
        try:
            source = json.loads(args.source_json.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            source = {"error": f"unreadable {args.source_json}"}

    files = {}
    for rel in sorted(descriptor["counts"]):
        path = args.out_dir / rel
        if path.exists():
            files[rel] = {"lines": descriptor["counts"][rel], "sha256": sha256_file(path)}
    feed = {
        "stamp": time.strftime("%Y%m%d_%H%M%S", time.gmtime()),
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "mode": "cnb-catalog-materialized",
        "source": source,
        "catalog": descriptor,
        "files": files,
    }
    (args.out_dir / "training_feed_manifest.json").write_text(
        json.dumps(feed, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"out_dir": str(args.out_dir), "counts": descriptor["counts"],
                      "catalog_data_version": descriptor["catalog_data_version"]},
                     ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
