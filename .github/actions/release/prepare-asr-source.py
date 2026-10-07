#!/usr/bin/env python3
"""Prepare a complete pinned ASR tree, preferring verified CNB Release packages as a cache.

2026-10-03 cutover Task 3: the reuse cache reads the public CNB tag-page inventory
(anonymous, fail-closed on SSR shape drift) and downloads attachments anonymously.
GitHub Release is used only by the one-time seed migration. When the CNB cache is
unavailable the pinned upstream resources are fetched instead (a cache never
bypasses source validation).
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

from asr_package import decode_json, decode_manifest_data_file, validate_index
from cnb_release import public_download_url

TOOLS = Path(__file__).resolve().parent
TAG = "asr-models"
MAX_PAGE_BYTES = 8 << 20

# 仓库根探测:逐级向上找 CoreKit/Sources/Domain 锚点(与 fetch-asr-models.py
# 同纪律——禁止按固定层级 parents[N] 假设;2026-10-05 审查整改)。
REPO_ROOT = TOOLS
while REPO_ROOT != REPO_ROOT.parent and not (REPO_ROOT / "CoreKit" / "Sources" / "Domain").is_dir():
    REPO_ROOT = REPO_ROOT.parent


def parse_cnb_tag_page(html, repository, tag):
    """Bounded, fail-closed parse of the CNB tag detail page (design doc §3.1).

    Only the server-rendered `script#__NEXT_DATA__` JSON is read; the release must
    be in `success` state, the tagRef must match, and every asset must carry a
    complete name/path/hash/size set with the exact expected download path.
    """
    if len(html) > MAX_PAGE_BYTES:
        raise ValueError("CNB tag page exceeds size bound")
    match = re.search(rb'<script[^>]*id="__NEXT_DATA__"[^>]*>(.*?)</script>', html, re.S)
    if match is None:
        raise ValueError("CNB tag page has no __NEXT_DATA__ payload")
    try:
        data = json.loads(match.group(1))
    except ValueError:
        raise ValueError("CNB tag page __NEXT_DATA__ is not JSON")
    props = data.get("props", {}).get("pageProps", {})
    if props.get("releaseDetailStatus") != "success":
        # 实测(2026-10-05 探针):Release 未创建时真实页面为 "pending" 且
        # releasesDetailData=null——fail-closed 语义,不猜测部分解析。
        raise ValueError("CNB tag page release state is not success")
    release_data = props.get("releasesDetailData")
    release = release_data.get("release") if isinstance(release_data, dict) else None
    if not isinstance(release, dict) or release.get("tagRef") != "refs/tags/" + tag:
        raise ValueError("CNB tag page release/tagRef mismatch")
    assets = release.get("assets")
    if not isinstance(assets, list) or not assets or len(assets) > 512:
        raise ValueError("CNB tag page assets are missing or unbounded")
    parsed, seen = [], set()
    for asset in assets:
        name = asset.get("name")
        if not isinstance(name, str) or not name or name in seen:
            raise ValueError("CNB tag page asset name is missing or duplicated")
        seen.add(name)
        path = asset.get("path")
        expected_path = "/" + repository + "/-/releases/download/" + tag + "/" + name
        if path != expected_path:
            raise ValueError("CNB tag page asset path is out of scope: " + name)
        algo = asset.get("hashAlgo")
        digest = asset.get("hashValue")
        size = asset.get("sizeInByte")
        if algo != "sha256" or not re.fullmatch(r"[0-9a-f]{64}", digest or "") or not isinstance(size, int):
            raise ValueError("CNB tag page asset metadata is incomplete: " + name)
        parsed.append({"name": name, "path": path, "hashAlgo": algo, "hashValue": digest, "sizeInByte": size})
    return parsed


def fetch_cnb_inventory(repository):
    url = "https://cnb.cool/" + repository + "/-/releases/tag/" + TAG
    request = urllib.request.Request(url, headers={"User-Agent": "vitaliber-asr-cache/1"})
    with urllib.request.urlopen(request, timeout=60) as response:
        html = response.read(MAX_PAGE_BYTES + 1)
    return parse_cnb_tag_page(html, repository, TAG)


def download_cnb_asset(repository, asset, destination, expected_sha256, expected_size):
    url = public_download_url(repository, TAG, asset["name"])
    request = urllib.request.Request(url, headers={"User-Agent": "vitaliber-asr-cache/1"})
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".downloading")
    # 流式落盘+哈希单趟(2026-10-05 审查):旧实现整包读入内存,1.7GB 级包
    # 峰值 ~3x 内存;有界读取 + 落盘即哈希,坏下载绝不落终名。
    digest = hashlib.sha256()
    received = 0
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            with temporary.open("wb") as target:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    received += len(chunk)
                    if received > expected_size:
                        raise ValueError("CNB cached package exceeds the declared size: " + asset["name"])
                    digest.update(chunk)
                    target.write(chunk)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    if received != expected_size or digest.hexdigest() != expected_sha256:
        temporary.unlink(missing_ok=True)
        raise ValueError("CNB cached package digest/size mismatch: " + asset["name"])
    temporary.replace(destination)
    return destination


def prepare(index, index_path, source, root, cache, repository, *,
            inventory=fetch_cnb_inventory, download=download_cnb_asset):
    """Restore the pinned source tree from the CNB cache, or fall back to upstream fetch."""
    # complete=False(2026-10-05 审查):首次新增档位的模板条目还没有真实
    # sha256/bytes(build 步骤才计算)——prepare 用 complete=True 会把「先建
    # 后签」的候选流掐死在第一步(鸡生蛋);缓存路径的 materialize/下载各自
    # 仍按完整校验(缺 sha 条目自然回落上游抓取,不放松任何缓存验证)。
    validate_index(index, complete=False)
    root.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    for name in ("manifest.json", "NOTICE.md", "LICENSE-APACHE-2.0.txt"):
        shutil.copyfile(source / name, root / name)
    try:
        assets = {a["name"]: a for a in inventory(repository)}
        for model in index["models"]:
            asset = assets[model["url"]]
            download(repository, asset, cache / model["url"], model["sha256"], model["bytes"])
            # 进度可观测（2026-10-07）：此前 728s 缓存下载零输出（黑箱；
            # CI 37598832117 排障靠时间窗反推）——逐包打印便于分段定位。
            print("cache asset verified: " + model["url"], flush=True)
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        print("CNB Release cache unavailable; using pinned upstream resources: " + str(error), flush=True)
    else:
        result = subprocess.run([sys.executable, str(TOOLS / "materialize-asr-packages.py"),
                                 "--index", str(index_path),
                                 "--directory", str(cache),
                                 "--source-manifest", str(source / "manifest.json"), "--root", str(root)])
        if result.returncode:
            print("Release cache did not match the pinned sources; verifying/fetching upstream", flush=True)
    # This rechecks every file and the source digest; a cache never bypasses source validation.
    subprocess.run([sys.executable, str(TOOLS / "fetch-asr-models.py"), "--root", str(root)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--source", type=Path, default=REPO_ROOT / "Resources" / "ASRModels")
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--repository", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        raise ValueError("Invalid repository")
    # 两态读取(2026-10-06 单一 JSON 架构):仓库面 manifest.json 为签名信封
    index = decode_manifest_data_file(args.index)
    prepare(index, args.index, args.source, args.root, args.cache, args.repository)


if __name__ == "__main__":
    main()
