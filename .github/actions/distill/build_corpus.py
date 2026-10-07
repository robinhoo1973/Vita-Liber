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
from entlink.catalog import load_jsonl_set, load_sqlite_v4, parse_catalog_jsonl  # noqa: E402


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
    args = parser.parse_args()

    if (args.catalog_jsonl is None) == (args.catalog_sqlite is None):
        parser.error("须且仅须提供 --catalog-jsonl 或 --catalog-sqlite 之一")
    if not 0 < args.split_ratio < 1:
        parser.error(f"--split-ratio 须在 (0, 1): {args.split_ratio}")
    bands = tuple(args.bands.split(","))
    for band in bands:
        if band not in BANDS:
            parser.error(f"未知噪声带: {band}(可选 {BANDS})")

    try:
        if args.catalog_sqlite is not None:
            catalog = load_sqlite_v4(args.catalog_sqlite)
            # dataVersion 缺失即拒建(fail-closed):无版本语料冻结后漂移闸/基线
            # 命名全部失真(基线曾落成 unknown.json 互相覆盖)。
            if not catalog.data_version:
                raise ValueError("catalog.sqlite 缺 data_version(catalog_meta 无该键)——"
                                 "无版本冻结即拒建")
        else:
            catalog = load_jsonl_set(args.catalog_jsonl)
        config = BuildConfig(
            master_seed=args.master_seed, split_ratio=args.split_ratio, bands=bands,
            negatives_per_sample=args.negatives, min_eval_entities=args.min_eval_entities,
            mine_confusions=not args.no_mine,
        )
        report = build_corpus(catalog, args.out, config)
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
