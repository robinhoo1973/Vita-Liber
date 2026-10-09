#!/usr/bin/env python3
"""验收裁决器(2026-10-08 业主裁决=统一门控;T6 落点,单一机器裁决点)。

为什么存在:此前 verdict=fail 或 calibrate 失败时 run 仍绿(verdict 只阻断 publish、
calibrate 仅注解)——"run 绿≠验收"无载体,且语料可见性不受训练面证据约束。
本裁决器聚合全部证据 → acceptance.json → 未达 exit≠0(run 判红,补"不吞红");
publish-corpus 只认 acceptance.go(可见性由裁决器唯一门控)。

job 细分后(2026-10-08 业主指令:job 间文件/信息经 artifacts 与 needs 传输):
- 必需绿(required):tests/fetch-catalog/build-extraction/build-entlink/build-dialogue/
  smoke-encoder/smoke-extraction/smoke-dialogue/eval-entlink/eval-corpora —— 任一非
  success → 不通过;
- 必需裁决(verdicts):entlink=pass 且 corpora=pass(经 needs.outputs 传入);
- 记录面(record):长尾记录面(如 calibrate)既不进本裁决器 needs 也不传 record——
  "不阻断 go"与"不阻断完成时刻"必须同一口径(2026-10-08 S2 红队结构裁决);
  --record 机制保留供未来短小记录面使用。

负测:tests/test_acceptance.py(stdlib,CI tests job 无 torch 亦实跑)。
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

REQUIRED_JOBS = ("tests", "tests-torch", "export-prompts", "fetch-catalog",
                 "materialize-catalog", "build-extraction", "build-entlink",
                 "build-dialogue", "smoke-encoder", "smoke-extraction", "smoke-dialogue",
                 "eval-entlink", "eval-corpora")
REQUIRED_VERDICTS = ("entlink", "corpora")


def evaluate(*, results: dict, records: dict, verdicts: dict,
             required: tuple = REQUIRED_JOBS,
             required_verdicts: tuple = REQUIRED_VERDICTS) -> dict:
    """纯函数裁决:返回 acceptance 报告(go/failures/record 齐备)。"""
    failures = []
    for name in required:
        value = results.get(name)
        if value != "success":
            failures.append(f"job {name}: {value or 'missing'}(必需绿)")
    for name in required_verdicts:
        value = verdicts.get(name)
        if value != "pass":
            failures.append(f"verdict {name}={value or 'missing'}(必须 pass)")
    run_url = "/".join(p for p in (
        os.environ.get("GITHUB_SERVER_URL", ""),
        os.environ.get("GITHUB_REPOSITORY", ""),
        f"actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}",
    ) if p)
    return {
        "schema_version": 1,
        "stage": "corpus-freeze",
        "go": not failures,
        "required": {name: results.get(name) for name in required},
        "verdicts": {name: verdicts.get(name) for name in required_verdicts},
        "record": dict(records),
        "failures": failures,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "run_url": run_url,
        "git_sha": os.environ.get("GITHUB_SHA", ""),
    }


def _pairs(items: list) -> dict:
    out = {}
    for item in items:
        key, _, value = item.partition("=")
        out[key] = value
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result", action="append", default=[], metavar="NAME=RESULT",
                        help="必需绿的作业结果(可重复;如 smoke-encoder=success)")
    parser.add_argument("--record", action="append", default=[], metavar="NAME=RESULT",
                        help="记录面作业结果(可重复;不阻断,如 calibrate=failure)")
    parser.add_argument("--verdict", action="append", default=[], metavar="NAME=VALUE",
                        help="必需裁决(可重复;entlink=pass corpora=pass)")
    parser.add_argument("--out", type=Path, default=Path("acceptance.json"))
    args = parser.parse_args()

    report = evaluate(results=_pairs(args.result), records=_pairs(args.record),
                      verdicts=_pairs(args.verdict))
    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                        encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))
    if not report["go"]:
        print("::error::验收未过——" + "; ".join(report["failures"]), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
