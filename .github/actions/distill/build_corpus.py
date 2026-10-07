#!/usr/bin/env python3
"""语料构建 CLI:目录资产 → 冻结 JSONL + manifest(计划文档 §7.6 prepare 段)。

用法:
  python3 .github/actions/distill/build_corpus.py \
      --catalog-jsonl drug=a.jsonl,hospital=b.jsonl,department=c.jsonl,exam=d.jsonl \
      --out out/corpus.jsonl --master-seed 20260929
  python3 .github/actions/distill/build_corpus.py --catalog-sqlite catalog.sqlite --out out/corpus.jsonl

退出码:0=成功;1=输入/环境错误;2=评测实体下限不达标(fail-closed)。
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from corpus.builder import BANDS, BuildConfig, build_corpus  # noqa: E402
from entlink.catalog import DOMAINS, load_jsonl_set, load_sqlite_v4, parse_catalog_jsonl  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog-jsonl", type=parse_catalog_jsonl, default=None)
    parser.add_argument("--catalog-sqlite", type=Path, default=None)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--master-seed", type=int, default=20260929)
    parser.add_argument("--split-ratio", type=float, default=0.85)
    parser.add_argument("--bands", default=",".join(BANDS))
    parser.add_argument("--negatives", type=int, default=4)
    parser.add_argument("--min-eval-entities", type=int, default=200)
    parser.add_argument("--no-mine", action="store_true", help="关闭目录混淆挖掘(仅种子表)")
    parser.add_argument("--group-by-name", action="store_true",
                        help="同域同名行合并为单实体(生产目录行级重复去污;评测侧须同开)")
    parser.add_argument("--max-terms-per-entity", type=int, default=0,
                        help="每实体最多取 N 个查询词条(0=不限)")
    parser.add_argument("--max-samples-per-domain", default="",
                        help="逐域样本上限 drug=200000,hospital=80000,…(确定性哈希抽样;空=不限)")
    parser.add_argument("--include-canonical-names", action="store_true",
                        help="规范名(噪声化)作查询源——真实 OCR/ASR 主场景;金标不变,实体级切分不变")
    parser.add_argument("--exclude-domains", default="",
                        help="从语料中排除的域(如 department——计划文档裁决:科室保持纯词表,不训模型)")
    parser.add_argument("--dump-entities", type=Path, default=None,
                        help="导出本次语料所用实体模型(JSONL 首行 _meta)——eval 侧以同形实体重建索引,"
                             "免二次下载 3.4GB 目录资产;实体模型同形 = 与 dataVersion 并列的第二一致性断言")
    args = parser.parse_args()

    if (args.catalog_jsonl is None) == (args.catalog_sqlite is None):
        parser.error("须且仅须提供 --catalog-jsonl 或 --catalog-sqlite 之一")
    if not 0 < args.split_ratio < 1:
        parser.error(f"--split-ratio 须在 (0, 1): {args.split_ratio}")
    bands = tuple(args.bands.split(","))
    for band in bands:
        if band not in BANDS:
            parser.error(f"未知噪声带: {band}(可选 {BANDS})")
    domain_caps: dict[str, int] = {}
    for item in filter(None, (p.strip() for p in args.max_samples_per_domain.split(","))):
        if "=" not in item:
            parser.error(f"--max-samples-per-domain 条目须为 domain=N: {item}")
        domain, value = item.split("=", 1)
        if domain not in DOMAINS:
            parser.error(f"未知域(--max-samples-per-domain): {domain}(可选 {DOMAINS})")
        try:
            domain_caps[domain] = int(value)
        except ValueError:
            parser.error(f"--max-samples-per-domain 上限须为整数: {item}")

    try:
        if args.catalog_sqlite is not None:
            catalog = load_sqlite_v4(args.catalog_sqlite, group_by_name=args.group_by_name)
            # dataVersion 缺失即拒建(fail-closed):无版本语料冻结后漂移闸/基线
            # 命名全部失真(基线曾落成 unknown.json 互相覆盖)。
            if not catalog.data_version:
                raise ValueError("catalog.sqlite 缺 data_version(catalog_meta 无该键)——"
                                 "无版本冻结即拒建")
        else:
            catalog = load_jsonl_set(args.catalog_jsonl)
        excluded = {d.strip() for d in args.exclude_domains.split(",") if d.strip()}
        if excluded - set(DOMAINS):
            parser.error(f"未知域(--exclude-domains): {sorted(excluded - set(DOMAINS))}")
        if excluded:
            before = len(catalog.entities)
            catalog.entities = [e for e in catalog.entities if e.domain not in excluded]
            print(f"exclude-domains {sorted(excluded)}: {before} → {len(catalog.entities)} 实体")
        config = BuildConfig(
            master_seed=args.master_seed, split_ratio=args.split_ratio, bands=bands,
            negatives_per_sample=args.negatives, min_eval_entities=args.min_eval_entities,
            mine_confusions=not args.no_mine,
            max_terms_per_entity=args.max_terms_per_entity,
            max_samples_per_domain=domain_caps,
            include_canonical_names=args.include_canonical_names,
        )
        report = build_corpus(catalog, args.out, config)
        if args.dump_entities is not None:
            args.dump_entities.parent.mkdir(parents=True, exist_ok=True)
            with open(args.dump_entities, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(json.dumps({"_meta": {"data_version": catalog.data_version,
                                               "source": catalog.source}}, ensure_ascii=False) + "\n")
                for entity in catalog.entities:
                    fh.write(json.dumps({"domain": entity.domain, "entity_id": entity.entity_id,
                                         "region": entity.region, "names": entity.names,
                                         "aliases": list(entity.aliases)}, ensure_ascii=False) + "\n")
            print(f"entities dumped: {args.dump_entities} ({len(catalog.entities)} 条)")
    except ValueError as exc:
        print(f"FAILED: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"FAILED: 输入/输出错误: {exc}", file=sys.stderr)
        return 1
    manifest = report.manifest
    print(json.dumps({
        "corpus": str(args.out),
        "manifest": str(args.out) + ".manifest.json",
        "counts": manifest["counts"],
        "corpus_sha256": manifest["corpus_sha256"],
        "catalog_data_version": manifest["catalog_data_version"],
        "pinyin_available": manifest["pinyin_available"],
        "dropped_collision": report.dropped_collision,
        "dropped_empty": report.dropped_empty,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
