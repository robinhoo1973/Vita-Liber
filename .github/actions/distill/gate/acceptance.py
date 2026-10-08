#!/usr/bin/env python3
"""验收裁决器(2026-10-08 业主裁决=统一门控;T6 落点,单一机器裁决点)。

为什么存在:此前 verdict=fail 或 calibrate 失败时 run 仍绿(verdict 只阻断 publish、
calibrate 仅注解)——"run 绿≠验收"无载体,且语料可见性不受训练面证据约束。
本裁决器聚合全部证据 → acceptance.json → 未达 exit≠0(run 判红,补"不吞红");
publish-corpus 只认 acceptance.go(可见性由裁决器唯一门控)。

判据冻结于此文件(禁散落 workflow;变更=PR 可审计):
- 必需绿(required):tests/prepare/eval/smoke 任一非 success → 不通过;
- eval.verdict 必须 == 'pass';
- 记录面(record):calibrate(两矩阵腿聚合)等——写入裁决件但不阻断
  (§7.2 回落条款:标定是数据不是失败;macOS 腿 cancelled 同理记录)。

负测:tests/test_acceptance.py(stdlib,CI tests job 无 torch 亦实跑)。
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

REQUIRED_JOBS = ("tests", "prepare", "eval", "smoke")


def evaluate(*, results: dict, records: dict, verdict: str,
             required: tuple = REQUIRED_JOBS) -> dict:
    """纯函数裁决:返回 acceptance 报告(go/failures/record 齐备)。"""
    failures = []
    for name in required:
        value = results.get(name)
        if value != "success":
            failures.append(f"job {name}: {value or 'missing'}(必需绿)")
    if verdict != "pass":
        failures.append(f"eval.verdict={verdict or 'missing'}(必须 pass)")
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
        "record": dict(records),
        "verdict": verdict,
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
                        help="必需绿的作业结果(可重复;如 smoke=success)")
    parser.add_argument("--record", action="append", default=[], metavar="NAME=RESULT",
                        help="记录面作业结果(可重复;不阻断,如 calibrate=failure)")
    parser.add_argument("--verdict", default="", help="eval 裁决(pass/fail/空)")
    parser.add_argument("--out", type=Path, default=Path("acceptance.json"))
    args = parser.parse_args()

    report = evaluate(results=_pairs(args.result), records=_pairs(args.record),
                      verdict=args.verdict)
    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                        encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))
    if not report["go"]:
        print("::error::验收未过——" + "; ".join(report["failures"]), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
