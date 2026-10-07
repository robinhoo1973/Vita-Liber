#!/usr/bin/env python3
"""CNB 匿名读路径模块（2026-10-07 委员会：读路径实现收敛为单一模块）。

消费面：prepare-asr-source（ASR 缓存/回源热路径）、probe_cnb_resources、
test-cnb-release，以及后续任何匿名读 CNB Release 的工具。写路径与账号面
仍在 cnb_release.py（CNBReleaseClient）；本模块只做**匿名**三件事：

  1) SSR tag 页解析（fail-closed 形状门——设计文档 §3.1；此前该函数以
     runpy-of-prepare 的形式被三处消费，收敛后为直接 import）；
  2) 有界流式校验下载（sha256+size 单趟、`.downloading` 临时名 + 原子换名；
     注意与 cnb_release.download_asset 的区别——后者是整包内存式小文件口，
     本模块的 download_cnb_asset 是大文件（GB 级）口）；
  3) 有界并行批下载（平台席 2026-10-07 A 方案）：逐资产计时 + 进度输出
     （消灭 728s 黑箱），fail-fast（任一失败取消未开始者并抛）。
     并发度由调用方给定：CNB 单流实测 ~5.1MB/s，「单流限速 vs 聚合限速」
     未证实 ⇒ 默认保守取 4，测量后调。

URL 文法单源：public_download_url 自 cnb_release 导入（同簇 import 纪律，
禁止第二份 URL 规则）。
"""
import hashlib
import json
import re
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from cnb_release import public_download_url

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


def fetch_cnb_inventory(repository, tag):
    url = "https://cnb.cool/" + repository + "/-/releases/tag/" + tag
    request = urllib.request.Request(url, headers={"User-Agent": "vitaliber-asr-cache/1"})
    with urllib.request.urlopen(request, timeout=60) as response:
        html = response.read(MAX_PAGE_BYTES + 1)
    return parse_cnb_tag_page(html, repository, tag)


def download_cnb_asset(repository, tag, asset, destination, expected_sha256, expected_size):
    url = public_download_url(repository, tag, asset["name"])
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


def download_assets(models, assets, cache, repository, *, tag, parallel, download=None):
    """有界并行批下载 + 逐资产计时（fail-fast）。

    - models：索引条目列表（含 url/sha256/bytes）；assets：name→asset 映射。
    - download 可注入（测试缝），签名 (repository, asset, destination, sha256, size)；
      缺省用本模块的 download_cnb_asset（显式带 tag 的 6 参版本）。
    - 并发度 parallel ≤ 1 或单资产时退化为串行（测试确定性）。
    - 任一资产失败：取消未开始者并向上抛（缓存路径 fail-closed，回退上游）。
    """
    if download is None:
        download = lambda repo, asset, dest, sha, size: download_cnb_asset(repo, tag, asset, dest, sha, size)
    cache = Path(cache)
    cache.mkdir(parents=True, exist_ok=True)

    def _one(model):
        asset = assets[model["url"]]
        started = time.monotonic()
        download(repository, asset, cache / model["url"], model["sha256"], model["bytes"])
        # 进度可观测（2026-10-07）：此前 728s 缓存下载零输出（黑箱；CI
        # 37598832117 排障靠时间窗反推）——逐资产打印名称与耗时便于分段定位。
        print("cache asset verified: %s (%.1fs)" % (model["url"], time.monotonic() - started), flush=True)

    ordered = list(models)
    workers = max(1, min(int(parallel), len(ordered) or 1))
    if workers == 1:
        for model in ordered:
            _one(model)
        return
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(_one, model) for model in ordered]
        try:
            for future in futures:
                future.result()
        except BaseException:
            for future in futures:
                future.cancel()
            raise
