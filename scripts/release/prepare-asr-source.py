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

from asr_package import decode_json, validate_index

TOOLS = Path(__file__).resolve().parent
TAG = "asr-models"
MAX_PAGE_BYTES = 8 << 20


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
    url = "https://cnb.cool/" + repository + "/-/releases/download/" + TAG + "/" + asset["name"]
    request = urllib.request.Request(url, headers={"User-Agent": "vitaliber-asr-cache/1"})
    with urllib.request.urlopen(request, timeout=600) as response:
        data = response.read(expected_size + 1)
    if len(data) != expected_size or hashlib.sha256(data).hexdigest() != expected_sha256:
        raise ValueError("CNB cached package digest/size mismatch: " + asset["name"])
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".downloading")
    temporary.write_bytes(data)
    temporary.replace(destination)
    return destination


def prepare(index, index_path, source, root, cache, repository, *,
            inventory=fetch_cnb_inventory, download=download_cnb_asset):
    """Restore the pinned source tree from the CNB cache, or fall back to upstream fetch."""
    validate_index(index)
    root.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    for name in ("manifest.json", "NOTICE.md", "LICENSE-APACHE-2.0.txt"):
        shutil.copyfile(source / name, root / name)
    try:
        assets = {a["name"]: a for a in inventory(repository)}
        for model in index["models"]:
            asset = assets[model["url"]]
            download(repository, asset, cache / model["url"], model["sha256"], model["bytes"])
    except (OSError, ValueError, KeyError, TypeError) as error:
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
    parser.add_argument("--source", type=Path, default=TOOLS.parents[1] / "Resources/ASRModels")
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--repository", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        raise ValueError("Invalid repository")
    index = decode_json(args.index.read_bytes())
    prepare(index, args.index, args.source, args.root, args.cache, args.repository)


if __name__ == "__main__":
    main()
