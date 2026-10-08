#!/usr/bin/env python3
"""部署件抽取打分 CLI(2026-10-08 round5 E0;先只产报告,不接裁决)。

职责边界: eval_corpora.py 复验**冻结语料自身**不变量;本 CLI 打分**模型对冻结语料**,
两者零重叠(round5 §2.5)。输出 status=report-only;D19 定线后另批接 gate。

契约:
- 输入 = corpus 冻结件 extraction_eval.jsonl(每行 conversations[system,user,assistant];
  user 行格式 "[i] 文本" 以 \\n 连接——与 build_extraction_corpus.py:565 同源) +
  模型输出 JSONL(每行 {"id"?: str, "text": "<assistant 原文>"})。
- 匹配: 全行有 id 且输出有 id → 按 id;否则按行序回退(记 coverage)。
  coverage==0 → 运行错误 exit 1(无证据 ≠ 全错,禁"无证据当全错")。
- 口径: 分带×卡种 strict/partial(见 gate/extraction_gate.py);硬零类 H1–H5 计数;
  worst_cell 取最差(禁综合分补偿);--gold-only=identity 臂(金标当预测,期望全格 F1=1)。
- 判据值取自 policy.json(tau/minSamples);--require-bands 时缺 band 即 exit 1。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from gate.extraction_gate import PARTIAL_CREDIT, aggregate, score_sample, worst_cell  # noqa: E402


def _load_eval(path: Path) -> list[dict]:
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                rows.append(json.loads(line))
    return rows


def _split_user_lines(user_content: str) -> list[str]:
    """与 build_extraction_corpus.py:565 同源: "[i] 文本" 逐行。"""
    lines = []
    for entry in user_content.split("\n"):
        lines.append(entry.split("] ", 1)[1] if "] " in entry else entry)
    return lines


def _row_gold_and_lines(row: dict) -> tuple[dict, list[str], str, str]:
    conv = row["conversations"]
    by_role = {m["role"]: m["content"] for m in conv}
    gold = json.loads(by_role["assistant"])
    lines = _split_user_lines(by_role["user"])
    noise = row.get("noise") or {}
    band = row.get("band") or noise.get("band") or "unlabeled"
    kind = row.get("kind") or row.get("meta", {}).get("kind") or "unlabeled"
    return gold, lines, band, kind


def _load_outputs(path: Path | None) -> dict:
    if path is None:
        return {}
    outputs = {}
    with open(path, encoding="utf-8") as fh:
        for idx, line in enumerate(fh):
            if not line.strip():
                continue
            item = json.loads(line)
            key = str(item["id"]) if "id" in item else f"__row{idx}"
            outputs[key] = item["text"]
    return outputs


def _tau_from_policy() -> float:
    try:
        from policy import get, load
        return float(get(load(), "gates.extraction.tau"))
    except Exception:  # noqa: BLE001 - policy 缺席时回退登记值
        return 0.03


def run(args) -> int:
    eval_rows = _load_eval(Path(args.eval_file))
    if not eval_rows:
        print("::error::eval 文件为空——无证据不当全错", file=sys.stderr)
        return 1

    outputs = _load_outputs(Path(args.model_output) if args.model_output else None)
    use_id = args.gold_only is False and outputs and all(
        "id" in row for row in eval_rows) and all(
        not k.startswith("__row") for k in outputs)

    results, missing = [], 0
    for idx, row in enumerate(eval_rows):
        gold, lines, band, kind = _row_gold_and_lines(row)
        if args.require_bands and band == "unlabeled":
            print(f"::error::--require-bands: 行 {idx} 缺 band 标签", file=sys.stderr)
            return 1
        if args.gold_only:
            pred_text = json.dumps(gold, ensure_ascii=False)
        else:
            key = str(row.get("id", f"__row{idx}")) if use_id else f"__row{idx}"
            if key not in outputs:
                missing += 1
                # 缺输出=覆盖缺失(记 coverage),按"空预测"计 FN;不得计为 H1 非法 JSON
                pred_text = json.dumps({"shared": [], "rows": []})
            else:
                pred_text = outputs[key]
        res = score_sample(gold=gold, pred_text=pred_text, lines=lines)
        res["meta"] = {"band": band, "kind": kind, "row": idx}
        results.append(res)

    coverage = (len(results) - missing) / len(results)
    if args.gold_only is False and coverage == 0:
        print("::error::模型输出覆盖为 0——无证据不当全错(exit 1)", file=sys.stderr)
        return 1

    min_samples = int(args.min_samples)
    cells = aggregate(results, by=("band", "kind"), min_samples=min_samples)
    worst = worst_cell(cells, min_samples=min_samples)

    baseline_delta: dict = {}
    regressions: list = []
    if args.baseline:
        baseline = json.loads(Path(args.baseline).read_text(encoding="utf-8"))
        base_cells = baseline.get("cells", {})
        for name, cell in cells.items():
            if name in base_cells:
                delta = round(cell["strict"]["f1"] - base_cells[name]["strict"]["f1"], 6)
                baseline_delta[name] = delta
                if delta < -float(args.tau):
                    regressions.append({"cell": name, "delta": delta})

    hz_totals: dict = {}
    for res in results:
        for key, val in res["hard_zero"].items():
            hz_totals[key] = hz_totals.get(key, 0) + val

    report = {
        "schema_version": 1,
        "kind": "extract-model-eval",
        "status": "report-only",
        "cells": cells,
        "worst_cell": worst,
        "hard_zero_totals": hz_totals,
        "coverage": round(coverage, 6),
        "samples": len(results),
        "params": {"tau": float(args.tau), "min_samples": min_samples,
                   "partial_credit": PARTIAL_CREDIT, "require_bands": bool(args.require_bands),
                   "gold_only": bool(args.gold_only)},
        "baseline_delta": baseline_delta,
        "regressions": regressions,
        "failures": [],
    }
    canonical = json.dumps(report, ensure_ascii=False, sort_keys=True)
    report["self_sha256"] = hashlib.sha256(canonical.encode()).hexdigest()

    if args.write_report:
        Path(args.write_report).write_text(
            json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8")
    if args.write_verdict:
        verdict = {"schema_version": 1, "kind": "extract-model-eval",
                   "status": "report-only", "verdict": "report-only",
                   "worst_cell": worst, "hard_zero_totals": hz_totals,
                   "coverage": report["coverage"], "regressions": regressions,
                   "failures": [], "report_sha256": report["self_sha256"]}
        Path(args.write_verdict).write_text(
            json.dumps(verdict, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8")
    print(json.dumps({"cells": len(cells), "samples": len(results),
                      "coverage": report["coverage"], "worst_cell": worst,
                      "hard_zero_totals": hz_totals}, ensure_ascii=False))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--eval-file", default="extraction_eval.jsonl")
    parser.add_argument("--model-output", default=None,
                        help='模型输出 JSONL({"id"?,"text"})')
    parser.add_argument("--gold-only", action="store_true", help="identity 臂:金标当预测")
    parser.add_argument("--baseline", default=None, help="上期 report json(逐格非劣)")
    parser.add_argument("--tau", default=None, help="非劣阈值(默认取 policy.json)")
    parser.add_argument("--min-samples", default=50)
    parser.add_argument("--require-bands", action="store_true")
    parser.add_argument("--write-report", default=None)
    parser.add_argument("--write-verdict", default=None)
    args = parser.parse_args(argv)
    if args.tau is None:
        args.tau = _tau_from_policy()
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
