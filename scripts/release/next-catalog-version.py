#!/usr/bin/env python3
"""轮换版本推进(2026-10-06 单一 JSON 架构):计算下一 catalogVersion。

单调性是客户端回滚守卫的前提——新签名目录的 catalogVersion 必须延续
既往发布历史,任何回落都会被已装客户端整体拒绝。推进源按优先级:
1. 仓库 Resources/ASRModelUpdates/manifest.json 已是签名信封 → payload.catalogVersion + 1;
2. CNB 远端 manifest.json(固定名)——匿名下载解码 → + 1;
3. CNB 远端最高 N.catalog.json(历史版本化面)→ + 1;
4. git 历史里最后提交的 N.catalog.json 版本号 → + 1(远端被清空时的连续性兜底);
5. 全无 → 1(首次发布)。

stdlib only;CNB 下载端点 302 → asset.cnb.cool 白名单跟随(与
cnb_release.CNBRedirectHandler 同语义),匿名请求不带凭据。
"""
import argparse
import base64
import json
import re
import subprocess
import sys
import urllib.request
from urllib.parse import urlsplit

ALLOWED_HOSTS = {"cnb.cool", "asset.cnb.cool"}


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
    return payload.get("catalogVersion")


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


def next_catalog_version(repository):
    repo_manifest = "Resources/ASRModelUpdates/manifest.json"
    try:
        version = _envelope_version(open(repo_manifest, "rb").read())
        if version:
            return version + 1
    except (OSError, ValueError):
        pass

    base = f"https://cnb.cool/{repository}/-/releases/download/asr-models"
    for name in ("manifest.json",):
        try:
            version = _envelope_version(_get(base + "/" + name))
            if version:
                return version + 1
        except Exception:
            continue

    legacy = _highest_legacy_from_git()
    if legacy:
        return legacy + 1
    # 连续性地板(2026-10-06 候选 37398352957 实证):CI 浅克隆无 git 历史,
    # 远端又被清空时四层全空——但既往发布历史到 catalogVersion=6(单文件
    # 架构前最后一版),从 7 起延续,保证已装客户端(持 v6 状态)的单调回滚
    # 守卫不拒新目录。该常量只在单一文件架构首次轮换时起作用,此后仓库
    # 信封路径接管。
    return 7


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default="robinhoo1973/Resources")
    args = parser.parse_args()
    print(next_catalog_version(args.repository))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
