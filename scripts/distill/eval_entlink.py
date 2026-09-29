#!/usr/bin/env python3
"""SU-M15-ENTLINK 评测闸 CLI:数据基线对照臂(P1)+ 模型五层闸(P3,条件)。

用法:
  python3 scripts/distill/eval_entlink.py \
      --corpus out/corpus.jsonl \
      --catalog-jsonl drug=a.jsonl,... \
      --wording-source CoreKit/Sources/Domain/AlertEngine.swift \
      --write-baseline out/baselines --write-verdict out/verdict.json

纪律(计划文档 §10):
- manifest 必须通过校验且 catalog dataVersion 与 manifest 一致,否则拒评(fail-closed);
- 基线臂报告逐带×域;verdict=fail 时退出码 2(阻断 publish),运行错误退出码 1。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from corpus.manifest import verify_manifest  # noqa: E402
from entlink.catalog import load_jsonl_set, load_sqlite_v4, parse_catalog_jsonl  # noqa: E402
from entlink.recall import RecallEngine  # noqa: E402
from gate.entlink_gate import GateConfig, run_gate, write_baseline, write_verdict  # noqa: E402
from gate.wording import WordingGuard, export_wording_blacklist  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, default=None, help="缺省=corpus 路径 + .manifest.json")
    parser.add_argument("--catalog-jsonl", type=parse_catalog_jsonl, default=None)
    parser.add_argument("--catalog-sqlite", type=Path, default=None)
    parser.add_argument("--wording-source", type=Path, default=None)
    parser.add_argument("--model-candidates", type=Path, default=None)
    parser.add_argument("--min-accepts", type=int, default=50)
    parser.add_argument("--top-k", type=int, default=10)
    parser.add_argument("--write-baseline", type=Path, default=None)
    parser.add_argument("--write-verdict", type=Path, default=None)
    args = parser.parse_args()

    manifest_path = args.manifest or args.corpus.with_suffix(args.corpus.suffix + ".manifest.json")
    try:
        manifest = verify_manifest(manifest_path, args.corpus)
    except (ValueError, OSError) as exc:
        print(f"FAILED manifest 校验: {exc}", file=sys.stderr)
        return 1

    if (args.catalog_jsonl is None) == (args.catalog_sqlite is None):
        parser.error("须且仅须提供 --catalog-jsonl 或 --catalog-sqlite 之一")
    if args.catalog_sqlite is not None:
        catalog = load_sqlite_v4(args.catalog_sqlite)
    else:
        catalog = load_jsonl_set(args.catalog_jsonl)

    # dataVersion 一致断言:目录漂移即拒评(fail-closed,计划文档 §10 漂移闸)。
    # 空版本同样拒评:曾用「两边都非空才比」,空 data_version 静默跳过漂移闸
    # 且基线落成 unknown.json 互相覆盖(历史教训)。
    if not manifest["catalog_data_version"] or not catalog.data_version:
        print(f"FAILED dataVersion 缺失: manifest={manifest['catalog_data_version']!r} "
              f"catalog={catalog.data_version!r}——无版本冻结即拒评(fail-closed)", file=sys.stderr)
        return 1
    if manifest["catalog_data_version"] != catalog.data_version:
        print(f"FAILED dataVersion 漂移: manifest={manifest['catalog_data_version']} "
              f"catalog={catalog.data_version}——拒评", file=sys.stderr)
        return 1

    wording_guard = None
    if args.wording_source is not None:
        try:
            wording_guard = WordingGuard(export_wording_blacklist(args.wording_source)["entries"])
        except (ValueError, re.error) as exc:  # re.error: ICU-only 语法在 Python 侧编译失败
            print(f"FAILED 措辞负清单导出: {exc}", file=sys.stderr)
            return 1

    model_candidates = None
    if args.model_candidates is not None:
        model_candidates = {row["id"]: row["candidates"]
                            for row in (json.loads(l) for l in args.model_candidates.read_text(encoding="utf-8").splitlines() if l.strip())}

    eval_lines = []
    for line in args.corpus.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if row.get("split") == "eval":
            eval_lines.append(row)

    engine = RecallEngine().build(catalog)
    result = run_gate(
        engine=engine, eval_lines=eval_lines,
        config=GateConfig(min_accepts=args.min_accepts, top_k=args.top_k),
        wording_guard=wording_guard, model_candidates=model_candidates,
        known_entity_ids={e.entity_id for e in catalog.entities},
    )

    data_version = manifest["catalog_data_version"] or "unknown"
    if args.write_baseline is not None:
        write_baseline(args.write_baseline / f"{data_version}.json", result, data_version)
    if args.write_verdict is not None:
        write_verdict(args.write_verdict, result, data_version)

    print(json.dumps({"verdict": result.verdict, "failures": result.failures,
                      "metrics": result.metrics}, ensure_ascii=False, indent=2))
    if result.verdict == "fail":
        print("RED: 评测闸不通过,阻断 publish", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
