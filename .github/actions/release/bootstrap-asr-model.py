#!/usr/bin/env python3
"""Bootstrap ASR model config entries from model names (discovery → probe → draft).

业主 2026-10-08 目标：「我只需要给出几个模型的名称就可以启动」——models.json /
catalog-copy.json 的候选内容由搜索抓取生成，人工过目一次后合并，其后全自动
（resolver 追新 → 投影 → 发布）。本工具=**本地/离线工具**；CI 不运行、零 AI 依赖。

发现层（免费、确定、无限额——官方结构化 API 优先，通用搜索引擎仅人工补充）：
- hf-repo        ：HF `/api/models?search=` 按名检索（可限作者域）→ 候选镜像仓；
- github-release ：`k2-fsa/sherpa-onnx` releases 资产名匹配 → 候选归档。
探针层：**下载实测** bytes/sha256（钉版纪律：Xet CAS 块哈希不可用），按成员名
推断角色（preprocess/encode/uncached_decode/…）；许可由 LICENSE 成员内容启发式。
对账层（--compare-config，逆测模式）：draft 逐字段对现有条目比对——证明
「从名字可复得人工钉版」；差异分「实质（哈希/成员集/revision）」与「外观
（路径约定/文案占位）」。

输出：draft JSON（models.json 条目候选 + copy 骨架 + 对账报告）。
"""
import argparse
import copy
import fnmatch
import hashlib
import json
import os
import re
import socket
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

from asr_constants import MODELS, VARIANTS

# 本机 IPv6 路由对部分 CDN 为黑洞：urllib 无 Happy Eyeballs，会卡死在
# IPv6 SYN-SENT（2026-10-08 实证：HF 直连下载僵死 5 分钟，curl 同 URL 1 秒）。
# 统一优先 IPv4（CI runner 通常仅 IPv4，等价无副作用）。
_ORIGINAL_GETADDRINFO = socket.getaddrinfo


def _ipv4_first(*args, **kwargs):
    answers = _ORIGINAL_GETADDRINFO(*args, **kwargs)
    return [answer for answer in answers if answer[0] == socket.AF_INET] or answers


socket.getaddrinfo = _ipv4_first

# 传输面与 resolver 同构（内联实现；本工具仅本地/离线运行，不参与 CI）。

# 家族级约定（上游 source、versionPolicy 前缀、path 目录）不写死在代码里：
# 对账模式经 apply_template 从既有条目继承（单一事实源=config），无模板落 REVIEW。
REVIEW = "REVIEW"
# .weights/.pt 等=训练格式载荷（非 ONNX，运行时不可用）——2026-10-08 iOS 产品席
# 实证：whisper turbo/large 仓的 turbo-encoder.weights 被 encoder 规则误收进 draft。
SKIP_PATTERNS = (".gitattributes", "test_wavs/*", "*.wav", "*trans.txt", ".git/*",
                 "*.weights", "*.pt", "*.pth", "*.ckpt")
# 角色推断 = 有序正则（search 式；前缀 glob 对 whisper 系带档位前缀的成员名
# 如 tiny-encoder.int8.onnx 全数失配——2026-10-08 实证修复）。notice 规则置前
# （防 MODEL_LICENSE 被 model 规则误吞；IGNORECASE 下依赖顺序保证正确性）。
ROLE_RULES = (
    (r"^MODEL_LICENSE", "notice"),
    (r"^LICENSE", "notice"),
    (r"uncached[_-]?decode", "uncachedDecoder"),
    (r"cached[_-]?decode", "cachedDecoder"),
    (r"preprocess", "preprocessor"),
    (r"conv[_-]?frontend", "frontend"),
    (r"encoder?", "encoder"),
    (r"decoder?", "decoder"),
    (r"joiner", "joiner"),
    (r"(^|[-_/])model[\._-]", "model"),
    (r"tokens\.txt$", "tokens"),
    (r"bpe\.vocab$", "bpe"),
    (r"vocab\.json$", "vocab"),
    (r"merges\.txt$", "merges"),
    (r"tokenizer_config\.json$", "tokenizerConfig"),
    (r"^README\.md$", "notice"),
)


class BootstrapError(Exception):
    pass


def _request_json(url, *, fetch_json=None, attempts=3):
    if fetch_json is not None:
        try:
            return fetch_json(url)
        except (OSError, ValueError) as error:
            raise BootstrapError("fetch failed: %s (%s)" % (url, error))
    headers = {"User-Agent": "vitaliber-asr-bootstrap/1"}
    # GITHUB_TOKEN 存在时注入 GitHub API 域（只增限额,不改语义）——匿名共享
    # runner IP 极易 403 rate limit（2026-10-08 push 自动 run 实证:qwen3
    # releases 查询被限流致 inventory unknown）。与 resolve-asr-models 同构。
    token = os.environ.get("GITHUB_TOKEN", "")
    if token and url.startswith("https://api.github.com/"):
        headers["Authorization"] = "Bearer " + token
    last = None
    for attempt in range(attempts):
        try:
            request = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.loads(response.read(8 << 20))
        except (OSError, ValueError) as error:
            last = error
            if attempt < attempts - 1:
                time.sleep(2 * (attempt + 1))
    raise BootstrapError("fetch failed: %s (%s)" % (url, last))


def _download_once(url, destination):
    headers = {"User-Agent": "vitaliber-asr-bootstrap/1"}
    request = urllib.request.Request(url, headers=headers)
    digest = hashlib.sha256()
    received = 0
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(request, timeout=600) as response:
        # 完整性校验（2026-10-08 run 37741139452 实证:连接悄断时 read 直接
        # EOF,半截文件被当作完整——probe 报出 144MB vs 金样 374MB 的假
        # mismatch）。有 Content-Length 时收流后必核;不符抛 OSError 走
        # 重试/报错路径,绝不把截断字节当事实。
        expected = response.headers.get("Content-Length")
        expected = int(expected) if expected and expected.isdigit() else None
        with destination.open("wb") as target:
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                received += len(chunk)
                digest.update(chunk)
                target.write(chunk)
    if expected is not None and received != expected:
        raise OSError("download truncated: %d/%d bytes" % (received, expected))
    return received, digest.hexdigest()


def _download(url, destination, attempts=3):
    """单文件重试（2026-10-08 实证：本机链路 TLS 瞬断 UNEXPECTED_EOF 需退避重试）。"""
    last = None
    for attempt in range(attempts):
        try:
            return _download_once(url, destination)
        except OSError as error:
            last = error
            Path(destination).unlink(missing_ok=True)
            if attempt < attempts - 1:
                time.sleep(2 * (attempt + 1))
    raise BootstrapError("download failed: %s (%s)" % (url, last))


def search_hf(name, author=None, limit=10, *, fetch_json=None):
    def query(term):
        url = "https://huggingface.co/api/models?search=" + urllib.parse.quote(term, safe="")
        if author:
            url += "&author=" + author
        url += "&limit=%d" % limit
        result = _request_json(url, fetch_json=fetch_json)
        return [entry.get("id") for entry in result if entry.get("id")]
    hits = query(name)
    if not hits and " " in name:
        hits = query(name.replace(" ", "-"))
    return hits


def fetch_repo(repo, *, fetch_json=None):
    info = _request_json("https://huggingface.co/api/models/" + repo, fetch_json=fetch_json)
    sha = info.get("sha") or ""
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise BootstrapError("repo has no resolvable revision: " + repo)
    members = [(s or {}).get("rfilename") for s in info.get("siblings") or []]
    return sha, [m for m in members if m]


def member_selected(member):
    if any(fnmatch.fnmatch(member, pattern) for pattern in SKIP_PATTERNS):
        return False
    return infer_role(member) is not None


def infer_role(member):
    base = member.rsplit("/", 1)[-1]
    for pattern, role in ROLE_RULES:
        if re.search(pattern, base, re.IGNORECASE):
            return role
    return None


def infer_identity(repo):
    """镜像仓名 → (family, variant)；variant 令牌扫描，无法判定时 None（供人审）。

    家族=**词边界子串**匹配（最长优先）——同时覆盖：
    - 单词家族在中段：streaming-zipformer-… → zipformer；
    - 连字家族（sense-voice / fire-red）：整段边界匹配（2026-10-08 实测：拆词
      扫描会让两家族全数失配、钉版仓库被判"缺失"）。
    例：whisper-turbo → (whisper, turbo)；moonshine-tiny-en-int8 → (moonshine, tiny)；
        sense-voice-zh-en-ja-ko-yue-2024-07-17 → (sense-voice, None)（人审补档位）。
    """
    tail = repo.split("/")[-1]
    tail = re.sub(r"^sherpa-onnx-", "", tail)
    for family in sorted(MODELS, key=len, reverse=True):
        match = re.search(r"(^|[-_/])" + re.escape(family) + r"($|[-_/])", tail)
        if match is None:
            continue
        remainder = tail[match.end():]
        tokens = remainder.replace("_", "-").split("-")
        variant = next((token for token in tokens if token in VARIANTS), None)
        return family, variant
    raise BootstrapError("cannot infer family from repo name: " + repo)


def infer_license(license_texts):
    joined = "\n".join(license_texts)
    if "MIT License" in joined or "Permission is hereby granted, free of charge" in joined:
        return "MIT"
    if "Apache License" in joined and "Version 2.0" in joined:
        return "Apache-2.0"
    return None


def prefer_license_notice(files):
    """notice 选择精化（逆测实证 2026-10-08）：有 LICENSE/MODEL_LICENSE 类成员时
    弃 README.md 兜底——许可文本是必需署名，README 存根只增噪（人工钉版同判）。

    多许可类成员并存时择一（verify 首跑实证,2026-10-08）：MODEL_LICENSE（模型
    专属许可）优先于 LICENSE（仓级）——上游 sense-voice 仓同存两件，人工钉版取
    MODEL_LICENSE；whisper 等仅单件的家族不受影响（择一后集不变）。"""
    def base_name(member):
        return member.rsplit("/", 1)[-1].upper()
    def is_license(member):
        return base_name(member).startswith(("LICENSE", "MODEL_LICENSE"))
    def is_model_license(member):
        return base_name(member).startswith("MODEL_LICENSE")
    licenses = [f for f in files if f["role"] == "notice" and is_license(f["member"])]
    if not licenses:
        return files
    keep = [f for f in licenses if is_model_license(f["member"])] or licenses
    keep_ids = {id(f) for f in keep}
    return [f for f in files if f["role"] != "notice" or id(f) in keep_ids]


def select_quantized_members(members):
    """同基名的 .onnx 量化孪生只留移动端优先形态：int8 > fp16 > fp32。

    2026-10-08 全量深探对账实证：whisper 镜像仓同时含 fp32 与 int8 导出，全收
    会让 draft 与在册约定（versionPolicy.prefix=int8，iOS 部署惯例）失配；
    非 onnx 成员（tokens/bpe/notice 等）原样透传，不同基名不合并。
    """
    def group_key(member):
        base = member.rsplit("/", 1)[-1].lower()
        if not base.endswith(".onnx") or infer_role(member) is None:
            return None
        return re.sub(r"\.(int8|fp16)(?=\.onnx$)", "", base)

    def level(member):
        base = member.rsplit("/", 1)[-1].lower()
        return 0 if ".int8." in base else (1 if ".fp16." in base else 2)

    chosen = {}
    for member in members:
        group = group_key(member)
        if group is None:
            continue
        if group not in chosen or level(member) < level(chosen[group]):
            chosen[group] = member
    picked = set(chosen.values())
    return [m for m in members if group_key(m) is None or m in picked]


def probe_repo(repo, *, workdir, fetch_json=None):
    sha, members = fetch_repo(repo, fetch_json=fetch_json)
    family, variant = infer_identity(repo)
    files, license_texts = [], []
    for member in select_quantized_members(members):
        role = infer_role(member)
        if role is None or not member_selected(member):
            continue
        url = "https://huggingface.co/%s/resolve/%s/%s" % (repo, sha, member)
        destination = Path(workdir) / repo.replace("/", "_") / member.replace("/", "_")
        size, digest = _download(url, destination)
        if role == "notice" and destination.stat().st_size < 65536:
            try:
                license_texts.append(destination.read_text(errors="replace"))
            except OSError:
                pass
        files.append({"role": role, "path": "%s-%s/%s" % (family, variant or "std", member),
                      "member": member, "bytes": size, "sha256": digest})
    if not files:
        raise BootstrapError("no model members discovered in: " + repo)
    files = prefer_license_notice(files)
    license_name = infer_license(license_texts) or REVIEW
    entry = {
        "id": family, "variant": variant, "license": license_name, "revision": sha,
        "source": REVIEW,
        "watch": {"kind": "hf-repo", "repo": repo},
        "versionPolicy": {"prefix": "", "dateSource": "commit"},
        "files": [{k: f[k] for k in ("role", "path", "member", "bytes", "sha256")}
                  for f in files],
    }
    return entry


def apply_template(draft, template):
    """对账继承：draft 的约定字段从既有条目补全（单一事实源=config，防代码硬编码）。

    - source/versionPolicy/license：draft 缺失或占位（REVIEW/空）时继承模板；
    - path 目录前缀：模板文件目录唯一时按模板约定重排 draft path；
    - 字节事实（bytes/sha256/member 集合）绝不继承——对账必须暴露真实差异。
    """
    if not template:
        return draft
    merged = dict(draft)
    if merged.get("variant") is None and template.get("variant"):
        # 命名不可判定档（如 14M/bilingual）在无模板时保 None 供人审；
        # 对账场景从既有条目继承（watch.repo 已精确匹配到 template）。
        merged["variant"] = template["variant"]
    if merged.get("source") in (None, "", REVIEW) and template.get("source"):
        merged["source"] = template["source"]
    if not (merged.get("versionPolicy") or {}).get("prefix") and template.get("versionPolicy"):
        merged["versionPolicy"] = dict(template["versionPolicy"])
    if merged.get("license") in (None, "", REVIEW) and template.get("license"):
        merged["license"] = template["license"]
    dirs = {f["path"].rsplit("/", 1)[0] for f in template.get("files", [])
            if "path" in f and "/" in f["path"]}
    if len(dirs) == 1:
        dirname = dirs.pop()
        merged["files"] = [
            dict(f, path=dirname + "/" + f["path"].rsplit("/", 1)[-1]) if "path" in f else f
            for f in merged.get("files", [])]
    return merged


def compare_entry(draft, existing):
    """逆测对账：返回 {'match': [...], 'mismatch': [...], 'cosmetic': [...]}。

    选件口径（2026-10-08 无硬编码化,业主指令）：生成器对每个角色择**单件**
    （量化孪生择一/许可择一）。单侧独有的成员若「本侧该角色恰 1 件、对侧该
    角色存在（含 url 基件）」⇒ 选件差异（人工偏好的等价替换）,记 cosmetic
    不判红——覆盖 zipformer decoder 非量化偏好 / 金样 notice 为外部 url 基件
    等全部已知差异,无需家族白名单。生成器产出冗余多件（fp32 混入类）或
    对侧角色缺失仍记 mismatch。
    """
    report = {"match": [], "mismatch": [], "cosmetic": []}
    for key in ("id", "variant", "license", "revision"):
        (report["match"] if draft.get(key) == existing.get(key) else report["mismatch"]).append(
            "%s: draft=%r existing=%r" % (key, draft.get(key), existing.get(key)))
    if (draft.get("watch") or {}).get("repo") == (existing.get("watch") or {}).get("repo"):
        report["match"].append("watch.repo")
    else:
        report["mismatch"].append("watch.repo: %r vs %r" % (
            (draft.get("watch") or {}).get("repo"), (existing.get("watch") or {}).get("repo")))
    # 既有条目可含 url 基文件（如 whisper 各档的外部 LICENSE，无 member 键）——
    # 其不在镜像仓探针的对照面内（2026-10-08 全量深探首跑 KeyError 实证），
    # 但计入「角色存在性」（选件替换判定的对侧依据）。
    existing_files = existing.get("files", [])
    by_member = {f["member"]: f for f in existing_files if "member" in f}

    def role_counts(files):
        counts = {}
        for f in files:
            counts[f.get("role")] = counts.get(f.get("role"), 0) + 1
        return counts

    draft_files = draft.get("files", [])
    draft_counts = role_counts(draft_files)
    existing_counts = role_counts(existing_files)
    for item in draft_files:
        existing_item = by_member.get(item["member"])
        if existing_item is None:
            role = item.get("role")
            if draft_counts.get(role) == 1 and existing_counts.get(role) == 1:
                report["cosmetic"].append(
                    "role %s: draft selected %s (existing picked a different single member)"
                    % (role, item["member"]))
            else:
                report["mismatch"].append("member only in draft: " + item["member"])
            continue
        if (item["sha256"], item["bytes"], item["role"]) == \
                (existing_item["sha256"], existing_item["bytes"], existing_item["role"]):
            report["match"].append("file " + item["member"])
        else:
            report["mismatch"].append(
                "file %s: draft(%s,%s,%s) vs existing(%s,%s,%s)" % (
                    item["member"], item["role"], item["bytes"], item["sha256"][:8],
                    existing_item["role"], existing_item["bytes"], existing_item["sha256"][:8]))
        if item["path"] != existing_item["path"]:
            report["cosmetic"].append("path %s: %s vs %s" % (
                item["member"], item["path"], existing_item["path"]))
    existing_members = set(by_member)
    for item in draft_files:
        existing_members.discard(item["member"])
    for extra in sorted(existing_members):
        extra_role = by_member[extra].get("role")
        if existing_counts.get(extra_role) == 1 and draft_counts.get(extra_role) == 1:
            report["cosmetic"].append(
                "role %s: existing has %s (draft picked a different single member)"
                % (extra_role, extra))
        else:
            report["mismatch"].append("member only in existing: " + extra)
    return report


def _release_tag_from_url(url):
    """从资产 URL 解析发布 tag（…/releases/download/<tag>/<asset>）。"""
    match = re.search(r"/releases/download/([^/]+)/", url or "")
    return match.group(1) if match else None


def drift_check(entry, *, fetch_json=None):
    """单条目 API 级漂移检查（不做全量哈希——哈希级验证由发布链承担）。

    severity：drift=钉版引用的事实与远端不符（值得人工看）；info=预期内/候选变化。
    """
    watch = entry.get("watch") or {}
    kind = watch.get("kind")
    where = "%s.%s" % (entry.get("id"), entry.get("variant"))
    findings = []
    try:
        if kind == "hf-repo":
            sha, members = fetch_repo(watch["repo"], fetch_json=fetch_json)
            if sha != entry.get("revision"):
                findings.append({"severity": "info",
                                 "message": "上游修订已滚动（发布链 resolver 将在下次发布自动采纳）"})
            entry_members = {f["member"] for f in entry.get("files", []) if "member" in f}
            member_set = set(members)
            missing = entry_members - member_set
            if missing:
                findings.append({"severity": "drift",
                                 "message": "钉版成员在镜像仓缺失: " + ", ".join(sorted(missing))})
            candidates = sorted(member for member in member_set - entry_members
                                if member_selected(member) and infer_role(member) != "notice")
            if candidates:
                findings.append({"severity": "info",
                                 "message": "镜像仓存在未收录成员（如上游全精度导出；是否收录由人工）: "
                                            + ", ".join(candidates[:8])})
        elif kind == "github-release":
            # 单发布按 tag 查询（2026-10-08 修复：全量 releases 响应含 287 资产
            # 超 8MB 读取上限被截断——本地实测 Unterminated string）。
            archive_url = (entry.get("archive") or {}).get("url", "")
            tag = _release_tag_from_url(archive_url) or "asr-models"
            release = _request_json("https://api.github.com/repos/%s/releases/tags/%s"
                                    % (watch["repo"], tag), fetch_json=fetch_json)
            names = {asset.get("name") for asset in (release or {}).get("assets") or []}
            asset_name = archive_url.rsplit("/", 1)[-1]
            if asset_name and asset_name not in names:
                findings.append({"severity": "drift",
                                 "message": "钉版归档在远端 Releases(%s) 缺失: %s" % (tag, asset_name)})
        else:
            return {"entry": where, "status": "unknown",
                    "findings": [{"severity": "unknown",
                                  "message": "未支持的 watch kind: " + str(kind)}]}
    except (BootstrapError, OSError, ValueError, KeyError, TypeError) as error:
        return {"entry": where, "status": "unknown",
                "findings": [{"severity": "unknown", "message": str(error)}]}
    status = "drift" if any(f["severity"] == "drift" for f in findings) else "ok"
    return {"entry": where, "status": status, "findings": findings}


def drift_report(config, *, fetch_json=None):
    """config 全量条目的漂移报告（cron/CI 消费；模型名从 config 自动获取）。"""
    results = [drift_check(entry, fetch_json=fetch_json)
               for entry in config.get("models", [])]
    summary = {"entries": len(results),
               "ok": sum(1 for row in results if row["status"] == "ok"),
               "drift": sum(1 for row in results if row["status"] == "drift"),
               "unknown": sum(1 for row in results if row["status"] == "unknown")}
    return {"summary": summary, "results": results}


def discover_authors(*, fetch_json=None, min_repos=2):
    """HF 上发布 sherpa-onnx 转换仓的账号域（自动发现，防硬编码名单）。

    阈值=同一账号在 top-100 "sherpa-onnx" 命中中出现 ≥min_repos 次（转换仓账号是
    批量发布者；社区偶发同名单仓被过滤）。2026-10-08 实测 csukuangfj=76、k2-fsa=11；
    csukuangfj2 单账号仓少，由 resolve_authors 的 config 提取层覆盖。
    """
    counts = {}
    for repo in search_hf("sherpa-onnx", limit=100, fetch_json=fetch_json):
        author = repo.split("/", 1)[0]
        counts[author] = counts.get(author, 0) + 1
    return tuple(sorted(a for a, n in counts.items() if n >= min_repos))


def resolve_authors(existing_config, *, explicit=None, fetch_json=None):
    """作者域解析（防硬编码）：显式 → 既有 config 提取（hf-repo watch）→ 自动发现。"""
    if explicit:
        return (explicit,)
    from_config = set()
    for entry in existing_config.get("models", []):
        watch = entry.get("watch") or {}
        repo = watch.get("repo") or ""
        if watch.get("kind") == "hf-repo" and "/" in repo:
            from_config.add(repo.split("/", 1)[0])
    if from_config:
        return tuple(sorted(from_config))
    return discover_authors(fetch_json=fetch_json)


def discover_family(family, *, authors=None, limit=100, fetch_json=None):
    """家族名 → 候选镜像仓清单（repo/variant；身份不可判定的命中剔除）。

    2026-10-08 业主口径：seeds 只给家族名，repo 与档位规格由工具自行找出——
    发现层=HF 结构化搜索（作者域限流，域由 resolve_authors 解析；dedupe），
    身份=infer_identity 词边界匹配。
    """
    authors = tuple(authors or ())
    candidates, seen = [], set()
    for account in authors:
        for repo in search_hf(family, account, limit=limit, fetch_json=fetch_json):
            if repo in seen:
                continue
            try:
                family_id, variant = infer_identity(repo)
            except BootstrapError:
                continue
            if family_id != family:
                continue
            seen.add(repo)
            candidates.append({"repo": repo, "variant": variant})
    return candidates


def emit_config_candidates(proposals, config, copy_doc, out_dir):
    """生成候选配置（生成链第一步,2026-10-08 业主指令:CI 生成、人工采纳）。

    只追加新家族提案（proposals 的 draft）;既有条目零触碰（人工字段原样保留）。
    catalog-copy 骨架以三语空串占位——投影器 fail-closed 拒空串,骨架不可能
    静默出厂（制品只是待填模板,不构成「已生成文案」）。返回写入路径列表。
    """
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    models = copy.deepcopy(config)
    models.setdefault("models", [])
    existing_ids = {entry.get("id") for entry in models["models"]}
    for proposal in proposals:
        draft = proposal["draft"]
        if draft.get("id") in existing_ids:
            continue
        models["models"].append(draft)
    copy_out = copy.deepcopy(copy_doc or {"formatVersion": 1, "families": [], "tiers": []})
    copy_out.setdefault("families", [])
    copy_out.setdefault("tiers", [])
    empty = {"en": "", "zh-Hans": "", "zh-Hant": ""}
    existing_families = {f.get("id") for f in copy_out["families"]}
    existing_tiers = {(t.get("id"), t.get("variant")) for t in copy_out["tiers"]}
    for proposal in proposals:
        draft = proposal["draft"]
        if draft.get("id") not in existing_families:
            copy_out["families"].append({"id": draft.get("id"), "name": dict(empty),
                                         "hint": dict(empty), "strengths": dict(empty),
                                         "limitations": dict(empty)})
            existing_families.add(draft.get("id"))
        key = (draft.get("id"), draft.get("variant"))
        if key not in existing_tiers:
            copy_out["tiers"].append({"id": draft.get("id"), "variant": draft.get("variant"),
                                      "tierName": dict(empty), "tierHint": dict(empty)})
            existing_tiers.add(key)
    written = []
    for name, doc in (("models-candidate.json", models),
                      ("catalog-copy-candidate.json", copy_out)):
        path = out_dir / name
        path.write_bytes(json.dumps(doc, ensure_ascii=False, indent=2).encode() + b"\n")
        written.append(path)
    return written


def inventory_report(seeds, existing_config, *, authors=None, only=None,
                     fetch_json=None):
    """家族档位清单（轻层，API 级零下载）：逐家族列出候选镜像仓的在册状态。

    - 匹配以 **watch.repo 精确相等**为准（比 (id,variant) 猜测可靠）；
    - github-release 型家族（watch.kind 驱动,零家族名硬编码）：按 tag 单发布
      查询 Releases 资产，资产名与 watch.asset 通配匹配既有 archive；
    - 另报「钉版仓库未在候选出现」（发现层回归信号，hf-repo 型专属）。
    """
    if authors is None:
        authors = resolve_authors(existing_config, fetch_json=fetch_json)
    entries = existing_config.get("models", [])
    results = []
    for seed in seeds:
        family = seed.get("name") or ""
        if only and family not in only:
            continue
        known = {((entry.get("watch") or {}).get("repo")): "%s.%s" % (entry.get("id"), entry.get("variant"))
                 for entry in entries if entry.get("id") == family}
        release_entry = next((item for item in entries
                              if item.get("id") == family
                              and (item.get("watch") or {}).get("kind") == "github-release"), None)
        rows = []
        try:
            if release_entry is not None:
                # github-release 型（watch 驱动,无家族名硬编码）：按 tag 单发布
                # 查询（全量 releases 响应超读上限,实测截断——2026-10-08）；资产名
                # 以 watch.asset 通配匹配（repo/模式/pin 全来自 config）。
                watch = release_entry.get("watch") or {}
                repo = watch.get("repo") or ""
                pattern = watch.get("asset") or "*"
                archive_url = (release_entry.get("archive") or {}).get("url", "")
                tag = _release_tag_from_url(archive_url) or "asr-models"
                release = _request_json("https://api.github.com/repos/%s/releases/tags/%s" % (repo, tag),
                                        fetch_json=fetch_json)
                for asset in (release or {}).get("assets") or []:
                    name = asset.get("name") or ""
                    if not fnmatch.fnmatch(name, pattern):
                        continue
                    in_config = archive_url.endswith(name)
                    rows.append({"repo": name, "variant": None,
                                 "status": ("in-config:%s.%s" % (release_entry.get("id"),
                                                                 release_entry.get("variant")))
                                 if in_config else "new-candidate"})
            else:
                for candidate in discover_family(family, authors=authors, fetch_json=fetch_json):
                    key = known.get(candidate["repo"])
                    rows.append({**candidate,
                                 "status": "in-config:" + key if key else "new-candidate"})
        except (BootstrapError, OSError, ValueError, KeyError, TypeError) as error:
            results.append({"family": family, "status": "unknown", "reason": str(error)})
            continue
        discovered_repos = {row["repo"] for row in rows}
        missing = sorted(repo for repo, key in known.items()
                         if repo and release_entry is None and repo not in discovered_repos)
        results.append({"family": family, "rows": rows,
                        "missing_pinned": missing,
                        "in_config": sum(1 for row in rows if str(row["status"]).startswith("in-config")),
                        "new_candidates": sum(1 for row in rows if row["status"] == "new-candidate")})
    summary = {
        "families": len(results),
        "candidates": sum(len(row.get("rows", [])) for row in results),
        "in_config": sum(row.get("in_config", 0) for row in results),
        "new_candidates": sum(row.get("new_candidates", 0) for row in results),
        "missing_pinned": sum(len(row.get("missing_pinned", [])) for row in results),
        "unknown": sum(1 for row in results if row.get("status") == "unknown"),
    }
    return {"summary": summary, "results": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", action="append",
                        help="模型名称（可多次，如 'moonshine tiny'；与 --from-config 二选一）")
    parser.add_argument("--from-config", type=Path,
                        help="漂移检查模式：读取 config 全部模型名（零输入；cron/CI 消费）")
    parser.add_argument("--drift-report", type=Path,
                        help="漂移报告 JSON 输出路径（--from-config 模式）")
    parser.add_argument("--from-seeds", type=Path,
                        help="种子验证模式：读取 seeds.json（名字清单），逐种子发现→探针→"
                             "与 --compare-config 金样对账（重下载，人工触发的验证运行）")
    parser.add_argument("--only", action="append",
                        help="种子过滤（子串，可多次；部分验证用）")
    parser.add_argument("--author", default=None,
                        help="HF 作者域（缺省=从 --compare-config 的 hf-repo watch 自动提取，"
                             "无则自动发现转换仓账号）")
    parser.add_argument("--repo", help="跳过发现层，直接指定 HF 仓库（逆测用）")
    parser.add_argument("--compare-config", type=Path,
                        help="逆测对账：与现有 config 的 (id,variant) 条目逐字段比对")
    # 默认落磁盘面（~/.cache）：本机 /tmp 为 3.9G tmpfs，GB 级探针会 ENOSPC
    # （2026-10-08 实测）；CI runner /tmp 大，默认同样安全。
    parser.add_argument("--workdir", type=Path,
                        default=Path.home() / ".cache" / "vitaliber-asr-bootstrap")
    parser.add_argument("--out", type=Path, help="报告/draft JSON 输出路径")
    parser.add_argument("--emit-config-candidates", type=Path,
                        help="新家族草案的候选配置输出目录（生成链第一步:CI 生成、"
                             "人工采纳;models/catalog-copy 候选,文案骨架空串待人填）")
    parser.add_argument("--catalog-copy", type=Path,
                        help="现有 catalog-copy.json（候选生成时用作全量基底）")
    parser.add_argument("--probe", action="store_true",
                        help="种子深探模式：对在册候选下载实测并与现有条目对账（重下载；"
                             "默认仅出家族档位清单，API 级零下载）")
    args = parser.parse_args()
    try:
        if args.from_seeds is not None:
            seeds_doc = json.loads(args.from_seeds.read_bytes())
            config = (json.loads(args.compare_config.read_bytes())
                      if args.compare_config is not None else {"models": []})
            inventory = inventory_report(seeds_doc.get("seeds", []), config,
                                         authors=(args.author,) if args.author else None,
                                         only=args.only)
            for row in inventory["results"]:
                print("family: %s" % row["family"], flush=True)
                if row.get("status") == "unknown":
                    print("  [unknown] " + row.get("reason", ""), flush=True)
                    continue
                for item in row.get("rows", []):
                    print("  %-8s %-58s %s"
                          % (item.get("variant") or "-", item["repo"], item["status"]), flush=True)
                for repo in row.get("missing_pinned", []):
                    print("::warning::钉版仓库未在候选出现: %s" % repo, file=sys.stderr)
            summary = inventory["summary"]
            print("inventory summary: 家族 %d / 候选 %d / 在册 %d / 未收录候选 %d / 钉版缺候选 %d / 未知 %d"
                  % (summary["families"], summary["candidates"], summary["in_config"],
                     summary["new_candidates"], summary["missing_pinned"], summary["unknown"]),
                  flush=True)
            output = {"inventory": inventory}
            if args.probe:
                by_key = {(entry["id"], entry.get("variant")): entry
                          for entry in config.get("models", [])}
                probes = []
                proposals = []
                for row in inventory["results"]:
                    in_config_any = False
                    for item in row.get("rows", []):
                        status = str(item.get("status", ""))
                        if not status.startswith("in-config:"):
                            continue
                        in_config_any = True
                        key_str = status.split(":", 1)[1]
                        entry_id, _, variant = key_str.partition(".")
                        entry = by_key.get((entry_id, variant))
                        if entry is None or (entry.get("watch") or {}).get("kind") != "hf-repo":
                            continue
                        try:
                            draft = apply_template(
                                probe_repo(item["repo"], workdir=args.workdir), entry)
                        except (BootstrapError, OSError, ValueError, KeyError, TypeError) as error:
                            probes.append({"entry": key_str, "repo": item["repo"],
                                           "status": "error", "reason": str(error)})
                            print("probe: %-22s ERROR %s" % (key_str, error), flush=True)
                            continue
                        compare = compare_entry(draft, entry)
                        # draft 随报告输出（2026-10-08 委员会:生成物归属步骤）——
                        # 报告 artifact 即「可采纳物」:待人工项(REVIEW/None)在
                        # draft 内可见,人工在本机 --compare-config 复核后写回 config。
                        probes.append({"entry": key_str, "repo": item["repo"],
                                       "compare": compare, "draft": draft})
                        print("probe: %-22s matched=%d mismatch=%d cosmetic=%d"
                              % (key_str, len(compare["match"]), len(compare["mismatch"]),
                                 len(compare["cosmetic"])), flush=True)
                        for line in compare["mismatch"]:
                            print("  [mismatch] " + line, flush=True)
                    # 新家族深探（生成链第一步,2026-10-08 业主指令）:家族零在册时,
                    # 候选按档位分组定序择一（repo 名排序首）构造 draft 提案——
                    # 无金样对账;draft 即「可采纳物」,人工复核后写回 config
                    # （CI 不直写金样,治理席裁决）。
                    if not in_config_any and row.get("status") != "unknown":
                        grouped = {}
                        for item in row.get("rows", []):
                            if item.get("status") != "new-candidate":
                                continue
                            try:
                                _, candidate_variant = infer_identity(item["repo"])
                            except BootstrapError:
                                candidate_variant = None
                            grouped.setdefault(candidate_variant, []).append(item["repo"])
                        for candidate_variant, repos in sorted(grouped.items(),
                                                               key=lambda kv: kv[0] or ""):
                            repo = sorted(repos)[0]
                            key_str = "%s.%s" % (row.get("family"), candidate_variant or "std")
                            try:
                                draft = probe_repo(repo, workdir=args.workdir)
                            except (BootstrapError, OSError, ValueError, KeyError, TypeError) as error:
                                probes.append({"entry": key_str, "repo": repo,
                                               "status": "error", "reason": str(error)})
                                print("proposal: %-18s ERROR %s" % (key_str, error), flush=True)
                                continue
                            proposals.append({"entry": key_str, "repo": repo, "draft": draft})
                            print("proposal: %-18s %s（新家族草案,draft 见报告）"
                                  % (key_str, repo), flush=True)
                reproduced = sum(1 for row in probes if isinstance(row.get("compare"), dict)
                                 and not row["compare"]["mismatch"])
                print("probe summary: 复现 %d / 不一致 %d / 错误 %d（共 %d 档）"
                      % (reproduced,
                         sum(1 for row in probes if isinstance(row.get("compare"), dict)
                             and row["compare"]["mismatch"]),
                         sum(1 for row in probes if row.get("status") == "error"), len(probes)),
                      flush=True)
                output["probes"] = probes
                if proposals:
                    output["proposals"] = proposals
            if args.out is not None:
                args.out.parent.mkdir(parents=True, exist_ok=True)
                args.out.write_bytes(json.dumps(output, ensure_ascii=False, indent=2).encode() + b"\n")
            if args.emit_config_candidates is not None and proposals:
                catalog_copy = (json.loads(args.catalog_copy.read_bytes())
                                if args.catalog_copy is not None else None)
                written = emit_config_candidates(proposals, config, catalog_copy,
                                                 args.emit_config_candidates)
                for path in written:
                    print("候选配置已生成: " + str(path), flush=True)
            return 0
        if args.from_config is not None:
            config = json.loads(args.from_config.read_bytes())
            report = drift_report(config)
            for row in report["results"]:
                print("drift: %-24s %s" % (row["entry"], row["status"]), flush=True)
                for finding in row["findings"]:
                    if finding["severity"] == "drift":
                        print("::warning::drift[%s] %s" % (row["entry"], finding["message"]),
                              file=sys.stderr)
                    elif finding["severity"] == "info":
                        print("  [info] %s" % finding["message"], flush=True)
            summary = report["summary"]
            print("drift summary: ok=%d drift=%d unknown=%d (共 %d 条)"
                  % (summary["ok"], summary["drift"], summary["unknown"], summary["entries"]),
                  flush=True)
            if args.drift_report is not None:
                args.drift_report.parent.mkdir(parents=True, exist_ok=True)
                args.drift_report.write_bytes(
                    json.dumps(report, ensure_ascii=False, indent=2).encode() + b"\n")
            return 0
        if not args.name:
            raise BootstrapError("--name 或 --from-config 必须提供其一")
        config = (json.loads(args.compare_config.read_bytes())
                  if args.compare_config is not None else {"models": []})
        by_key = {(e["id"], e.get("variant")): e for e in config.get("models", [])}
        drafts = []
        for name in args.name:
            repo = args.repo or (search_hf(name, args.author) or [None])[0]
            if not repo:
                raise BootstrapError("no candidate repo found for: " + name)
            print("bootstrap: %s -> %s" % (name, repo), flush=True)
            entry = probe_repo(repo, workdir=args.workdir)
            entry = apply_template(entry, by_key.get((entry["id"], entry["variant"])))
            drafts.append(entry)
        output = {"drafts": drafts}
        if args.compare_config is not None:
            reports = []
            for entry in drafts:
                existing = by_key.get((entry["id"], entry["variant"]))
                reports.append({"entry": "%s.%s" % (entry["id"], entry["variant"]),
                                "compare": (compare_entry(entry, existing)
                                            if existing else "no existing entry")})
            output["reports"] = reports
            for report in reports:
                print("compare: %s" % report["entry"])
                if isinstance(report["compare"], str):
                    print("  " + report["compare"])
                    continue
                for bucket in ("mismatch", "cosmetic"):
                    for line in report["compare"][bucket]:
                        print("  [%s] %s" % (bucket, line))
                print("  matched: %d 项" % len(report["compare"]["match"]))
        if args.out is not None:
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_bytes(json.dumps(output, ensure_ascii=False, indent=2).encode() + b"\n")
            print("draft written: " + str(args.out), flush=True)
        return 0
    except (OSError, ValueError, KeyError, TypeError, BootstrapError) as error:
        print("ASR-BOOTSTRAP-ERROR: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
