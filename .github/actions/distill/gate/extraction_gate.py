#!/usr/bin/env python3
"""抽取分带评分(纯函数,2026-10-08 round5 E0;stdlib 零依赖)。

契约(round5 §2.5,数据席 C 席方案收敛):
- 双口径: strict = (scope,row,key,value,lineIndex) 全等;partial(0.5) = 同
  (scope,row,key) 且 value 互为子串或 lineIndex 相等 —— 参照 SemEval-2013 四场景
  的 strict/partial 两档(nervaluate MIT 口径);
- 硬零类 H1–H5(绝对否决,不设线): 非法 JSON / 非逐字(App value.range(of:) 口径,
  pred 值必须逐字出现在对应行内) / 文法不可达字符(输入侧扫描) / 硬负例建行 /
  结构错(键非串/形状错);
- 逐单元(band×kind)聚合;worst_cell=样本数达标单元中 F1_strict 最低者(禁综合分补偿);
- tripwire: 每单元 strict 接受数下限 + 全拒识判红(只判红不设及格线)。

判据数值不在此文件(冻结于 policy.json:tau/evalPerCell/minSamples);本文件=纯计分器。
负测: tests/test_extraction_gate.py。评分器自身正确性由 --gold-only identity 臂先行自证
(金标当预测 → 全格 F1=1.0、硬零=0)。
"""
from __future__ import annotations

import json

PARTIAL_CREDIT = 0.5
_SPAN_KEYS = ("key", "value", "lineIndex")


def _iter_spans(data: dict) -> tuple[list[tuple], list[str]]:
    """展平 {"shared":[...], "rows":[[...]]} → [(scope,row_idx,key,value,lineIndex)], 结构错列表。"""
    errors: list[str] = []
    spans: list[tuple] = []
    shared = data.get("shared", [])
    rows = data.get("rows", [])
    if not isinstance(shared, list):
        errors.append("shared 非列表")
        shared = []
    if not isinstance(rows, list):
        errors.append("rows 非列表")
        rows = []
    for span in shared:
        parsed = _parse_span(span)
        if parsed is None:
            errors.append(f"shared span 形状错: {span!r}")
            continue
        spans.append(("shared", -1) + parsed)
    for row_idx, row in enumerate(rows):
        if not isinstance(row, list):
            errors.append(f"rows[{row_idx}] 非列表")
            continue
        for span in row:
            parsed = _parse_span(span)
            if parsed is None:
                errors.append(f"row span 形状错: {span!r}")
                continue
            spans.append(("row", row_idx) + parsed)
    return spans, errors


def _parse_span(span) -> tuple | None:
    if not isinstance(span, dict):
        return None
    if any(k not in span for k in _SPAN_KEYS):
        return None
    key, value, line_index = span["key"], span["value"], span["lineIndex"]
    if not isinstance(key, str) or not isinstance(value, str):
        return None
    if not isinstance(line_index, int) or line_index < 0:
        return None
    return (key, value, line_index)


def _match(gold: list[tuple], pred: list[tuple]) -> tuple[list[tuple], list[tuple], list[tuple]]:
    """贪心一对一匹配(按 (scope,row,key) 分组): 返回 (strict对, partial对, 未匹配gold)。"""
    remaining = list(pred)
    strict_pairs: list[tuple] = []
    partial_pairs: list[tuple] = []
    unmatched_gold: list[tuple] = []
    for g in gold:
        # 严格: 全等
        exact = next((p for p in remaining if p == g), None)
        if exact is not None:
            remaining.remove(exact)
            strict_pairs.append(g)
            continue
        # 部分: 同 (scope,row,key) 且 value 互为子串或 lineIndex 相等
        for p in list(remaining):
            if p[0] == g[0] and p[1] == g[1] and p[2] == g[2]:
                if p[3] in g[3] or g[3] in p[3] or p[4] == g[4]:
                    remaining.remove(p)
                    partial_pairs.append(g)
                    break
        else:
            unmatched_gold.append(g)
    return strict_pairs, partial_pairs, unmatched_gold


def score_sample(*, gold: dict, pred_text: str, lines: list[str] | None = None,
                 neg_lines: set[int] | None = None,
                 unreachable_chars: set[str] | None = None) -> dict:
    """单样本评分。lines=用户文本行(展开 H2 非逐字检查);neg_lines=硬负例行号(H4)。"""
    hard_zero = {"json_invalid": 0, "non_verbatim": 0, "grammar_char": 0,
                 "negative_row": 0, "structure": 0}
    gold_spans, gold_errors = _iter_spans(gold)
    hard_zero["structure"] += len(gold_errors)  # 金标侧结构错计入(构建期应已排除)

    if unreachable_chars:
        hard_zero["grammar_char"] += sum(
            1 for (_s, _r, _k, v, _li) in gold_spans
            if any(ch in unreachable_chars for ch in v))

    try:
        pred_data = json.loads(pred_text)
        if not isinstance(pred_data, dict):
            raise ValueError("顶层非对象")
    except (json.JSONDecodeError, ValueError):
        hard_zero["json_invalid"] = 1
        return _result(0, len(gold_spans), 0, 0, hard_zero)

    pred_spans, pred_errors = _iter_spans(pred_data)
    hard_zero["structure"] += len(pred_errors)

    if lines is not None:
        for (_s, _r, _k, v, li) in pred_spans:
            if li >= len(lines) or v not in lines[li]:
                hard_zero["non_verbatim"] += 1
    if neg_lines:
        hard_zero["negative_row"] += sum(1 for sp in pred_spans if sp[4] in neg_lines)

    strict_pairs, partial_pairs, _unmatched = _match(gold_spans, pred_spans)
    return _result(len(strict_pairs), len(gold_spans), len(partial_pairs),
                   len(pred_spans), hard_zero)


def _result(strict_tp: int, gold_n: int, partial_n: int, pred_n: int, hard_zero: dict) -> dict:
    return {
        "strict_tp": strict_tp, "partial_n": partial_n,
        "gold": gold_n, "pred": pred_n, "hard_zero": hard_zero,
    }


def _prf(tp: float, pred_n: int, gold_n: int) -> dict:
    p = tp / pred_n if pred_n else 0.0
    r = tp / gold_n if gold_n else 0.0
    f = 2 * p * r / (p + r) if (p + r) else 0.0
    return {"p": round(p, 6), "r": round(r, 6), "f1": round(f, 6)}


def aggregate(results: list[dict], *, by: tuple = ("band", "kind"),
              min_samples: int = 50) -> dict:
    """逐单元聚合。每条 result 需带 meta{band,kind,...}(由调用方注入)。"""
    cells: dict[tuple, list[dict]] = {}
    for item in results:
        key = tuple(item["meta"].get(field, "?") for field in by)
        cells.setdefault(key, []).append(item)
    out: dict[str, dict] = {}
    for key, items in sorted(cells.items()):
        strict_tp = sum(i["strict_tp"] for i in items)
        partial_n = sum(i["partial_n"] for i in items)
        gold_n = sum(i["gold"] for i in items)
        pred_n = sum(i["pred"] for i in items)
        hz = {k: sum(i["hard_zero"][k] for i in items) for k in items[0]["hard_zero"]}
        cell = {
            "samples": len(items),
            "strict": _prf(strict_tp, pred_n, gold_n),
            "partial": _prf(strict_tp + PARTIAL_CREDIT * partial_n, pred_n, gold_n),
            "hard_zero": hz,
            "tripwire": _tripwire(strict_tp, gold_n, pred_n),
        }
        if len(items) < min_samples:
            cell["underpowered"] = True
        out["|".join(str(k) for k in key)] = cell
    return out


def _tripwire(strict_tp: int, gold_n: int, pred_n: int) -> dict:
    """全拒识判红(只判红,不设及格线);接受数下限由调用方对 policy 值比较。"""
    return {
        "accepts": strict_tp,
        "all_rejected": pred_n == 0 and gold_n > 0,
        "all_reject_recall_zero": pred_n == 0 and strict_tp == 0,
    }


def worst_cell(cells: dict, *, min_samples: int = 50) -> dict | None:
    """取最差单元(样本数达标的单元中 F1_strict 最低);禁综合分补偿。"""
    eligible = [(name, c) for name, c in cells.items()
                if not c.get("underpowered") and c["samples"] >= min_samples]
    if not eligible:
        return None
    name, cell = min(eligible, key=lambda kv: kv[1]["strict"]["f1"])
    return {"cell": name, "f1_strict": cell["strict"]["f1"], "samples": cell["samples"]}
