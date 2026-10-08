#!/usr/bin/env python3
"""发布文本草拟（2026-10-09 业主指令；LLM 模块化 release/llm_client.py 的首批消费者）。

用途（非阻塞侧车；治理同 ASR ④，全文见 ASR_RELEASE.md「LLM 辅助草拟」节）：
  --mode release-notes : 由公开事实（facts JSON）草拟 Release 变更说明（三语 markdown）
  --mode readme-block  : 由公开事实草拟 readme-sync sections.json 的分节文案（intro+blocks）

facts JSON（只允许公开内容）：
  {"tag": "llama-models", "repository": "robinhoo1973/Resources",
   "assets": [{"name": "<资产名>", "size": <字节>}],
   "previousNotes": "<上一版说明,可选>", "extraFacts": "<补充事实串,可选>"}

输出（**只写 --out 目录**；绝不触碰权威模板 cnb-release-notes/*.md 与
readme-sync sections.json——采纳 = 人工誊写）：
  release-notes.suggested.md / readme-block.suggested.json
  meta.json（suggestedBy/factsSha256/cacheKey/cached）
  errors.json（失败/负清单拒绝台账）

用法：
  python3 draft-release-text.py --mode release-notes --facts facts.json --out /tmp/draft \
      --endpoint https://open.bigmodel.cn/api/paas/v4 --model glm-4.7-flash \
      --api-key-env LLM_API_KEY
"""
import argparse
import hashlib
import json
import runpy
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
COPY_TOOL = HERE / "apply-asr-catalog-copy.py"
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from llm_client import (  # noqa: E402
    LLMError, cached_chat, default_cache_dir, make_chat, parse_json_block,
)

LOCALES = ("zh-Hans", "zh-Hant", "en")
SECTION_HEADING = "## 本次更新 / 本次資料更新 / This update"
_LANG_HEADINGS = {"zh-Hans": "### 简体中文", "zh-Hant": "### 繁體中文",
                  "en": "### English"}


def load_banned_re():
    """负清单与投影器同源（防双写漂移；同 suggest-asr-metadata 纪律）。"""
    module = runpy.run_path(str(COPY_TOOL))
    return module["_BANNED_RE"]


def _facts_lines(facts):
    assets = facts.get("assets") or []
    listing = "\n".join("- %s (%d bytes)" % (a.get("name"), a.get("size") or 0)
                        for a in assets) or "(none listed)"
    previous = (facts.get("previousNotes") or "").strip() or "(none)"
    extra = (facts.get("extraFacts") or "").strip() or "(none)"
    return listing, previous, extra


def build_release_notes_prompt(facts):
    listing, previous, extra = _facts_lines(facts)
    return ("You draft the public \"this update\" text for a release page of a software "
            "resource repository.\n"
            "Tag: %s\nRepository: %s\nAssets in this release:\n%s\n"
            "Previous release notes (context only):\n%s\nAdditional facts:\n%s\n"
            "Reply with a single JSON object with exactly three keys: \"zh-Hans\", "
            "\"zh-Hant\", \"en\". Each value is the full body text in that language: "
            "2-4 short paragraphs of markdown or a short bullet list. Rules: state only "
            "facts present above; no superlatives (no \"best\", \"fastest\", "
            "\"guaranteed\"); no medical or health claims; do not list file names, URLs "
            "or hashes; do not mention failures, delays or unavailable items; do not "
            "invent version numbers or dates."
            % (facts.get("tag"), facts.get("repository"), listing, previous, extra))


def build_readme_block_prompt(facts):
    listing, previous, extra = _facts_lines(facts)
    return ("You maintain the README of a resource repository. Propose the human "
            "section text for one release tag based on its asset file names.\n"
            "Tag: %s\nAssets:\n%s\nAdditional facts:\n%s\n"
            "Reply with a single JSON object: {\"intro\": \"<one-sentence section "
            "intro in Simplified Chinese>\", \"blocks\": [{\"id\": \"<stable "
            "lowercase id>\", \"match\": \"<exact file name or file-name prefix>\", "
            "\"displayName\": \"<short name>\", \"description\": \"<one-line "
            "description in Simplified Chinese>\"}]}. Group assets by family; "
            "each match must select only that family. Facts only; no superlatives; "
            "no medical claims."
            % (facts.get("tag"), listing, extra))


def render_release_notes(doc):
    parts = [SECTION_HEADING]
    for locale in LOCALES:
        parts.append(_LANG_HEADINGS[locale])
        parts.append(doc[locale].strip())
    return "\n\n".join(parts) + "\n"


def _offending(text, banned):
    match = banned.search(text)
    return match.group(0) if match else None


def draft_release_notes(facts, chat, cache_dir, model, temperature, banned):
    """→ {"markdown", "cacheKey", "cached"} 或 {"error", "raw"?}。"""
    prompt = build_release_notes_prompt(facts)
    try:
        output, key, cached = cached_chat(chat, cache_dir, prompt, model, temperature)
    except LLMError as error:
        return {"error": str(error)}
    doc = parse_json_block(output)
    if not isinstance(doc, dict) or set(doc.keys()) != set(LOCALES):
        return {"error": "非三语 JSON 对象", "raw": output[:400], "cacheKey": key}
    for locale in LOCALES:
        text = doc.get(locale)
        if not isinstance(text, str) or not text.strip():
            return {"error": "缺 %s 文案" % locale, "cacheKey": key}
        hit = _offending(text, banned)
        if hit:
            return {"error": "负清单命中 %r（%s）" % (hit, locale), "cacheKey": key}
    return {"markdown": render_release_notes(doc), "cacheKey": key, "cached": cached}


def draft_readme_block(facts, chat, cache_dir, model, temperature, banned):
    """→ {"doc", "cacheKey", "cached", "rejected": [...]} 或 {"error", ...}。"""
    prompt = build_readme_block_prompt(facts)
    try:
        output, key, cached = cached_chat(chat, cache_dir, prompt, model, temperature)
    except LLMError as error:
        return {"error": str(error)}
    parsed = parse_json_block(output)
    if not isinstance(parsed, dict):
        return {"error": "非 JSON 对象", "raw": output[:400], "cacheKey": key}
    rejected = []
    intro = parsed.get("intro")
    if not isinstance(intro, str) or not intro.strip():
        return {"error": "缺 intro", "cacheKey": key}
    hit = _offending(intro, banned)
    if hit:
        return {"error": "intro 负清单命中 %r" % hit, "cacheKey": key}
    blocks = []
    for block in parsed.get("blocks") or []:
        if not isinstance(block, dict):
            continue
        fields = {k: block.get(k) for k in ("id", "match", "displayName", "description")}
        if not all(isinstance(v, str) and v.strip() for v in fields.values()):
            rejected.append({"block": block, "reason": "字段缺失或非字符串"})
            continue
        bad = [k for k, v in fields.items() if _offending(v, banned)]
        if bad:
            rejected.append({"block": block, "reason": "负清单命中: %s" % bad})
            continue
        blocks.append(fields)
    doc = {"intro": intro, "blocks": blocks}
    return {"doc": doc, "cacheKey": key, "cached": cached, "rejected": rejected}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("release-notes", "readme-block"), required=True)
    parser.add_argument("--facts", type=Path, required=True, help="公开事实 JSON")
    parser.add_argument("--out", type=Path, required=True, help="草稿输出目录（只写这里）")
    parser.add_argument("--endpoint", default="http://127.0.0.1:8080/v1",
                        help="OpenAI 兼容端点（缺省本机 llama-server）")
    parser.add_argument("--model", default="local")
    parser.add_argument("--api-key-env", default=None,
                        help="携带密钥的环境变量名（在线端点;密钥勿入仓）")
    parser.add_argument("--temperature", type=float, default=0.2)
    parser.add_argument("--cache", type=Path, default=default_cache_dir("release-text"))
    args = parser.parse_args()

    facts_bytes = args.facts.read_bytes()
    facts = json.loads(facts_bytes)
    banned = load_banned_re()
    chat = make_chat(args.endpoint, args.model,
                     api_key_env=args.api_key_env, temperature=args.temperature)

    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    draft = (draft_release_notes(facts, chat, args.cache, args.model,
                                 args.temperature, banned)
             if args.mode == "release-notes"
             else draft_readme_block(facts, chat, args.cache, args.model,
                                     args.temperature, banned))
    errors = []
    if "error" in draft:
        errors.append({"mode": args.mode, **draft})
    else:
        target = (out / "release-notes.suggested.md" if args.mode == "release-notes"
                  else out / "readme-block.suggested.json")
        if args.mode == "release-notes":
            target.write_text(draft["markdown"], encoding="utf-8")
        else:
            payload = {"formatVersion": 1,
                       "suggestedBy": "llm:%s@%s" % (args.endpoint, args.model),
                       **draft["doc"]}
            target.write_bytes(json.dumps(payload, ensure_ascii=False,
                                          indent=2).encode() + b"\n")
            errors.extend(draft.get("rejected") or [])
        (out / "meta.json").write_bytes(json.dumps({
            "mode": args.mode,
            "suggestedBy": "llm:%s@%s" % (args.endpoint, args.model),
            "factsSha256": hashlib.sha256(facts_bytes).hexdigest(),
            "cacheKey": draft.get("cacheKey"), "cached": draft.get("cached"),
        }, ensure_ascii=False, indent=2).encode() + b"\n")
        print("draft written:", target)
    (out / "errors.json").write_bytes(json.dumps(
        {"formatVersion": 1, "errors": errors}, ensure_ascii=False,
        indent=2).encode() + b"\n")
    if "error" in draft:
        print("DRAFT-FAILED: %s" % draft["error"], file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
