#!/usr/bin/env python3
"""Prepare a complete pinned ASR tree, preferring verified CNB Release packages as a cache.

2026-10-03 cutover Task 3: the reuse cache reads the public CNB tag-page inventory
(anonymous, fail-closed on SSR shape drift) and downloads attachments anonymously.
GitHub Release is used only by the one-time seed migration. When the CNB cache is
unavailable the pinned upstream resources are fetched instead (a cache never
bypasses source validation).
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

from asr_package import decode_manifest_data_file, validate_index
# 匿名读路径单一模块（2026-10-07 委员会）：SSR 解析/校验下载/有界并行批下载
# 收敛进 cnb_read；本文件不再内联传输实现（此前三处 runpy-of-prepare 消费）。
from cnb_read import download_assets, fetch_cnb_inventory as _fetch_cnb_inventory

TOOLS = Path(__file__).resolve().parent
TAG = "asr-models"


def fetch_cnb_inventory(repository):
    """prepare 面兼容封装：固定本链 tag 的匿名库存读取（cnb_read 单源）。"""
    return _fetch_cnb_inventory(repository, TAG)

# 仓库根探测:逐级向上找 CoreKit/Sources/Domain 锚点(与 fetch-asr-models.py
# 同纪律——禁止按固定层级 parents[N] 假设;2026-10-05 审查整改)。
REPO_ROOT = TOOLS
while REPO_ROOT != REPO_ROOT.parent and not (REPO_ROOT / "CoreKit" / "Sources" / "Domain").is_dir():
    REPO_ROOT = REPO_ROOT.parent


def prepare(index, index_path, source, root, cache, repository, *,
            inventory=fetch_cnb_inventory, download=None, parallel=4):
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
        # 有界并行批下载（cnb_read.download_assets）：默认 4 路，逐资产计时；
        # download 注入缝保持 (repo, asset, dest, sha, size) 5 参签名。
        download_assets(index["models"], assets, cache, repository,
                        tag=TAG, parallel=parallel, download=download)
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
    parser.add_argument("--parallel", type=int, default=4,
                        help="CNB 缓存并行下载路数（默认 4；CNB 限速形态未证实，保守起步）")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        raise ValueError("Invalid repository")
    # 两态读取(2026-10-06 单一 JSON 架构):仓库面 manifest.json 为签名信封
    index = decode_manifest_data_file(args.index)
    prepare(index, args.index, args.source, args.root, args.cache, args.repository, parallel=args.parallel)


if __name__ == "__main__":
    main()
