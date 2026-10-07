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
import fnmatch
import hashlib
import json
import re
import socket
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

from asr_package import MODELS, VARIANTS

# 本机 IPv6 路由对部分 CDN 为黑洞：urllib 无 Happy Eyeballs，会卡死在
# IPv6 SYN-SENT（2026-10-08 实证：HF 直连下载僵死 5 分钟，curl 同 URL 1 秒）。
# 统一优先 IPv4（CI runner 通常仅 IPv4，等价无副作用）。
_ORIGINAL_GETADDRINFO = socket.getaddrinfo


def _ipv4_first(*args, **kwargs):
    answers = _ORIGINAL_GETADDRINFO(*args, **kwargs)
    return [answer for answer in answers if answer[0] == socket.AF_INET] or answers


socket.getaddrinfo = _ipv4_first

# 传输面与 resolver 同构（内联实现；本工具仅本地/离线运行，不参与 CI）。

FAMILY_SOURCES = {
    "whisper": "https://github.com/openai/whisper",
    "zipformer": "https://github.com/k2-fsa/icefall",
    "dolphin": "https://github.com/DataoceanAI/Dolphin",
    "sense-voice": "https://github.com/FunAudioLLM/SenseVoice",
    "fire-red": "https://github.com/FireRedTeam/FireRedASR",
    "moonshine": "https://github.com/usefulsensors/moonshine",
    "qwen3": "https://github.com/QwenLM/Qwen3-ASR",
}
FAMILY_VERSION_PREFIX = {"whisper": "int8", "dolphin": "ctc-int8", "qwen3": "0.6b-int8"}
SKIP_PATTERNS = (".gitattributes", "test_wavs/*", "*.wav", "*trans.txt", ".git/*")
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
        with destination.open("wb") as target:
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                received += len(chunk)
                digest.update(chunk)
                target.write(chunk)
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


def search_hf(name, author=None, limit=10):
    def query(term):
        url = "https://huggingface.co/api/models?search=" + urllib.parse.quote(term, safe="")
        if author:
            url += "&author=" + author
        url += "&limit=%d" % limit
        result = _request_json(url)
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

    例：sherpa-onnx-whisper-turbo → (whisper, turbo)；
        sherpa-onnx-moonshine-tiny-en-int8 → (moonshine, tiny)；
        sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23 → (zipformer, None)（人审补档位）。
    """
    tail = repo.split("/")[-1]
    tail = re.sub(r"^sherpa-onnx-", "", tail)
    tokens = tail.split("-")
    family = next((token for token in tokens if token in MODELS), None)
    if family is None:
        raise BootstrapError("cannot infer family from repo name: " + repo)
    variant = next((token for token in tokens if token in VARIANTS), None)
    return family, variant


def infer_license(license_texts):
    joined = "\n".join(license_texts)
    if "MIT License" in joined or "Permission is hereby granted, free of charge" in joined:
        return "MIT"
    if "Apache License" in joined and "Version 2.0" in joined:
        return "Apache-2.0"
    return None


def prefer_license_notice(files):
    """notice 选择精化（逆测实证 2026-10-08）：有 LICENSE/MODEL_LICENSE 类成员时
    弃 README.md 兜底——许可文本是必需署名，README 存根只增噪（人工钉版同判）。"""
    def is_license(member):
        return member.rsplit("/", 1)[-1].upper().startswith(("LICENSE", "MODEL_LICENSE"))
    if not any(f["role"] == "notice" and is_license(f["member"]) for f in files):
        return files
    return [f for f in files if f["role"] != "notice" or is_license(f["member"])]


def probe_repo(repo, *, workdir):
    sha, members = fetch_repo(repo)
    family, variant = infer_identity(repo)
    files, license_texts = [], []
    for member in members:
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
    license_name = infer_license(license_texts) or "REVIEW"
    entry = {
        "id": family, "variant": variant, "license": license_name, "revision": sha,
        "source": FAMILY_SOURCES.get(family, "REVIEW"),
        "watch": {"kind": "hf-repo", "repo": repo},
        "versionPolicy": {"prefix": FAMILY_VERSION_PREFIX.get(family, ""),
                          "dateSource": "commit"},
        "files": [{k: f[k] for k in ("role", "path", "member", "bytes", "sha256")}
                  for f in files],
    }
    return entry


def compare_entry(draft, existing):
    """逆测对账：返回 {'match': [...], 'mismatch': [...], 'cosmetic': [...]}。"""
    report = {"match": [], "mismatch": [], "cosmetic": []}
    for key in ("id", "variant", "license", "revision"):
        (report["match"] if draft.get(key) == existing.get(key) else report["mismatch"]).append(
            "%s: draft=%r existing=%r" % (key, draft.get(key), existing.get(key)))
    if (draft.get("watch") or {}).get("repo") == (existing.get("watch") or {}).get("repo"):
        report["match"].append("watch.repo")
    else:
        report["mismatch"].append("watch.repo: %r vs %r" % (
            (draft.get("watch") or {}).get("repo"), (existing.get("watch") or {}).get("repo")))
    by_member = {f["member"]: f for f in existing.get("files", [])}
    for item in draft.get("files", []):
        existing_item = by_member.get(item["member"])
        if existing_item is None:
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
    for item in draft.get("files", []):
        existing_members.discard(item["member"])
    for extra in sorted(existing_members):
        report["mismatch"].append("member only in existing: " + extra)
    return report


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
            releases = _request_json("https://api.github.com/repos/%s/releases?per_page=100"
                                     % watch["repo"], fetch_json=fetch_json)
            asset_name = (entry.get("archive") or {}).get("url", "").rsplit("/", 1)[-1]
            names = {asset.get("name")
                     for release in (releases if isinstance(releases, list) else [])
                     for asset in release.get("assets") or []}
            if asset_name and asset_name not in names:
                findings.append({"severity": "drift",
                                 "message": "钉版归档在远端 Releases 缺失: " + asset_name})
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", action="append",
                        help="模型名称（可多次，如 'moonshine tiny'；与 --from-config 二选一）")
    parser.add_argument("--from-config", type=Path,
                        help="漂移检查模式：读取 config 全部模型名（零输入；cron/CI 消费）")
    parser.add_argument("--drift-report", type=Path,
                        help="漂移报告 JSON 输出路径（--from-config 模式）")
    parser.add_argument("--author", default="csukuangfj", help="HF 作者域（默认 csukuangfj）")
    parser.add_argument("--repo", help="跳过发现层，直接指定 HF 仓库（逆测用）")
    parser.add_argument("--compare-config", type=Path,
                        help="逆测对账：与现有 config 的 (id,variant) 条目逐字段比对")
    parser.add_argument("--workdir", type=Path, default=Path("/tmp/asr-bootstrap"))
    parser.add_argument("--out", type=Path, help="draft JSON 输出路径")
    args = parser.parse_args()
    try:
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
        drafts = []
        for name in args.name:
            repo = args.repo or (search_hf(name, args.author) or [None])[0]
            if not repo:
                raise BootstrapError("no candidate repo found for: " + name)
            print("bootstrap: %s -> %s" % (name, repo), flush=True)
            entry = probe_repo(repo, workdir=args.workdir)
            drafts.append(entry)
        output = {"drafts": drafts}
        if args.compare_config is not None:
            config = json.loads(args.compare_config.read_bytes())
            by_key = {(e["id"], e.get("variant")): e for e in config.get("models", [])}
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
