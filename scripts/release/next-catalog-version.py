#!/usr/bin/env python3
"""轮换版本推进(2026-10-07 单调修复):下一 catalogVersion = max(全部来源)+1。

单调性是客户端回滚守卫的前提——新签名目录的 catalogVersion 必须严格大于
既往一切已发布/已提交/远端可见版本,任何回落都会被已装客户端整体拒绝。
2026-10-07 事故(仓库信封 v7 vs 远端 manifest v8,旧「按优先级首命中 +1」输出
8 → 下次发布与远端同版本 = 等价歧义必红)根因:首命中是**可用性**设计(任一源
可用即可),不是**单调性**设计(必须取全部来源的下界之上)。修复:收集全部
来源版本,取 max + 1;诊断一律走 stderr(stdout 只输出数字,供 CI 捕获)。

来源与失败语义(2026-10-07 委员会 CI 席设计):
1. 仓库 Resources/ASRModelUpdates/manifest.json 签名信封 → payload.catalogVersion;
   缺失/畸形 = WARNING 跳过(远端/地板兜底)。
2. CNB 远端固定名 manifest.json(匿名下载) → payload.catalogVersion;
   404 = 跳过(尚未发布);网络错误/5xx/重定向越界/非信封载荷 = **硬错**
   (瞬时故障或形状漂移绝不允许静默降为同版本发布)。
3. git 历史最高 N.catalog.json(CI 浅克隆自然为空;兼容旧版本化资产面)。
地板 6:全部来源缺失时 next = 7(单文件架构前最后一版为 6,历史语义保留)。

stdlib only;匿名请求(不带凭据);302 → asset.cnb.cool 白名单跟随。
"""
import argparse
import base64
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

ALLOWED_HOSTS = {"cnb.cool", "asset.cnb.cool"}
FLOOR = 6
REPO_MANIFEST = "Resources/ASRModelUpdates/manifest.json"


class RemoteFetchError(RuntimeError):
    """远端目录不可用且语义上不允许降级(网络/5xx/形状)——硬错。"""


def _get(url, max_bytes=2 << 20):
    class Redirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            target = urlsplit(newurl)
            if target.netloc not in ALLOWED_HOSTS:
                raise RuntimeError("redirect refused: " + target.netloc)
            return super().redirect_request(req, fp, code, msg, headers, newurl)

    opener = urllib.request.build_opener(Redirect())
    request = urllib.request.Request(url, headers={"User-Agent": "vitaliber-ci/1.0"})
    with opener.open(request, timeout=60) as response:
        data = response.read(max_bytes + 1)
        if len(data) > max_bytes:
            raise RuntimeError("metadata exceeds size bound")
        return data


def _envelope_version(data):
    envelope = json.loads(data)
    if "payload" not in envelope or "signatures" not in envelope:
        return None
    payload = json.loads(base64.b64decode(envelope["payload"]))
    version = payload.get("catalogVersion")
    return version if isinstance(version, int) and not isinstance(version, bool) else None


def _highest_legacy_from_git():
    result = subprocess.run(
        ["git", "log", "--all", "--name-only", "--pretty=format:", "--", "Resources/ASRModelUpdates"],
        capture_output=True, text=True)
    versions = set()
    for name in result.stdout.splitlines():
        match = re.fullmatch(r"Resources/ASRModelUpdates/([1-9][0-9]*)\.catalog\.json", name)
        if match:
            versions.add(int(match.group(1)))
    return max(versions) if versions else None


def _repo_source_version(path=REPO_MANIFEST):
    try:
        version = _envelope_version(Path(path).read_bytes())
    except (OSError, ValueError) as error:
        print(f"next-catalog-version: WARNING 仓库信封不可用({error})——跳过该来源", file=sys.stderr)
        return None
    if version is None:
        print("next-catalog-version: WARNING 仓库信封无 catalogVersion——跳过该来源", file=sys.stderr)
    return version


def _remote_source_version(repository, fetch):
    url = f"https://cnb.cool/{repository}/-/releases/download/asr-models/manifest.json"
    try:
        data = fetch(url)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None  # 尚未发布:无远端基线
        raise RemoteFetchError(
            f"远端 manifest.json HTTP {error.code}——拒绝在未知远端状态下推进") from error
    except (urllib.error.URLError, OSError, RuntimeError) as error:
        raise RemoteFetchError(f"远端 manifest.json 获取失败: {error}") from error
    try:
        version = _envelope_version(data)
    except ValueError as error:
        raise RemoteFetchError(f"远端 manifest.json 形状异常: {error}") from error
    if version is None:
        raise RemoteFetchError("远端 manifest.json 非签名信封——拒绝在未知远端状态下推进")
    return version


def next_catalog_version(repository, fetch=_get, git_versions=_highest_legacy_from_git,
                         repo_manifest=REPO_MANIFEST):
    """max(全部来源 ∪ {地板}) + 1;远端异常(非 404)上抛 RemoteFetchError 硬错。"""
    sources = {}
    repo_version = _repo_source_version(repo_manifest)
    if repo_version is not None:
        sources["repo"] = repo_version
    remote_version = _remote_source_version(repository, fetch)
    if remote_version is not None:
        sources["remote"] = remote_version
    legacy = git_versions()
    if legacy is not None:
        sources["git"] = legacy
    head = max(list(sources.values()) + [FLOOR])
    detail = ",".join(f"{key}={value}" for key, value in sorted(sources.items())) or "none"
    print(f"next-catalog-version: sources[{detail}] floor={FLOOR} -> next={head + 1}", file=sys.stderr)
    return head + 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repository", default="robinhoo1973/Resources")
    args = parser.parse_args()
    try:
        print(next_catalog_version(args.repository))
    except RemoteFetchError as error:
        print(f"next-catalog-version: ERROR {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
