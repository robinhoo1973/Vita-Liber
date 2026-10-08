#!/usr/bin/env python3
"""语料质量闸(round5 E0 三闸断言化;[X2] 裁决消费;2026-10-08)。

此前三闸只记录不断言(span 损伤/CER/deficit 全在 manifest 里躺着)。本 CLI 把
它们变成 fail-closed 判据:

1. span 损伤率 ∈ policy.noise.spanDamageTargets ± spanDamageTolerance
   (仅当带内 spans ≥ spanDamageMinSpans 起效——小样本跳过,不假红);
2. per-band CER 均值 ∈ policy.noise.bandTargets ± 0.02(仅当 cer_n ≥ 1000);
3. 声明式网格:policy.corpus.requiredKinds − deferredKinds 每类必须
   出现在 manifest.params.kinds 且 kind 级 eval 单元 ≥ evalPerCell(60),
   deficit>0 = 红(**不存在 ≠ 通过**);
4. 值 holdout 不变量:forced ≥ 1;SFT 侧不得携带 value_holdout 标记;
   eval 侧必须含 ≥1 条 value_holdout(留出集被测);
5. underpowered 细格(eval < minSamplesPerCell)只登记入报告(不阻断),
   但必须显式列出——防「静默 underpowered 当通过」。

判据值全取 policy.json(单一事实源);缺 policy → 全跳过(训练机布局,由 CI 断言兜)。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

CER_TOLERANCE = 0.02


def _load_rows(path: Path) -> list[dict]:
    rows = []
    if path.is_file():
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if line.strip():
                    rows.append(json.loads(line))
    return rows


def check(extraction_dir: Path, policy: dict | None) -> tuple[list[str], dict]:
    manifest = json.loads((extraction_dir / "extraction_manifest.json").read_text(encoding="utf-8"))
    stats = manifest.get("stats") or {}
    failures: list[str] = []
    report: dict = {"underpowered_cells": [], "kind_eval": {}, "span_damage": {}, "cer": {}}

    noise = manifest.get("noise") or {}
    sd = noise.get("span_damage_by_band") or {}
    if policy is not None:
        pn = policy["noise"]
        targets, tol = pn["spanDamageTargets"], pn["spanDamageTolerance"]
        min_spans = pn["spanDamageMinSpans"]
        band_cer = pn["bandTargets"]
        ge = policy["gates"]["extraction"]
        quota_unit = ge.get("evalQuotaUnit", "cell")
        eval_quota = int(ge.get("evalPerCell", 60))
        min_cell = int(ge.get("minSamplesPerCell", 50))
        required = [k for k in policy["corpus"].get("requiredKinds", [])
                    if k not in (policy["corpus"].get("deferredKinds") or {})]
    else:
        targets, tol, min_spans, band_cer = {}, {}, 0, {}
        quota_unit, eval_quota, min_cell, required = "cell", 60, 50, []

    # ① span 损伤率
    for band, agg in sorted(sd.items()):
        report["span_damage"][band] = agg.get("rate")
        if band in targets and agg.get("spans", 0) >= min_spans:
            if abs(agg["rate"] - targets[band]) > tol.get(band, 0.05):
                failures.append(
                    f"span 损伤率({band}) {agg['rate']} 偏离目标 {targets[band]} 超容差 {tol.get(band)}")
    # ② CER
    for band, agg in sorted(sd.items()):
        report["cer"][band] = agg.get("cer_mean")
        if band in band_cer and agg.get("cer_n", 0) >= 1000:
            if abs(agg.get("cer_mean", 0.0) - band_cer[band]) > CER_TOLERANCE:
                failures.append(
                    f"CER 均值({band}) {agg.get('cer_mean')} 偏离目标 {band_cer[band]} 超 ±{CER_TOLERANCE}")

    # ③ 声明式网格
    present_kinds = set((manifest.get("params") or {}).get("kinds") or [])
    cells = stats.get("eval_cells") or {}
    for kind in required:
        if kind not in present_kinds:
            failures.append(f"必需卡种 {kind} 不在 manifest.params.kinds(缺失≠通过)")
            continue
        cell = cells.get(f"kind:{kind}")
        if cell is None:
            failures.append(f"kind 单元缺失: {kind}(声明式网格要求显式登记)")
            continue
        report["kind_eval"][kind] = cell.get("eval")
        if quota_unit == "kind" and cell.get("eval", 0) < eval_quota:
            failures.append(f"kind 单元 {kind} eval={cell.get('eval')} < 定额 {eval_quota}")
        if cell.get("deficit", 0) > 0:
            failures.append(f"kind 单元 {kind} deficit={cell['deficit']}(不足=不通过,不得静默)")

    # ⑤ underpowered 细格登记(不阻断)
    for key, cell in sorted(cells.items()):
        if "|" in key and cell.get("eval", 0) < min_cell:
            report["underpowered_cells"].append({"cell": key, "eval": cell.get("eval")})
    report["underpowered_cells_total"] = len(report["underpowered_cells"])
    report["underpowered_cells"] = report["underpowered_cells"][:40]

    # ④ holdout 不变量
    vh = stats.get("value_holdout") or {}
    if policy is not None:
        if int(vh.get("forced", 0)) < 1:
            failures.append("值 holdout 未生效:forced=0(留出集必须非空)")
        sft_rows = _load_rows(extraction_dir / "extraction_sft.jsonl")
        if any(r.get("value_holdout") for r in sft_rows):
            failures.append("SFT 侧出现 value_holdout 标记(留出值泄漏进训练侧)")
        eval_rows = _load_rows(extraction_dir / "extraction_eval.jsonl")
        if eval_rows and not any(r.get("value_holdout") for r in eval_rows):
            failures.append("eval 侧无 value_holdout 样本(留出集从未被测)")
    report["value_holdout"] = {k: v for k, v in vh.items() if k != "keys"}

    return failures, report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extraction-dir", type=Path, required=True)
    parser.add_argument("--write-verdict", type=Path, default=None)
    args = parser.parse_args()

    try:
        import policy as _policy
        pol = _policy.load()
    except (ImportError, FileNotFoundError, ValueError):
        pol = None
        print("WARN 无 policy.json——质量闸跳过(训练机布局;CI 必有)", file=sys.stderr)

    failures, report = check(args.extraction_dir, pol)
    verdict = {"stage": "corpus-quality", "status": "fail" if failures else "pass",
               "failures": failures, "report": report}
    if args.write_verdict is not None:
        args.write_verdict.write_text(json.dumps(verdict, ensure_ascii=False, indent=2) + "\n",
                                      encoding="utf-8")
    print(json.dumps(verdict, ensure_ascii=False, indent=2))
    if failures:
        print("RED: 语料质量闸不通过(build-extraction 拒产出后续)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
