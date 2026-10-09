#!/usr/bin/env python3
"""LLM 客户端共享模块（2026-10-09 业主指令：LLM 独立成模块）。

来源 = ASR ④「LLM 辅助草拟」批（2026-10-08/09）通用内核的逐字抽取
（llm_chat/cache_key/cached_chat/parse_json_block 行为不变）。支持 OpenAI 兼容
/v1/chat/completions：智谱 GLM-4.7-Flash 免费档、本机 llama.cpp llama-server、
任意兼容端点。

治理（全文见 ASR_RELEASE.md「LLM 辅助草拟」节；所有消费者同受约束）：
1. 只发**公开元数据**；密钥经环境变量（勿入仓）；
2. 输出 = 建议/草稿侧车，**绝不直写权威文件**（金样/模板/sections.json 须人工采纳）；
3. 内容寻址缓存 sha256(prompt‖model‖temperature‖seed)——同输入同输出字节；
4. 在线端点仅起草期；发布链零 AI 裁决。

消费者：suggest-asr-metadata.py（ASR 目录草拟）、draft-release-text.py
（README 分节文案 / Release 变更说明草稿）。
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

RETRYABLE_HTTP = (429, 500, 502, 503, 504)


class LLMError(Exception):
    pass


class LLMQuotaExhausted(LLMError):
    """配额耗尽（非瞬时;不重试,批级应立即断流降级）。

    run 37860771905 实证:免费档日配额用尽（429 code 1302「调用次数已达
    上限」）时逐字段重试×3 纯浪费——重试只对**瞬时拥塞**（1305「访问量
    过大」）有意义。"""
    pass


def _is_quota_exhausted(body):
    lowered = (body or "").lower()
    return ("1302" in lowered or "调用次数已达上限" in (body or "")
            or "quota" in lowered or "余额不足" in (body or "")
            or "insufficient" in lowered)


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
            if _is_quota_exhausted(detail):
                # 配额耗尽 = 非瞬时,重试无意义（业主 2026-10-09:须处理免费
                # 用完场景）——立即上抛,由消费者断流降级。
                raise LLMQuotaExhausted(message)
            if error.code in RETRYABLE_HTTP and attempt < attempts - 1:
                delay = backoff * (2 ** attempt)
                print("SUGGEST-RETRY: %s — %.0fs 后重试（%d/%d）"
                      % (message, delay, attempt + 1, retries), file=sys.stderr)
                _sleep(delay)
                continue
            raise LLMError(message)
        except (OSError, ValueError) as error:
            if attempt < attempts - 1:
                delay = backoff * (2 ** attempt)
                print("SUGGEST-RETRY: 请求失败: %s — %.0fs 后重试（%d/%d）"
                      % (error, delay, attempt + 1, retries), file=sys.stderr)
                _sleep(delay)
                continue
            raise LLMError("请求失败: %s" % error)
        try:
            document = json.loads(raw)
        except ValueError:
            # 诊断增强（2026-10-08 TEMP 实证:空/重定向响应曾只报
            # "Expecting value"——附最终 URL 与片段,直接暴露认证/重定向类问题）。
            raise LLMError("非 JSON 响应（%d 字节,最终 URL=%s）: %s"
                           % (len(raw), final_url,
                              raw[:300].decode("utf-8", "replace")))
        return document["choices"][0]["message"]["content"]
    raise LLMError("重试耗尽")  # 不可达（循环内必 return/raise）


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
    """内容寻址缓存（治理条款 3）:命中复用;未命中调用并落盘。"""
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


def default_cache_dir(slug):
    """消费者缓存目录约定：~/.cache/vitaliber-<slug>（CI 内由 actions/cache 承接）。"""
    return Path.home() / ".cache" / ("vitaliber-" + slug)


def make_chat(endpoint, model, *, api_key_env=None, temperature=0.2,
              timeout=180, retries=3, backoff=5.0):
    """构造消费者用的 chat(prompt) 闭包;密钥经环境变量名注入。

    调用标准（全文见 ASR_RELEASE.md「LLM 客户端调用标准」节）:一切 HTTP/LM
    调用必须经本模块;超时/重试/退避参数透传,消费者只负责批级策略
    （逐字段容错、总时限、错误台账）。"""
    api_key = os.environ.get(api_key_env) if api_key_env else None
    def chat(prompt):
        return llm_chat(endpoint, model, prompt, api_key=api_key,
                        temperature=temperature, timeout=timeout,
                        retries=retries, backoff=backoff)
    return chat
