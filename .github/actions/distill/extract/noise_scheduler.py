"""目标 CER 编辑预算噪声调度器(噪声 v2 核心;round5 仲裁 α/数据席 C 终案)。

模型:每带=一份「编辑预算」——按族份额把 CER 目标折算成**精确编辑次数**
    n_f = round(cer_target × len(text) × share_f)
替换类族(confusion/width/punct)同一位置每段至多改一次(used 集合,防反复砸);
结构类族(space/delete/insert)每轮按当前串重算合法位置。段末实测
cer_measured=Levenshtein(clean,noisy)/len(clean);与目标差>1pp 记 deficit
(**登记不阻断**)。验收量=span 损伤率(P(span≥1 编辑)),由构建器用
`span_damage_stats` 聚合(带目标 11/26/47/70%±容差,round5 §2.2)。

确定性:random.Random(seed) 逐操作消费;表进仓+码点序 ⇒ 跨机逐同。
"""
from __future__ import annotations

import random

try:
    from extract.confusion import ConfusionTables
except ImportError:  # 直跑(working-directory=extract)时的相对导入回落
    from confusion import ConfusionTables  # type: ignore

FAMILIES = ("confusion", "width", "punct", "space", "delete", "insert")

# 带位族份额(round5 §2.2 矩阵的 OCR 侧;和不必=1,应用前归一)
BAND_SHARES: dict[str, dict[str, float]] = {
    "light": {"confusion": 0.60, "width": 0.15, "space": 0.10, "punct": 0.15},
    "medium": {"confusion": 0.60, "width": 0.15, "space": 0.15, "delete": 0.05, "punct": 0.05},
    "heavy": {"confusion": 0.65, "width": 0.10, "space": 0.15, "delete": 0.05, "insert": 0.05},
    "extreme": {"confusion": 0.60, "width": 0.05, "space": 0.10, "delete": 0.15, "insert": 0.10},
}
PUNCT_VARIANTS = "，。、;；:：,．·-—"
_FULLWIDTH_BASE = 0xFEE0


def levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def _to_fullwidth(ch: str) -> str | None:
    code = ord(ch)
    if 0x21 <= code <= 0x7E:
        return chr(code + _FULLWIDTH_BASE)
    if 0xFF01 <= code <= 0xFF5E:
        return chr(code - _FULLWIDTH_BASE)
    return None


def _eligible(chars: list[str], family: str, tables: ConfusionTables) -> list[int]:
    if family == "confusion":
        return [i for i, ch in enumerate(chars) if tables.mirrors_for(ch)]
    if family == "width":
        return [i for i, ch in enumerate(chars) if _to_fullwidth(ch)]
    if family == "punct":
        return [i for i, ch in enumerate(chars) if ch in PUNCT_VARIANTS]
    if family == "space":
        return list(range(len(chars)))
    if family == "delete":
        return list(range(len(chars))) if len(chars) > 1 else []
    if family == "insert":
        return list(range(len(chars)))
    return []


def _apply(chars: list[str], family: str, i: int, rng: random.Random,
           tables: ConfusionTables) -> bool:
    if family == "confusion":
        mirrors = tables.mirrors_for(chars[i])
        if not mirrors:
            return False
        chars[i] = rng.choice([m for m, _ in mirrors])
    elif family == "width":
        fw = _to_fullwidth(chars[i])
        if fw is None:
            return False
        chars[i] = fw
    elif family == "punct":
        candidates = [p for p in PUNCT_VARIANTS if p != chars[i]]
        if not candidates:
            return False
        chars[i] = rng.choice(candidates)
    elif family == "space":
        if chars[i] == " ":
            del chars[i]
        else:
            chars.insert(i, " ")
    elif family == "delete":
        if len(chars) <= 1:
            return False
        del chars[i]
    elif family == "insert":
        mirrors = tables.mirrors_for(chars[i])
        chars.insert(i + 1, mirrors[0][0] if mirrors else chars[i])
    else:
        return False
    return True


def noisify_segment(text: str, *, band: str, cer_target: float, rng: random.Random,
                    tables: ConfusionTables | None = None,
                    shares: dict[str, float] | None = None) -> tuple[str, dict]:
    """按带位编辑预算对一段文本合成噪声;返回 (noisy, meta)。"""
    tables = tables or ConfusionTables.load()
    if not text:
        return text, {"band": band, "cer_target": cer_target, "cer_measured": 0.0,
                      "families": [], "ops": {}}
    raw_shares = dict(shares or BAND_SHARES.get(band, BAND_SHARES["medium"]))
    total_share = sum(raw_shares.values()) or 1.0
    share = {f: v / total_share for f, v in raw_shares.items()}

    chars = list(text)
    ops: dict[str, int] = {}
    for family in FAMILIES:
        if family not in share:
            continue
        # 随机取整(期望保真):短段上 round() 会把 light 档预算恒归零(实证),
        # floor + Bernoulli(小数部分) 保住 E[编辑数]=cer_target×L_eff×share_f。
        # v2.1 长度补偿(2026-10-08 R0 首测→27k 实测标定):带位验收量=span 损伤率,
        # 其 4-8 字锚上标定(11/26/47/70%);语料含大量 1-3 字 span,纯 len 预算让
        # P(damage) 系统性偏低(CI 0.0767/0.1893/0.3449/0.5368 ≈0.73×)。
        # L_eff=7:27k 本地实测(锚=6:0.0969/0.2326/0.4332/0.6513)按 μ 比例反推
        # 锚=7 落点 0.112/0.266/0.485/0.707——四带均入目标±容差;长 span 行为不变。
        exp_edits = cer_target * max(len(text), 7) * share[family]
        target_edits = int(exp_edits)
        if rng.random() < (exp_edits - target_edits):
            target_edits += 1
        used: set[int] = set()
        for _ in range(target_edits):
            eligible = [p for p in _eligible(chars, family, tables) if p not in used]
            if not eligible:
                break
            i = rng.choice(eligible)
            if _apply(chars, family, i, rng, tables):
                ops[family] = ops.get(family, 0) + 1
                if family in ("confusion", "width", "punct"):
                    used.add(i)  # 替换类:同位置每段至多改一次

    noisy = "".join(chars)
    dist = levenshtein(text, noisy)
    return noisy, {
        "band": band,
        "cer_target": round(cer_target, 4),
        "cer_measured": round(dist / max(len(text), 1), 4),
        "families": sorted(ops.keys()),
        "ops": ops,
    }


def span_damage_stats(pairs: list[tuple[str, str]]) -> dict:
    """span 损伤率(P(span≥1 编辑))——带位验收量(round5 §2.2)。"""
    damaged = sum(1 for clean, noisy in pairs if clean != noisy)
    total = len(pairs)
    return {"spans": total, "damaged": damaged,
            "rate": round(damaged / max(total, 1), 4)}


if __name__ == "__main__":
    tables = ConfusionTables.load()
    sample = "阿莫西林胶囊 0.25g 每日两次 口服 7天"
    for band, target in (("light", 0.02), ("medium", 0.05), ("heavy", 0.10), ("extreme", 0.18)):
        cers, pairs = [], []
        for seed in range(200):
            noisy, meta = noisify_segment(sample, band=band, cer_target=target,
                                          rng=random.Random(seed), tables=tables)
            cers.append(meta["cer_measured"])
            pairs.append((sample, noisy))
        print(f"{band:8s} target={target:.2f} mean_cer={sum(cers)/len(cers):.4f} "
              f"span_damage={span_damage_stats(pairs)['rate']:.3f}")
