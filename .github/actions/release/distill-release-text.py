#!/usr/bin/env python3
"""发布文案蒸馏（确定性 × LLM → 逐段择优 + provenance；2026-10-09 业主指令）。

与 ASR 目录蒸馏（distill-asr-metadata.py）同范式：
- **确定性为真值底**：无 LLM 或 LLM 不可用时，发布页回落确定性动态段
  （事实行/统计/增量行——既有渲染面，绝不因 LLM 缺席而变差）。
- **LLM 只补散文段**：draft-release-text 的建议经**本模块独立复检**（三语
  齐全/长度闸/负清单——不与草拟器共享信任，同 ASR 蒸馏复检纪律）后逐
  语言采纳；未采纳语言 prose=null → 发布页该语言走确定性面。
- **全量 provenance**：decisions/rejected/leftOpen 台账（distill-report.json）。

模式：
  release-notes : --from-index <index.json>（payload 事实回显）+ --suggested
                  <draft 输出目录>（可缺）→ release-notes.final.json
                  {locales: {l: {prose: str|null, proseSource: llm|deterministic}}}
  readme-block  : --suggested <draft 输出目录> → readme-block.final.json
                  （逐块 lint 门:合法块采纳入册,非法块丢弃留痕;确定性面=
                  readme-sync 缺省,本模块不自造基线）

任何失败（缺 suggested/损坏）= 确定性面成稿（rc 0）;仅输出面 IO 错误 rc 1。
"""
import argparse
import json
import re
import runpy
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
COPY_TOOL = HERE / "apply-asr-catalog-copy.py"

LOCALES = ("zh-Hans", "zh-Hant", "en")
MAX_LOCALE_CHARS = 1600
BLOCK_FIELDS = ("id", "match", "displayName", "description")


class DistillTextError(Exception):
    pass


NUMBER_RE = re.compile(r"\d+(?:\.\d+)+")


def audit_numbers(prose, facts_blob):
    """数字对拍（report-only;委员会 2026-10-09 增量）：散文中的**版本型数字**
    （含小数点,如 1.0 / 0.6b 的 0.6）须能在事实集找到,否则记 suspicious
    ——防幻觉版本号进发布页;不拒绝（发布页可 PATCH;拒绝的误伤代价更高）。"""
    return sorted({token for token in NUMBER_RE.findall(prose or "")
                   if token not in facts_blob})


def load_banned_re():
    """负清单与投影器同源（防双写漂移;与 suggest-asr-metadata 同纪律）。"""
    return runpy.run_path(str(COPY_TOOL))["_BANNED_RE"]


def lint_prose(text, banned):
    """单语言散文复检;合法返回 None,否则错误说明。"""
    if not isinstance(text, str) or not text.strip():
        return "空文本"
    if len(text) > MAX_LOCALE_CHARS:
        return "超长（%d > %d）" % (len(text), MAX_LOCALE_CHARS)
    hit = banned.search(text)
    if hit:
        return "负清单命中 %r" % hit.group(0)
    return None


def load_optional(path):
    if path is not None and path.is_file():
        try:
            return json.loads(path.read_bytes())
        except (OSError, ValueError):
            return None
    return None


def distill_release_notes(payload, suggested_dir, banned):
    """逐语言择优。返回 (final_doc, report)。"""
    suggested = (load_optional((suggested_dir / "release-notes.json")
                               if suggested_dir else None) or {})
    locales_in = suggested.get("locale") or {}
    suggested_by = suggested.get("suggestedBy")
    facts_blob = json.dumps(payload, ensure_ascii=False)
    final_locales, decisions, rejected, suspicious = {}, [], [], []
    for locale in LOCALES:
        text = locales_in.get(locale)
        if suggested_by is None and text is None:
            decisions.append({"locale": locale, "proseSource": "deterministic",
                              "reason": "无建议（LLM 缺席/降级）"})
            final_locales[locale] = {"prose": None, "proseSource": "deterministic"}
            continue
        problem = lint_prose(text, banned)
        if problem:
            rejected.append({"locale": locale, "reason": problem,
                             "value": text if isinstance(text, str) else None})
            decisions.append({"locale": locale, "proseSource": "deterministic",
                              "reason": "复检驳回: " + problem})
            final_locales[locale] = {"prose": None, "proseSource": "deterministic"}
            continue
        decisions.append({"locale": locale, "proseSource": "llm",
                          "reason": "复检通过", "suggestedBy": suggested_by})
        final_locales[locale] = {"prose": text.strip(), "proseSource": "llm",
                                 "suspiciousNumbers": audit_numbers(text, facts_blob)}
        for token in final_locales[locale]["suspiciousNumbers"]:
            suspicious.append({"locale": locale, "token": token})
    final_doc = {
        "formatVersion": 1,
        "generatedFrom": {"suggested": str(suggested_dir) if suggested_dir else None,
                          "suggestedBy": suggested_by,
                          "payloadCatalogVersion": payload.get("catalogVersion"),
                          "payloadRootVersion": payload.get("rootVersion")},
        "locales": final_locales,
    }
    adopted = sum(1 for row in decisions if row["proseSource"] == "llm")
    report = {"formatVersion": 1, "mode": "release-notes",
              "counts": {"llmProse": adopted,
                         "deterministicProse": len(LOCALES) - adopted,
                         "rejected": len(rejected),
                         "suspiciousNumbers": len(suspicious)},
              "decisions": decisions, "rejected": rejected,
              "suspiciousNumbers": suspicious, "leftOpen": []}
    return final_doc, report


def distill_readme_block(suggested_dir, banned):
    """逐块择优：合法块（结构+负清单）入册;其余丢弃留痕（确定性面=缺省）。"""
    suggested = (load_optional((suggested_dir / "readme-block.suggested.json")
                               if suggested_dir else None) or {})
    intro = suggested.get("intro")
    rejected, blocks = [], []
    intro_problem = lint_prose(intro, banned) if intro is not None else "无建议"
    adopted_intro = None if intro_problem else intro.strip()
    if intro is not None and intro_problem:
        rejected.append({"where": "intro", "reason": intro_problem})
    for block in suggested.get("blocks") or []:
        if not isinstance(block, dict):
            rejected.append({"where": "block", "reason": "非对象"})
            continue
        missing = [f for f in BLOCK_FIELDS
                   if not isinstance(block.get(f), str) or not block[f].strip()]
        if missing:
            rejected.append({"where": str(block.get("id")) or "block",
                             "reason": "字段缺失: %s" % missing})
            continue
        hit = next((f for f in BLOCK_FIELDS if banned.search(block[f])), None)
        if hit:
            rejected.append({"where": block["id"], "reason": "负清单命中: %s" % hit})
            continue
        blocks.append({f: block[f].strip() for f in BLOCK_FIELDS})
    final_doc = {"formatVersion": 1,
                 "generatedFrom": {"suggested": str(suggested_dir)
                                   if suggested_dir else None,
                                   "suggestedBy": suggested.get("suggestedBy")},
                 "intro": adopted_intro, "blocks": blocks}
    total = (1 + len(suggested.get("blocks") or [])) if suggested else 0
    adopted = len(blocks) + (1 if adopted_intro else 0)
    report = {"formatVersion": 1, "mode": "readme-block",
              "counts": {"adopted": adopted,
                         "deterministic": max(0, total - adopted),
                         "rejected": len(rejected)},
              "decisions": ([{"where": "intro",
                              "source": "llm" if adopted_intro else "deterministic"}]
                            + [{"where": block["id"], "source": "llm"}
                               for block in blocks]),
              "rejected": rejected, "leftOpen": []}
    return final_doc, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("release-notes", "readme-block"),
                        required=True)
    parser.add_argument("--from-index", type=Path, default=None,
                        help="构建索引 index.json（release-notes 模式的事实源）")
    parser.add_argument("--facts", type=Path, default=None,
                        help="或直接给 facts JSON（release-notes 模式;二选一）")
    parser.add_argument("--suggested", type=Path, default=None,
                        help="draft-release-text 输出目录（可缺=纯确定性成稿）")
    parser.add_argument("--out", type=Path, required=True, help="蒸馏输出目录")
    args = parser.parse_args()
    try:
        banned = load_banned_re()
        if args.mode == "release-notes":
            payload = {}
            if args.from_index is not None:
                payload = json.loads(args.from_index.read_bytes())
            elif args.facts is not None:
                payload = json.loads(args.facts.read_bytes())
            final_doc, report = distill_release_notes(payload, args.suggested, banned)
            final_name, report_name = "release-notes.final.json", "distill-report.json"
        else:
            final_doc, report = distill_readme_block(args.suggested, banned)
            final_name, report_name = "readme-block.final.json", "distill-report.json"
        out = args.out
        out.mkdir(parents=True, exist_ok=True)
        (out / final_name).write_bytes(
            json.dumps(final_doc, ensure_ascii=False, indent=2).encode() + b"\n")
        (out / report_name).write_bytes(
            json.dumps(report, ensure_ascii=False, indent=2).encode() + b"\n")
        print("发布文案蒸馏完成（%s）: %s"
              % (args.mode, json.dumps(report["counts"], ensure_ascii=False)),
              flush=True)
        return 0
    except (DistillTextError, OSError, ValueError, KeyError, TypeError) as error:
        print("DISTILL-TEXT-ERROR: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
