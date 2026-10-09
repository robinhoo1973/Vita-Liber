#!/usr/bin/env python3
"""ASR 发布页正文渲染（永久头 + 动态段；委员会 S3 设计，2026-10-07）。

版式 = `cnb-release-notes/asr-models.md` 的永久头（三语，人工维护、创建时写入）
+ 本模块生成的「本次更新」动态段（简 → 繁 → 英）：

  - 版本三元组：目录版本 + 信任根版本 + 构建/签发时间（全部取自签名载荷，
    重跑同字节；时间绝不用墙钟）；
  - 家族 × 档位统计表：家族名 / 档位名 / 合计大小——文案零新增，全部来自
    签名载荷的三语字段（单一事实源）；
  - 增量行：与上一版签名载荷 diff（新增/更新/移除档位，以家族·档位名标示）。
    取不到上一版、或同一目录版本重跑 ⇒ 整行省略，绝不解释原因。

硬规则（业主 2026-10-07 与委员会口径）：动态段**不列文件名 / URL / 哈希**；
不出现任何数据来源；不出现失败 / 不可达一类措辞（禁用词由测试负样例钉住）。
"""

from asr_change_set import change_set

SECTION_HEADING = "## 本次更新 / 本次資料更新 / This update"
LANGUAGES = ("zh-Hans", "zh-Hant", "en")

_LABELS = {
    "zh-Hans": {
        "heading": "### 简体中文",
        "version_line": "目录版本: v%d（信任根版本: v%d）",
        "built_line": "构建时间: %s (UTC)",
        "issued_line": "签发时间: %s (UTC)",
        "stats_line": "家族与档位（%d 个家族 / %d 个档位）:",
        "family_header": "家族", "tiers_header": "档位", "size_header": "合计大小",
        "family_word": "个家族", "tier_word": "档位", "mw": "个",
        "delta_prefix": "**与上一版(v%d)相比**:",
        "added_word": "新增", "updated_word": "更新", "removed_word": "移除",
        "unchanged": "档位集合与内容无变化。",
        "sep": "、", "join": "；", "end": "。",
    },
    "zh-Hant": {
        "heading": "### 繁體中文",
        "version_line": "目錄版本: v%d（信任根版本: v%d）",
        "built_line": "構建時間: %s (UTC)",
        "issued_line": "簽發時間: %s (UTC)",
        "stats_line": "家族與檔位（%d 個家族 / %d 個檔位）:",
        "family_header": "家族", "tiers_header": "檔位", "size_header": "合計大小",
        "family_word": "個家族", "tier_word": "檔位", "mw": "個",
        "delta_prefix": "**與上一版(v%d)相比**:",
        "added_word": "新增", "updated_word": "更新", "removed_word": "移除",
        "unchanged": "檔位集合與內容無變化。",
        "sep": "、", "join": "；", "end": "。",
    },
    "en": {
        "heading": "### English",
        "version_line": "catalog version: v%d (trust root version: v%d)",
        "built_line": "built at: %s (UTC)",
        "issued_line": "signed at: %s (UTC)",
        "stats_line": "families and tiers (%d families / %d tiers):",
        "family_header": "Family", "tiers_header": "Tiers", "size_header": "Total size",
        "family_word": "families", "tier_word": "tiers", "mw": "",
        "delta_prefix": "**Compared with the previous release (v%d)**: ",
        "added_word": "added", "updated_word": "updated", "removed_word": "removed",
        "unchanged": "tier set and content unchanged.",
        "tier_word_singular": "tier",
        "sep": ", ", "join": "; ", "end": ".",
    },
}


def human_size(n):
    """字节数 → 人类可读（与 README 同步模块同算法，MiB/KiB 二进制）。"""
    for unit, step in (("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10)):
        if n >= step:
            text = f"{n / step:.1f}".rstrip("0").rstrip(".")
            return f"{text} {unit}"
    return f"{n} B"


def _text(node, language):
    return (node or {}).get(language) or ""


def _family_index(payload):
    index = (payload or {}).get("index") or {}
    return index.get("families") or [], index.get("models") or []


def _family_name_map(families, language):
    names = {}
    for family in families:
        names[family.get("id") or ""] = _text(family.get("name"), language) or (family.get("id") or "")
    return names


def _tier_display(model, language):
    return _text(model.get("tierName"), language) or (model.get("variant") or "")


def _tiers_by_family(models):
    grouped = {}
    order = []
    for model in models:
        family = model.get("id") or ""
        if family not in grouped:
            grouped[family] = []
            order.append(family)
        grouped[family].append(model)
    return grouped, order


def _render_stats(language, families, models):
    labels = _LABELS[language]
    grouped, order = _tiers_by_family(models)
    tier_count = sum(len(tiers) for tiers in grouped.values())
    names = _family_name_map(families, language)
    lines = [
        labels["stats_line"] % (len(order), tier_count),
        "",
        f"| {labels['family_header']} | {labels['tiers_header']} | {labels['size_header']} |",
        "|---|---|---:|",
    ]
    for family in order:
        tiers = grouped[family]
        tier_text = " / ".join(_tier_display(model, language) for model in tiers)
        total = sum(int(model.get("bytes") or 0) for model in tiers)
        lines.append(f"| {names.get(family) or family} | {tier_text} | {human_size(total)} |")
    return lines


def _delta_counts(previous, payload):
    """返回 (added, updated, removed) 或 None（无可比基线/同版本重跑=省略）。

    单源委托 `asr_change_set.change_set`（2026-10-08 委员会终裁：发布页与
    overview changes 块共用同一增量语义——禁止同语义双实现漂移）。
    """
    return change_set(previous, payload)


def _delta_line(language, previous, payload, families):
    labels = _LABELS[language]
    counts = _delta_counts(previous, payload)
    if counts is None:
        return ""
    added, updated, removed = counts
    prefix = labels["delta_prefix"] % int(previous.get("catalogVersion") or 0)
    if not added and not updated and not removed:
        return prefix + labels["unchanged"]
    names = _family_name_map(families, language)
    # 移除条目来自上一版载荷，而家族显示名表此前只用当前版构建 → 移除行回退原始 id
    # （2026-10-07 评审实证：`moonshine·极轻` 应为家族显示名·档位名）。并入上一版
    # 家族名表（当前版同名优先），移除行与新增/更新行同样输出显示名。
    previous_families, _ = _family_index(previous)
    if previous_families:
        names = {**_family_name_map(previous_families, language), **names}
    parts = []
    for models, word in ((added, labels["added_word"]),
                         (updated, labels["updated_word"]),
                         (removed, labels["removed_word"])):
        if not models:
            continue
        items = labels["sep"].join(
            f"{names.get(model.get('id') or '') or (model.get('id') or '')}·{_tier_display(model, language)}"
            for model in models)
        if language == "en":
            tier_word = labels.get("tier_word_singular", labels["tier_word"]) if len(models) == 1 else labels["tier_word"]
            parts.append(f"{len(models)} {tier_word} {word} ({items})")
        else:
            parts.append(f"{word} {len(models)} {labels['mw']}{labels['tier_word']}（{items}）")
    return prefix + labels["join"].join(parts) + labels["end"]


def render_release_body(permanent_body, payload, previous_payload=None, notes=None):
    """永久头 + 动态段（简 → 繁 → 英），确定性输出（同输入=同字节）。

    notes（{locale: 文本},可选,2026-10-09 发布文案接线）:LLM 草拟的「本次更新」
    散文段——插在各语言版本事实行之后、统计之前;None/缺该语言 = 确定性面不变。"""
    families, models = _family_index(payload)
    index = (payload or {}).get("index") or {}
    parts = [permanent_body.strip("\n"), "", SECTION_HEADING, ""]
    for language in LANGUAGES:
        labels = _LABELS[language]
        parts.append(labels["heading"])
        parts.append("")
        parts.append("- " + labels["version_line"] % (
            int(payload.get("catalogVersion") or 0), int(payload.get("rootVersion") or 0)))
        built = (index.get("updatedAt") or "").strip()
        if built:
            parts.append("- " + labels["built_line"] % built)
        issued = (payload.get("issuedAt") or "").strip()
        if issued:
            parts.append("- " + labels["issued_line"] % issued)
        prose = (notes or {}).get(language)
        if isinstance(prose, str) and prose.strip():
            parts.append("")
            parts.append(prose.strip())
        parts.append("")
        parts.extend(_render_stats(language, families, models))
        delta = _delta_line(language, previous_payload, payload, families)
        if delta:
            parts.append("")
            parts.append(delta)
        parts.append("")
    return "\n".join(parts).rstrip("\n") + "\n"
