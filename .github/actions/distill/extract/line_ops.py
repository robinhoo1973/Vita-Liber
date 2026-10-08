"""行级结构噪声(round5 §2.2 C 席;字节敏感数据批)。

模拟 OCR/ASR 的行结构错误:丢行、列交织、行合并、行切分。
硬约束(违一条即污染语料):
  1) **lineIndex 结构推导重算**:ops 只维护 old→new 行映射,span 的 lineIndex 由映射
     更新——不做 span 值字符串搜索定位(F-b 线纪律)。
  2) **丢行/交织仅无 span 行**;合并=相邻整行拼接(允许其中一行带 span,值为子串
     保持);切分仅无 span 行,切点=分隔符串位置(结构扫描,与 span 值无关)。
     span 行不切=保守子集(登记:span 行切分留给 v2.1 行噪声)。
  3) 确定性:同 rng 序列同输出;ops 计数入样本/manifest 元数据。
调用方:build_extraction_corpus.py 主循环(构造期 check_verbatim 兜底)。
"""
from __future__ import annotations

import random
import re

# 带位算子率(clean=恒等;强度沿 band 单调)
BAND_LINE_RATES: dict[str, dict[str, float]] = {
    "clean": {},
    "light": {"drop": 0.02, "merge": 0.02},
    "medium": {"drop": 0.04, "merge": 0.04, "interleave": 0.03},
    "heavy": {"drop": 0.06, "merge": 0.06, "interleave": 0.05, "split": 0.04},
    "extreme": {"drop": 0.08, "merge": 0.08, "interleave": 0.07, "split": 0.06},
}

# 切分候选位:行内分隔符串(全角冒号/半角冒号/双空格/中点/单空格兜底)
_SPLIT_SEP = re.compile(r"(?: {1,2}|[：:][ 　]?|[·．][ 　]?)")


def _eligible_split_positions(text: str) -> list:
    return [m for m in _SPLIT_SEP.finditer(text) if m.start() > 0 and m.end() < len(text)]


def apply_line_ops(lines: list, shared: list, rows: list, rng: random.Random, *,
                   band: str) -> tuple[list, list, list, dict]:
    """对样本行列表施加结构算子;span 的 lineIndex 经映射重算(原地更新 span 字典)。

    返回 (new_lines, shared, rows, stats);stats={"drop","merge","interleave","split"}。
    """
    stats = {"drop": 0, "merge": 0, "interleave": 0, "split": 0}
    rates = BAND_LINE_RATES.get(band, {})
    n = len(lines)
    if not rates or n == 0:
        return list(lines), shared, rows, stats

    all_spans = list(shared) + [s for row in rows for s in row]
    has_span = [False] * n
    for s in all_spans:
        li = s["lineIndex"]
        if 0 <= li < n:
            has_span[li] = True

    # ① 丢行(仅无 span 行)
    kept = []
    for i, text in enumerate(lines):
        draw = rng.random()
        if not has_span[i] and draw < rates.get("drop", 0.0):
            stats["drop"] += 1
            continue
        kept.append({"text": text, "olds": [i], "spanned": has_span[i]})

    # ② 合并(相邻整行拼接;至多一行带 span)
    merged = []
    i = 0
    while i < len(kept):
        if i + 1 < len(kept):
            draw = rng.random()
            a, b = kept[i], kept[i + 1]
            if (draw < rates.get("merge", 0.0)
                    and not (a["spanned"] and b["spanned"])):
                merged.append({"text": a["text"] + " " + b["text"],
                               "olds": a["olds"] + b["olds"],
                               "spanned": a["spanned"] or b["spanned"]})
                stats["merge"] += 1
                i += 2
                continue
        merged.append(kept[i])
        i += 1

    # ③ 交织(仅无 span 行;每样本至多一次交换=列错位的保守形态)
    idx_elig = [k for k, e in enumerate(merged) if not e["spanned"]]
    draw = rng.random()
    if len(idx_elig) >= 2 and draw < rates.get("interleave", 0.0):
        a, b = rng.sample(idx_elig, 2)
        merged[a], merged[b] = merged[b], merged[a]
        stats["interleave"] += 1

    # ④ 切分(仅无 span 行;切点=分隔符位置)
    expanded = []
    for e in merged:
        draw = rng.random()
        if not e["spanned"] and draw < rates.get("split", 0.0):
            positions = _eligible_split_positions(e["text"])
            if positions:
                m = rng.choice(positions)
                left, right = e["text"][:m.start()], e["text"][m.end():]
                if left and right:
                    expanded.append({"text": left, "olds": e["olds"][:1], "spanned": False})
                    expanded.append({"text": right, "olds": e["olds"][1:], "spanned": False})
                    stats["split"] += 1
                    continue
        expanded.append(e)

    old_to_new = {}
    for pos, e in enumerate(expanded):
        for old in e["olds"]:
            old_to_new[old] = pos
    for s in all_spans:
        s["lineIndex"] = old_to_new[s["lineIndex"]]
    return [e["text"] for e in expanded], shared, rows, stats


if __name__ == "__main__":
    demo_lines = ["仁济医院 门诊处方笺", "科室：心内科", "医师：王医生", "阿莫西林胶囊 0.25g 每日两次"]
    demo_spans = [{"key": "hospital", "value": "仁济医院", "unit": None, "lineIndex": 0},
                  {"key": "department", "value": "心内科", "unit": None, "lineIndex": 1}]
    for band in ("light", "medium", "heavy", "extreme"):
        out, _, _, st = apply_line_ops(demo_lines, list(demo_spans), [],
                                       random.Random(7), band=band)
        print(band, st, "|", out)
