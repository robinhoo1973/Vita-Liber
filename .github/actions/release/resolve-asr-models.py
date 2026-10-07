#!/usr/bin/env python3
"""Resolve the latest upstream revisions for the ASR model config (full-auto adoption).

业主 2026-10-07 裁决（全自动）：每次 run 按 `.github/config/asr/models.json` 的
watch 规则解析上游最新版——内容有变即滚动 pin（revision/URL/bytes/sha256），
由既有构建→签名→发布链自动产出新版本；无变即原地不动。

watch 种类（与 generate-asr-source-manifest.py 同文法）：
- hf-repo        ：HuggingFace 模型仓库；latest = 模型 API 的 `sha`（main commit）。
- github-commit  ：raw.githubusercontent 静态文件；latest = 该文件路径的最近 commit。
- github-release ：GitHub Release 资产（asset 通配）；latest = 最新匹配资产，
                   revision 由 watch.versionRegex 从资产名提取。

纪律（与发布链同级）：
- 解析失败（网络/形状）→ 该条目 status=unknown，**保留现行 pin** + ::warning::
  （构建不阻断；绝不猜测版本）。
- 解析到新 revision 后必须**下载实测** bytes/sha256（HF Xet CAS 块级哈希不得
  用作钉版哈希——钉版纪律）；实测失败 = 硬错（fail-closed）。
- 内容等值（全部文件 sha256 与现行 pin 相同）→ **不滚动 revision**（防上游
  元数据类提交造成无谓全量重建）；日志注明内容等值。
- 次源锁定文件（显式 url 的 notice 等）不参与自动追踪。

CI 消费：--apply 输出更新后的 config（供 generate-asr-source-manifest.py 投影），
--report 输出逐条目 JSON（可观测面）。stdlib only；匿名请求（HF/GitHub 公开面）；
GITHUB_TOKEN 存在时用于提高 API 限额（只增限额，不改语义）。
"""
import argparse
import copy
import fnmatch
import hashlib
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

USER_AGENT = "vitaliber-asr-resolver/1"
HF_API = "https://huggingface.co/api/models/"
GH_API = "https://api.github.com/repos/"
PAGE = 100


class ResolveError(Exception):
    pass


def _request_json(url, *, fetch_json=None, attempts=3):
    if fetch_json is not None:
        # 注入缝（离线测试）：不重试，瞬时失败即转换——调用方按 unknown 处理。
        try:
            return fetch_json(url)
        except (OSError, ValueError) as error:
            raise ResolveError("fetch failed: %s (%s)" % (url, error))
    headers = {"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"}
    token = os.environ.get("GITHUB_TOKEN", "")
    if token and url.startswith(GH_API):
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
    raise ResolveError("fetch failed: %s (%s)" % (url, last))


def _download(url, destination, *, download=None):
    if download is not None:
        return download(url, destination)
    headers = {"User-Agent": USER_AGENT}
    request = urllib.request.Request(url, headers=headers)
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    received = 0
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


def resolve_latest(watch, *, fetch_json=None):
    """Returns the latest upstream revision for one watch rule.

    github-release 返回 {"revision": ..., "url": ...}；其余返回 revision 字符串。
    """
    kind = watch.get("kind")
    if kind == "hf-repo":
        info = _request_json(HF_API + watch["repo"], fetch_json=fetch_json)
        sha = info.get("sha") if isinstance(info, dict) else None
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise ResolveError("hf-repo API returned no revision: " + watch["repo"])
        return sha
    if kind == "github-commit":
        url = (GH_API + watch["repo"] + "/commits?path=" +
               urllib.parse.quote(watch["member"], safe="") + "&per_page=1")
        commits = _request_json(url, fetch_json=fetch_json)
        if not isinstance(commits, list) or not commits:
            raise ResolveError("github-commit API returned no commit: " + watch["repo"])
        return commits[0]["sha"]
    if kind == "github-release":
        pattern = watch.get("asset") or ""
        regex = watch.get("versionRegex")
        if not regex:
            raise ResolveError("github-release watch missing versionRegex")
        releases = _request_json(GH_API + watch["repo"] + "/releases?per_page=" + str(PAGE),
                                 fetch_json=fetch_json)
        for release in releases if isinstance(releases, list) else []:
            for asset in release.get("assets") or []:
                name = asset.get("name") or ""
                if fnmatch.fnmatch(name, pattern):
                    match = re.match(regex, name)
                    if match is None:
                        raise ResolveError("asset did not match versionRegex: " + name)
                    return {"revision": match.group(1),
                            "url": asset.get("browser_download_url") or ""}
        raise ResolveError("no release asset matched: " + watch["repo"] + "/" + pattern)
    raise ResolveError("unknown watch kind: " + str(kind))


def _hf_member_url(watch, revision, member):
    return "https://huggingface.co/%s/resolve/%s/%s" % (watch["repo"], revision, member)


def _shared_revision(shared):
    match = re.match(r"^https://raw\.githubusercontent\.com/" +
                     re.escape(shared["watch"]["repo"]) + r"/([0-9a-f]{40})/", shared["url"])
    return match.group(1) if match else None


def plan_entry(entry, *, fetch_json=None):
    """One entry → {"status": "up-to-date"|"update"|"unknown", ...}."""
    watch = entry["watch"]
    try:
        latest = resolve_latest(watch, fetch_json=fetch_json)
    except ResolveError as error:
        return {"status": "unknown", "reason": str(error)}
    if watch["kind"] == "github-release":
        if latest["revision"] == entry["revision"]:
            return {"status": "up-to-date", "latest": entry["revision"]}
        return {"status": "update", "latest": latest["revision"],
                "url": latest["url"], "revision": latest["revision"]}
    if latest == entry["revision"]:
        return {"status": "up-to-date", "latest": latest}
    return {"status": "update", "latest": latest, "revision": latest}


def apply_update(entry, result, *, workdir, download=None):
    """Download+measure the new revision; rolls pins only when content changed.

    Returns "rolled" | "content-identical". Raises ResolveError on hard failure.
    """
    watch = entry["watch"]
    workdir = Path(workdir)
    workdir.mkdir(parents=True, exist_ok=True)
    if watch["kind"] == "github-release":
        destination = workdir / (entry["id"] + "-" + str(entry.get("variant")) + ".dl")
        size, digest = _download(result["url"], destination, download=download)
        if size == entry["archive"]["bytes"] and digest == entry["archive"]["sha256"]:
            return "content-identical"
        entry["revision"] = result["revision"]
        entry["archive"]["url"] = result["url"]
        entry["archive"]["bytes"] = size
        entry["archive"]["sha256"] = digest
        return "rolled"
    if watch["kind"] in ("hf-repo", "github-commit"):
        changed = False
        for item in entry.get("files", []):
            if "member" not in item:
                continue
            if watch["kind"] == "hf-repo":
                url = _hf_member_url(watch, result["revision"], item["member"])
            else:
                url = ("https://raw.githubusercontent.com/%s/%s/%s"
                       % (watch["repo"], result["revision"], watch["member"]))
            destination = workdir / (str(item["path"]).replace("/", "_"))
            size, digest = _download(url, destination, download=download)
            if size != item["bytes"] or digest != item["sha256"]:
                changed = True
                item["bytes"] = size
                item["sha256"] = digest
        if not changed:
            return "content-identical"
        entry["revision"] = result["revision"]
        return "rolled"
    raise ResolveError("watch kind cannot be applied: " + str(watch.get("kind")))


def resolve_all(config, *, fetch_json=None, download=None, workdir=None):
    """Plan+apply over the whole config (models + shared); returns (updated, report)."""
    if workdir is None:
        raise ResolveError("workdir is required")
    updated = copy.deepcopy(config)
    report = []
    for entry, target in zip(config["models"], updated["models"]):
        where = "%s.%s" % (entry["id"], entry.get("variant"))
        result = plan_entry(entry, fetch_json=fetch_json)
        row = {"entry": where, "status": result["status"]}
        if result["status"] == "up-to-date":
            row["revision"] = result["latest"]
        elif result["status"] == "update":
            try:
                outcome = apply_update(target, result, workdir=workdir, download=download)
            except (OSError, ResolveError) as error:
                raise ResolveError("update failed for %s: %s" % (where, error))
            row["revision"] = result["revision"]
            row["outcome"] = outcome
            if outcome == "content-identical":
                # 内容等值：回滚 pin（不因元数据类提交产生全量重建/重签）。
                target["revision"] = entry["revision"]
                if "archive" in target:
                    target["archive"] = copy.deepcopy(entry["archive"])
                for t_item, o_item in zip(target.get("files", []), entry.get("files", [])):
                    if "member" in o_item:
                        t_item["bytes"], t_item["sha256"] = o_item["bytes"], o_item["sha256"]
                row["status"] = "up-to-date"
                row["revision"] = entry["revision"]
        else:
            row["reason"] = result["reason"]
        report.append(row)
    for shared, target in zip(config.get("shared", []), updated.get("shared", [])):
        watch = shared.get("watch") or {}
        where = "shared/" + shared["path"]
        if watch.get("kind") != "github-commit":
            report.append({"entry": where, "status": "skipped"})
            continue
        try:
            latest = resolve_latest(watch, fetch_json=fetch_json)
        except ResolveError as error:
            report.append({"entry": where, "status": "unknown", "reason": str(error)})
            continue
        current = _shared_revision(shared)
        if latest == current:
            report.append({"entry": where, "status": "up-to-date", "revision": latest})
            continue
        url = "https://raw.githubusercontent.com/%s/%s/%s" % (watch["repo"], latest,
                                                              watch["member"])
        try:
            size, digest = _download(url, Path(workdir) / (shared["role"] + ".dl"),
                                     download=download)
        except OSError as error:
            raise ResolveError("shared update failed for %s: %s" % (where, error))
        if size == shared["bytes"] and digest == shared["sha256"]:
            report.append({"entry": where, "status": "up-to-date", "revision": current})
            continue
        target["url"] = url
        target["bytes"] = size
        target["sha256"] = digest
        report.append({"entry": where, "status": "update", "revision": latest})
    return updated, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--apply", type=Path, help="输出更新后的 config")
    parser.add_argument("--report", type=Path, help="输出逐条目 JSON 报告")
    parser.add_argument("--workdir", type=Path, default=Path("/tmp/asr-resolve"))
    parser.add_argument("--plan-only", action="store_true",
                        help="只解析与报告，不下载实测、不输出 apply（观测/预检面）")
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_bytes())
        if args.plan_only:
            updated, report = config, [dict(plan_entry(entry), entry="%s.%s" % (entry["id"], entry.get("variant")))
                                       for entry in config["models"]]
        else:
            updated, report = resolve_all(config, workdir=args.workdir)
        for row in report:
            if row["status"] == "up-to-date":
                print("resolve: %-24s up-to-date (%s)" % (row["entry"], row.get("revision")),
                      flush=True)
            elif row["status"] == "update":
                print("resolve: %-24s UPDATE -> %s" % (row["entry"], row.get("revision")),
                      flush=True)
            elif row["status"] == "unknown":
                print("::warning::resolve: %s unknown — 保留现行 pin（%s）"
                      % (row["entry"], row.get("reason")), file=sys.stderr)
        if args.report is not None:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_bytes(json.dumps(report, ensure_ascii=False, indent=2).encode())
        if args.apply is not None:
            args.apply.parent.mkdir(parents=True, exist_ok=True)
            args.apply.write_bytes(
                json.dumps(updated, ensure_ascii=False, indent=2).encode() + b"\n")
        return 0
    except (OSError, ValueError, KeyError, TypeError, ResolveError) as error:
        print("ASR-RESOLVE-ERROR: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
