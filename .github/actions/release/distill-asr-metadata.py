#!/usr/bin/env python3
"""蒸馏合并（候选 × LLM 建议 → 逐项择优终稿 + provenance 报告；2026-10-08 业主指令）。

口径：确定性生成为**真值底**（深探实测），LLM 建议只填空缺
（REVIEW / 空串 / 空 prefix），择优=逐字段取唯一在场来源并全量记录；
采纳前规范化（"null"/"none"/空等哨兵 → 无效，含模型误写的字符串化
null）、置信度阈值（--min-confidence）、与投影器同源的负清单复检。
输出为 **artifact 终稿候选**，不写回仓——金样采纳 = 人工 review 报告后
誊写（治理不变:CI 不直写金样,投影器仍为终闸）。

用法：
  python3 distill-asr-metadata.py --candidates <目录> [--suggested <目录>] \
      --out <目录> [--min-confidence 0.6]
"""
import argparse
import copy
import json
import runpy
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
COPY_TOOL = HERE / "apply-asr-catalog-copy.py"

SENTINELS = {"", "null", "none", "n/a", "nil", "undefined"}
LOCALES = ("zh-Hans", "zh-Hant", "en")
FAMILY_FIELDS = ("name", "hint", "strengths", "limitations")
TIER_FIELDS = ("tierName", "tierHint")


class DistillError(Exception):
    pass


def load_banned_re():
    """负清单与投影器同源（防双写漂移;与 suggest 同源加载）。"""
    return runpy.run_path(str(COPY_TOOL))["_BANNED_RE"]


def normalize(value):
    """哨兵字符串归一为 None（"null"/"none"/空等;非字符串原样返回交形态校验）。"""
    if not isinstance(value, str):
        return value
    text = value.strip()
    return None if text.lower() in SENTINELS else text


def deterministic_filled(value):
    """确定性标量在场口径：归一后非空且非 REVIEW。"""
    value = normalize(value)
    return bool(value) and str(value).upper() != "REVIEW"


def copy_filled(value):
    """三语文案在场口径：zh-Hans 非空（与 suggest 触发口径同源）。"""
    return isinstance(value, dict) and bool(str(value.get("zh-Hans") or "").strip())


def valid_copy_value(value, banned):
    """三语完整性 + 负清单复检;合法返回 None,否则返回错误说明。"""
    if not isinstance(value, dict):
        return "形态不符（非对象）"
    for locale in LOCALES:
        text = value.get(locale)
        if not isinstance(text, str) or not text.strip():
            return "缺 %s 或为空" % locale
        if banned.search(text):
            return "负清单命中: %s" % locale
    return None


def eligible(suggestion, min_confidence):
    """建议可用性：置信度门槛 + 哨兵归一。返回 (value|None, reason|None)。"""
    if not isinstance(suggestion, dict):
        return None, "无建议"
    confidence = suggestion.get("confidence")
    if isinstance(confidence, (int, float)) and confidence < min_confidence:
        return None, "置信度不足（%s < %s）" % (confidence, min_confidence)
    value = normalize(suggestion.get("value"))
    if value is None:
        return None, "建议值为空/哨兵（归一为 None）"
    return value, None


class Report:
    """provenance 台账：adopted（采纳/llm）/ shadowed（确定性在场,建议仅参考）/
    rejected（建议被驳回）/ leftOpen（两侧均缺）/ orphans（无对应条目的建议）。"""

    def __init__(self):
        self.adopted, self.shadowed, self.rejected = [], [], []
        self.left_open, self.orphans = [], []
        self.quarantined = []

    def adopt(self, where, field, value, confidence, suggested_by):
        self.adopted.append({"where": where, "field": field, "value": value,
                             "confidence": confidence, "source": "llm",
                             "suggestedBy": suggested_by})

    def shadow(self, where, field, deterministic, suggestion, confidence):
        self.shadowed.append({"where": where, "field": field,
                              "deterministic": deterministic,
                              "suggestion": normalize(suggestion.get("value")),
                              "confidence": confidence})

    def reject(self, where, field, reason, confidence=None, value=None):
        self.rejected.append({"where": where, "field": field, "reason": reason,
                              "confidence": confidence, "value": value})

    def leave_open(self, where, field, reason):
        self.left_open.append({"where": where, "field": field, "reason": reason})


def merge_scalar_field(entry, path, where, suggestions, min_confidence, banned,
                       report, suggested_by):
    """models 条目标量字段（license / versionPolicy.prefix）。"""
    field = ".".join(path)
    parent = entry
    for key in path[:-1]:
        if not isinstance(parent.get(key), dict):
            parent[key] = {}
        parent = parent[key]
    current = parent.get(path[-1])
    suggestion = suggestions.get(field)
    if deterministic_filled(current):
        if suggestion:
            report.shadow(where, field, normalize(current), suggestion,
                          suggestion.get("confidence"))
        return
    value, reason = eligible(suggestion, min_confidence)
    if value is None:
        if suggestion:
            report.reject(where, field, reason, suggestion.get("confidence"),
                          normalize(suggestion.get("value")))
        else:
            report.leave_open(where, field, "确定性空缺且无建议")
        return
    if not isinstance(value, str):
        report.reject(where, field, "形态不符（标量字段须字符串）",
                      suggestion.get("confidence"), value)
        return
    if banned.search(str(value)):
        report.reject(where, field, "负清单命中", suggestion.get("confidence"), value)
        return
    parent[path[-1]] = value
    report.adopt(where, field, value, suggestion.get("confidence"), suggested_by)


def merge_copy_field(container, field, where, suggestions, banned, report,
                     suggested_by):
    """文案容器字段（families[].{name,hint,…} / tiers[].{tierName,tierHint}）。"""
    current = container.get(field)
    suggestion = suggestions.get(field)
    if copy_filled(current):
        if suggestion:
            report.shadow(where, field, current, suggestion, None)
        return
    value, reason = eligible(suggestion, 0)
    if value is None:
        if suggestion:
            report.reject(where, field, reason, None, normalize(suggestion.get("value")))
        else:
            report.leave_open(where, field, "文案骨架空缺且无建议")
        return
    invalid = valid_copy_value(value, banned)
    if invalid:
        report.reject(where, field, invalid, None, value)
        return
    container[field] = value
    report.adopt(where, field, value, None, suggested_by)


def merge_models(candidates_doc, suggested_doc, min_confidence, banned, report,
                 suggested_by):
    merged = copy.deepcopy(candidates_doc)
    index = {}
    for entry in (suggested_doc or {}).get("entries", []):
        index[(entry.get("id"), entry.get("variant"))] = entry.get("suggestions") or {}
    seen = set()
    for entry in merged.get("models", []):
        key = (entry.get("id"), entry.get("variant"))
        seen.add(key)
        suggestions = index.get(key) or {}
        where = "%s/%s" % (key[0], key[1] or "-")
        merge_scalar_field(entry, ("license",), where, suggestions,
                           min_confidence, banned, report, suggested_by)
        merge_scalar_field(entry, ("versionPolicy", "prefix"), where, suggestions,
                           min_confidence, banned, report, suggested_by)
    for key, suggestions in index.items():
        if key not in seen and suggestions:
            report.orphans.append({"id": key[0], "variant": key[1],
                                   "fields": sorted(suggestions)})
    return merged


def merge_copy(candidates_doc, suggested_doc, min_confidence, banned, report,
               suggested_by):
    merged = copy.deepcopy(candidates_doc)
    doc = suggested_doc or {}
    families = {family.get("id"): family.get("suggestions") or {}
                for family in doc.get("families", [])}
    tiers = {(tier.get("id"), tier.get("variant")): tier.get("suggestions") or {}
             for tier in doc.get("tiers", [])}
    for family in merged.get("families", []):
        suggestions = families.get(family.get("id")) or {}
        for field in FAMILY_FIELDS:
            merge_copy_field(family, field, "family:%s" % family.get("id"),
                             suggestions, banned, report, suggested_by)
    for tier in merged.get("tiers", []):
        suggestions = tiers.get((tier.get("id"), tier.get("variant"))) or {}
        for field in TIER_FIELDS:
            merge_copy_field(tier, field, "tier:%s/%s" % (tier.get("id"),
                                                          tier.get("variant") or "-"),
                             suggestions, banned, report, suggested_by)
    return merged


def copy_complete(copy_doc, family_id, variant):
    """该档位文案三语齐备口径（家族 4 字段 + 档位 2 字段,全 locale 非空）。

    run 37868483691 实证:新档位骨架空串被投影器 fail-closed 拒,发布链
    红——入流闸=文案不齐的新档位隔离（留提案,补齐后自然入流）。"""
    family = next((f for f in copy_doc.get("families", [])
                   if f.get("id") == family_id), None)
    if family is None:
        return False
    for field in FAMILY_FIELDS:
        value = family.get(field) or {}
        if any(not str(value.get(locale) or "").strip() for locale in LOCALES):
            return False
    tier = next((t for t in copy_doc.get("tiers", [])
                 if t.get("id") == family_id and t.get("variant") == variant), None)
    if tier is None:
        return False
    for field in TIER_FIELDS:
        value = tier.get(field) or {}
        if any(not str(value.get(locale) or "").strip() for locale in LOCALES):
            return False
    return True


def quarantine_incomplete(copy_doc, models_doc, report):
    """文案不齐的新档位隔离出发布集（models 剔除 + 对应 copy 剔除 + 报告留痕）。

    隔离对象=发布集全体（base 与新增同判据）——在册条目文案向来齐备,等价
    于只隔离骨架新档位;判据不自造白名单,以文案完整性为唯一事实。"""
    kept, quarantined = [], []
    for model in models_doc.get("models", []):
        family_id = model.get("id")
        variant = model.get("variant")
        if copy_complete(copy_doc, family_id, variant):
            kept.append(model)
        else:
            quarantined.append({"id": family_id, "variant": variant,
                                "reason": "文案三语不齐（骨架空串,待 LLM/人工补齐后自动入流）"})
    models_doc["models"] = kept
    if quarantined:
        report.quarantined = quarantined
        kept_keys = {(m.get("id"), m.get("variant")) for m in kept}
        copy_doc["tiers"] = [t for t in copy_doc.get("tiers", [])
                             if (t.get("id"), t.get("variant")) in kept_keys]
        live_families = {m.get("id") for m in kept}
        copy_doc["families"] = [f for f in copy_doc.get("families", [])
                                if f.get("id") in live_families]


def load_optional(path):
    if path is not None and path.is_file():
        return json.loads(path.read_bytes())
    return None


def dump(path, document):
    path.write_bytes(json.dumps(document, ensure_ascii=False, indent=2).encode() + b"\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidates", type=Path, required=True,
                        help="候选目录（models.json/catalog-copy.json）")
    parser.add_argument("--suggested", type=Path, default=None,
                        help="LLM 建议侧车目录（缺失=纯确定性成稿）")
    parser.add_argument("--out", type=Path, required=True, help="蒸馏输出目录")
    parser.add_argument("--min-confidence", type=float, default=0.6)
    args = parser.parse_args()
    try:
        banned = load_banned_re()
        models_doc = json.loads((args.candidates / "models.json").read_bytes())
        copy_doc = json.loads((args.candidates / "catalog-copy.json").read_bytes())
        models_sugg = load_optional((args.suggested / "models.suggested.json")
                                    if args.suggested else None)
        copy_sugg = load_optional((args.suggested / "catalog-copy.suggested.json")
                                  if args.suggested else None)
        suggested_by = next((doc.get("suggestedBy") for doc in (models_sugg, copy_sugg)
                             if doc and doc.get("suggestedBy")), None)
        report = Report()
        merged_models = merge_models(models_doc, models_sugg, args.min_confidence,
                                     banned, report, suggested_by)
        merged_copy = merge_copy(copy_doc, copy_sugg, args.min_confidence,
                                 banned, report, suggested_by)
        quarantine_incomplete(merged_copy, merged_models, report)
        out = args.out
        out.mkdir(parents=True, exist_ok=True)
        dump(out / "models.json", merged_models)
        dump(out / "catalog-copy.json", merged_copy)
        dump(out / "distill-report.json", {
            "formatVersion": 1,
            "generatedFrom": {
                "candidates": str(args.candidates),
                "suggested": str(args.suggested) if args.suggested else None,
                "sidecarPresent": bool(models_sugg or copy_sugg),
                "minConfidence": args.min_confidence,
                "suggestedBy": suggested_by,
            },
            "counts": {"adopted": len(report.adopted), "shadowed": len(report.shadowed),
                       "rejected": len(report.rejected),
                       "leftOpen": len(report.left_open),
                       "orphans": len(report.orphans),
                       "quarantined": len(report.quarantined)},
            "adopted": report.adopted, "shadowed": report.shadowed,
            "rejected": report.rejected, "leftOpen": report.left_open,
            "orphans": report.orphans, "quarantined": report.quarantined,
        })
        (out / "README.txt").write_bytes((
            "蒸馏合并终稿（候选 × LLM 建议,逐项择优;2026-10-08）。\n\n"
            "规则：确定性生成为真值底（深探实测）,LLM 建议只填空缺"
            "（REVIEW/空串/空 prefix）;\n"
            "采纳经置信度阈值（--min-confidence）与负清单复检;"
            "「null」等哨兵字符串归一为无效。\n"
            "provenance 全量见 distill-report.json"
            "（adopted/shadowed/rejected/leftOpen/orphans）。\n"
            "本目录为 artifact 终稿候选,不写回仓;"
            "金样采纳=人工 review 后誊写,投影器仍为终闸。\n").encode())
        print("蒸馏完成: 采纳 %d / 确定性在场 %d / 驳回 %d / 遗留空缺 %d / 孤儿 %d"
              " / 隔离 %d"
              % (len(report.adopted), len(report.shadowed), len(report.rejected),
                 len(report.left_open), len(report.orphans),
                 len(report.quarantined)), flush=True)
        for row in report.quarantined:
            print("::warning::隔离（文案不齐,不入本轮发布）: %s/%s"
                  % (row["id"], row["variant"] or "-"), flush=True)
        return 0
    except (DistillError, OSError, ValueError, KeyError, TypeError) as error:
        print("DISTILL-ERROR: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
