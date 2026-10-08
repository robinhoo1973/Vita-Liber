#!/usr/bin/env python3
"""LLM 辅助草拟（旁路侧车；2026-10-08 业主指令 + 委员会三席定案）。

治理边界（全文见 ASR_RELEASE.md「LLM 辅助草拟（旁路）」节）：
- 建议只写 `suggested/*.suggested.json` 旁路，**主文件保持 REVIEW/三语空串
  骨架**——采纳 = 人工誊写 + 标记剥除；绝不整文件复制回仓（CI 不直写金样）。
- 只发**公开模型元数据**（上游 repo/文件名/公开许可文本）给 LLM；在线端点仅
  起草期人工增强，永不入 CI 链（发布链零 AI 裁决不变）。
- 内容寻址缓存（sha256(prompt‖model‖温度‖seed)）；文案建议先过与投影器
  **同源**的负清单预检，投影器仍为终闸。
- 引擎缺省本机 llama.cpp llama-server（OpenAI 兼容 /v1；仓内 0.5B GGUF 可
  复用）；`--endpoint` 可指任意兼容端点，密钥经环境变量（勿入仓）。

用法：
  python3 suggest-asr-metadata.py --candidates <asr-config-candidates 目录> \
      --out <输出目录> [--endpoint http://127.0.0.1:8080/v1] [--model local] \
      [--api-key-env LLM_API_KEY] [--temperature 0.2] [--cache <目录>]
"""
import argparse
import hashlib
import json
import os
import re
import runpy
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
COPY_TOOL = HERE / "apply-asr-catalog-copy.py"
CACHE_DEFAULT = Path.home() / ".cache" / "vitaliber-asr-suggest"


class SuggestError(Exception):
    pass


def load_banned_re():
    """负清单与投影器同源（防双写漂移）。"""
    module = runpy.run_path(str(COPY_TOOL))
    return module["_BANNED_RE"]


RETRYABLE_HTTP = (429, 500, 502, 503, 504)


def llm_chat(endpoint, model, prompt, *, api_key=None, temperature=0.2, timeout=180,
             retries=3, backoff=5.0, _sleep=time.sleep):
    """OpenAI 兼容 /v1/chat/completions（本机 llama-server 或任意在线兼容端点）。

    429/5xx 与网络抖动按指数退避重试（free 档限流为常态,run 37857357547 实证
    1305「访问量过大」——单次失败不得吞掉整批建议）。"""
    payload = json.dumps({"model": model,
                          "messages": [{"role": "user", "content": prompt}],
                          "temperature": temperature}).encode()
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = "Bearer " + api_key
    url = endpoint.rstrip("/") + "/chat/completions"
    attempts = max(1, retries + 1)
    for attempt in range(attempts):
        request = urllib.request.Request(url, data=payload, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = response.read(1 << 20)
                final_url = response.geturl()
        except urllib.error.HTTPError as error:
            detail = ""
            try:
                detail = error.read(300).decode("utf-8", "replace")
            except OSError:
                pass
            message = "HTTP %d（%s）: %s" % (error.code, error.geturl(), detail)
            if error.code in RETRYABLE_HTTP and attempt < attempts - 1:
                delay = backoff * (2 ** attempt)
                print("SUGGEST-RETRY: %s — %.0fs 后重试（%d/%d）"
                      % (message, delay, attempt + 1, retries), file=sys.stderr)
                _sleep(delay)
                continue
            raise SuggestError(message)
        except (OSError, ValueError) as error:
            if attempt < attempts - 1:
                delay = backoff * (2 ** attempt)
                print("SUGGEST-RETRY: 请求失败: %s — %.0fs 后重试（%d/%d）"
                      % (error, delay, attempt + 1, retries), file=sys.stderr)
                _sleep(delay)
                continue
            raise SuggestError("请求失败: %s" % error)
        try:
            document = json.loads(raw)
        except ValueError:
            # 诊断增强（2026-10-08 TEMP 实证:空/重定向响应曾只报
            # "Expecting value"——附最终 URL 与片段,直接暴露认证/重定向类问题）。
            raise SuggestError("非 JSON 响应（%d 字节,最终 URL=%s）: %s"
                               % (len(raw), final_url,
                                  raw[:300].decode("utf-8", "replace")))
        return document["choices"][0]["message"]["content"]
    raise SuggestError("重试耗尽")  # 不可达（循环内必 return/raise）


def parse_json_block(text):
    """取首个平衡的 {...} 块（小模型 JSON 稳定性容错;失败返回 None）。"""
    start = text.find("{")
    while start != -1:
        depth = 0
        for index in range(start, len(text)):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(text[start:index + 1])
                    except ValueError:
                        break
        start = text.find("{", start + 1)
    return None


def cache_key(prompt, model, temperature, seed=0):
    blob = json.dumps({"prompt": prompt, "model": model,
                       "temperature": temperature, "seed": seed},
                      ensure_ascii=False, sort_keys=True).encode()
    return hashlib.sha256(blob).hexdigest()


def cached_chat(chat, cache_dir, prompt, model, temperature):
    """内容寻址缓存（治理条款 5）:命中复用;未命中调用并落盘。"""
    key = cache_key(prompt, model, temperature)
    cache_dir = Path(cache_dir)
    entry = cache_dir / key
    if (entry / "output.txt").is_file():
        return (entry / "output.txt").read_text(encoding="utf-8"), key, True
    output = chat(prompt)
    entry.mkdir(parents=True, exist_ok=True)
    (entry / "output.txt").write_text(output, encoding="utf-8")
    (entry / "meta.json").write_text(json.dumps({
        "model": model, "temperature": temperature, "cacheKey": key,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return output, key, False


def license_prompt(entry):
    files = ", ".join(sorted(f.get("member", "?") for f in entry.get("files", [])))
    return ("You assist a model-registry maintainer. Given ONLY the public metadata "
            "below, propose an SPDX license candidate. Reply with a single JSON "
            "object: {\"license\": \"<SPDX-id or null>\", \"confidence\": <0-1>, "
            "\"reason\": \"<one sentence>\"}. Do not guess without basis.\n"
            "family: %s\nupstream repo: %s\nfiles: %s\ncurrent license field: %r"
            % (entry.get("id"), (entry.get("watch") or {}).get("repo"), files,
               entry.get("license")))


def prefix_prompt(entry):
    return ("You assist a model-registry maintainer. The version-policy prefix "
            "(part of derived version labels, e.g. \"int8\") is empty. Based on "
            "the public metadata, propose a short lowercase prefix or null. Reply "
            "JSON: {\"prefix\": \"<string or null>\", \"confidence\": <0-1>, "
            "\"reason\": \"<one sentence>\"}.\n"
            "family: %s\nupstream repo: %s" % (entry.get("id"),
                                               (entry.get("watch") or {}).get("repo")))


def copy_prompt(family_id, variant, files):
    return ("You draft short public-facing catalog copy for an on-device speech "
            "model (family: %s, tier: %s; files: %s). Reply JSON with three "
            "languages: {\"name\": {\"zh-Hans\": \"\", \"zh-Hant\": \"\", "
            "\"en\": \"\"}, \"hint\": {...}, \"strengths\": {...}, "
            "\"limitations\": {...}}. Facts only, no medical claims, no "
            "superlatives (no \"best/highest/fastest/guaranteed\")."
            % (family_id, variant or "-", files))


def collect_suggestions(candidates_dir, chat, cache_dir, model, temperature, banned,
                        max_seconds=0):
    """扫描候选文件 → 建议集（主文件只读）。返回 (entries, families, tiers, rejected, errors)。

    逐字段容错（run 37857357547 实证:free 档 429 曾一败全弃、前段成功结果全丢）——
    单字段失败记 errors 继续,部分成功照常落盘。max_seconds>0 时执行**总时限**
    （2026-10-09 实证:重试预算可超 job timeout——超限字段记 deadline 跳过,
    已得建议照常落盘,作业内必然结束）。"""
    errors = []
    deadline = None if not max_seconds else time.monotonic() + max_seconds

    def attempt(where, field, prompt):
        if deadline is not None and time.monotonic() >= deadline:
            errors.append({"where": where, "field": field, "error": "deadline exceeded"})
            return None
        try:
            output, key, cached = cached_chat(chat, cache_dir, prompt, model, temperature)
        except SuggestError as error:
            errors.append({"where": where, "field": field, "error": str(error)})
            return None
        return output, key, cached

    models = json.loads((candidates_dir / "models.json").read_bytes())
    copy_doc = json.loads((candidates_dir / "catalog-copy.json").read_bytes())
    entries = []
    for entry in models.get("models", []):
        suggestions = {}
        where = "%s/%s" % (entry.get("id"), entry.get("variant") or "-")
        needs_license = str(entry.get("license", "")).upper() in ("REVIEW", "")
        needs_prefix = not (entry.get("versionPolicy") or {}).get("prefix")
        if needs_license:
            result = attempt(where, "license", license_prompt(entry))
            if result:
                output, key, cached = result
                parsed = parse_json_block(output) or {}
                suggestions["license"] = {"value": parsed.get("license"),
                                          "confidence": parsed.get("confidence"),
                                          "reason": parsed.get("reason"),
                                          "cacheKey": key, "cached": cached,
                                          "raw": None if parsed else output[:400]}
        if needs_prefix:
            result = attempt(where, "versionPolicy.prefix", prefix_prompt(entry))
            if result:
                output, key, cached = result
                parsed = parse_json_block(output) or {}
                suggestions["versionPolicy.prefix"] = {
                    "value": parsed.get("prefix"), "confidence": parsed.get("confidence"),
                    "reason": parsed.get("reason"), "cacheKey": key, "cached": cached,
                    "raw": None if parsed else output[:400]}
        if suggestions:
            entries.append({"id": entry.get("id"), "variant": entry.get("variant"),
                            "suggestions": suggestions})
    families, tiers, rejected = [], [], []
    for family in copy_doc.get("families", []):
        missing = [field for field in ("name", "hint", "strengths", "limitations")
                   if not (family.get(field) or {}).get("zh-Hans")]
        if not missing:
            continue
        result = attempt("family:%s" % family.get("id"), "copy",
                         copy_prompt(family.get("id"), None, "family-level"))
        if result is None:
            continue
        output, key, cached = result
        parsed = parse_json_block(output) or {}
        suggestions = {}
        for field in missing:
            value = parsed.get(field)
            if not isinstance(value, dict):
                continue
            offending = [locale for locale, text in value.items()
                         if not isinstance(text, str) or not text.strip()
                         or banned.search(text)]
            if offending:
                # 负清单/空值预检不过 → 进 rejected（投影器仍为终闸）
                rejected.append({"where": "%s/%s" % (family.get("id"), field),
                                 "reason": "负清单或空值: %s" % offending})
                continue
            suggestions[field] = {"value": value, "cacheKey": key, "cached": cached}
        if suggestions:
            families.append({"id": family.get("id"), "suggestions": suggestions})
    for tier in copy_doc.get("tiers", []):
        missing = [field for field in ("tierName", "tierHint")
                   if not (tier.get(field) or {}).get("zh-Hans")]
        if not missing:
            continue
        where = "tier:%s/%s" % (tier.get("id"), tier.get("variant") or "-")
        result = attempt(where, "copy", copy_prompt(tier.get("id"), tier.get("variant"),
                                                    "tier-level"))
        if result is None:
            continue
        output, key, cached = result
        parsed = parse_json_block(output) or {}
        suggestions = {}
        for field in missing:
            value = parsed.get(field)
            if not isinstance(value, dict):
                continue
            offending = [locale for locale, text in value.items()
                         if not isinstance(text, str) or not text.strip()
                         or banned.search(text)]
            if offending:
                rejected.append({"where": "%s.%s/%s" % (tier.get("id"),
                                                        tier.get("variant"), field),
                                 "reason": "负清单或空值: %s" % offending})
                continue
            suggestions[field] = {"value": value, "cacheKey": key, "cached": cached}
        if suggestions:
            tiers.append({"id": tier.get("id"), "variant": tier.get("variant"),
                          "suggestions": suggestions})
    return entries, families, tiers, rejected, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidates", type=Path, required=True,
                        help="asr-config-candidates 目录（models.json/catalog-copy.json）")
    parser.add_argument("--out", type=Path, required=True, help="侧车输出目录")
    parser.add_argument("--endpoint", default="http://127.0.0.1:8080/v1",
                        help="OpenAI 兼容端点（缺省本机 llama-server）")
    parser.add_argument("--model", default="local")
    parser.add_argument("--api-key-env", default=None,
                        help="携带密钥的环境变量名（在线端点;密钥勿入仓）")
    parser.add_argument("--temperature", type=float, default=0.2)
    parser.add_argument("--max-seconds", type=float, default=0,
                        help="草拟总时限（秒;0=不限;超限字段记 deadline 跳过）")
    parser.add_argument("--cache", type=Path, default=CACHE_DEFAULT)
    args = parser.parse_args()
    try:
        banned = load_banned_re()
        api_key = os.environ.get(args.api_key_env) if args.api_key_env else None
        def chat(prompt):
            return llm_chat(args.endpoint, args.model, prompt,
                            api_key=api_key, temperature=args.temperature)
        entries, families, tiers, rejected, errors = collect_suggestions(
            args.candidates, chat, args.cache, args.model, args.temperature, banned,
            max_seconds=args.max_seconds)
        out = args.out
        out.mkdir(parents=True, exist_ok=True)
        suggested_by = "llm:%s@%s" % (args.endpoint, args.model)
        (out / "models.suggested.json").write_bytes(json.dumps({
            "formatVersion": 1, "suggestedBy": suggested_by, "entries": entries,
        }, ensure_ascii=False, indent=2).encode() + b"\n")
        (out / "catalog-copy.suggested.json").write_bytes(json.dumps({
            "formatVersion": 1, "suggestedBy": suggested_by,
            "families": families, "tiers": tiers, "rejected": rejected,
        }, ensure_ascii=False, indent=2).encode() + b"\n")
        # 恒写诊断文件（2026-10-08 run 37857357547 实证:全败时目录为空 →
        # 上传告警 → 下游 download「Artifact not found」error 注解;
        # 恒落盘后下游可据 errors.json 区分「限流降级」与「真无建议」）。
        (out / "errors.json").write_bytes(json.dumps({
            "formatVersion": 1, "suggestedBy": suggested_by, "errors": errors,
        }, ensure_ascii=False, indent=2).encode() + b"\n")
        (out / "README.txt").write_bytes((
            "LLM 辅助草拟（旁路侧车）。\n\n"
            "建议仅供参考:采纳 = 人工誊写入主文件并**剥除本目录标记**;\n"
            "绝不整文件复制回仓（主文件保持 REVIEW/骨架直至人工确认）。\n"
            "负清单预检与投影器同源;投影器仍为终闸。\n"
            "仅发送公开模型元数据（禁私仓/密钥/用户数据）。\n"
            "单字段失败（如 429 限流）记 errors.json 不中断批;"
            "重试=指数退避（429/5xx/网络）。\n"
            "suggestedBy=%s\n" % suggested_by).encode())
        print("建议已生成: models=%d 条目 / copy=家族 %d 档 %d（rejected %d / errors %d）"
              % (len(entries), len(families), len(tiers), len(rejected),
                 len(errors)), flush=True)
        if errors and not (entries or families or tiers):
            print("SUGGEST-ERROR: 全部字段失败（%d 条）——诊断见 errors.json"
                  % len(errors), file=sys.stderr)
            return 1
        return 0
    except (SuggestError, OSError, ValueError, KeyError, TypeError) as error:
        print("SUGGEST-ERROR: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
