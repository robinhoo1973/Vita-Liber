#!/usr/bin/env python3
"""One-time seed: transfer verified historical model assets from GitHub Releases to
the CNB resource Release (2026-10-03 plan Task 2).

--plan downloads every asset and verifies size + SHA-256 locally without any CNB
write; --execute uploads only after the whole set verified. GitHub Release is
read-only here and is not used by any active pipeline afterwards.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from cnb_release import CNBReleaseClient, CNBReleaseError, UrllibCNBTransport

ALLOWED_TAGS = {"asr-models", "llama-models", "llama-xcframework"}


class SeedAssetError(RuntimeError):
    pass


def gh_download_asset(github_repository, tag, name, destination, max_bytes):
    result = subprocess.run(["gh", "release", "download", tag, "--repo", github_repository,
                             "--pattern", name, "--dir", str(destination)],
                            text=True, capture_output=True)
    if result.returncode:
        raise SeedAssetError("GitHub download failed for " + name + ": "
                             + (result.stderr.strip() or result.stdout.strip()))
    path = Path(destination) / name
    if not path.is_file() or path.is_symlink() or path.stat().st_size > max_bytes:
        raise SeedAssetError("GitHub asset out of bounds: " + name)
    return path


def legacy_github_name(cnb_name, variant):
    """旧 GitHub 资产名 = CNB variant 段名去掉 `-{variant}` 一段。

    例如 zipformer-large-2023-02-20-20260912-r2.zip → zipformer-2023-02-20-20260912-r2.zip。
    只用于一次性 seed 的 GitHub 读取面;sha256 全量校验兜底,推导错误 fail-closed。
    """
    return cnb_name.replace("-" + variant + "-", "-", 1)


def asr_expectations(catalog_path, legacy_index_path):
    """签名目录模型条目 → {(cnb 名): (github 旧名, size, sha256)},按 sha 联结旧索引。"""
    catalog = json.loads(Path(catalog_path).read_bytes())
    payload = json.loads(base64.b64decode(catalog["payload"]))
    legacy = {m["sha256"]: m for m in json.loads(Path(legacy_index_path).read_bytes())["models"]}
    expectations = {}
    for model in payload["index"]["models"]:
        legacy_model = legacy.get(model["sha256"])
        if legacy_model is None:
            raise SeedAssetError("No legacy GitHub asset matches " + model["id"] + " " + model["url"])
        expectations[model["url"]] = (legacy_github_name(model["url"], model["variant"]),
                                      model["bytes"], model["sha256"])
    return expectations


def plan_assets(tag, source, expectations, work_dir):
    """下载并逐字节校验全部资产;任何失配即抛,不产生任何 CNB 写入。"""
    staged = {}
    for cnb_name, (github_name, size, sha256) in expectations.items():
        path = source(tag, github_name, Path(work_dir), size)
        if path.stat().st_size != size:
            raise SeedAssetError("Size mismatch for " + github_name)
        if hashlib.sha256(path.read_bytes()).hexdigest() != sha256:
            raise SeedAssetError("Digest mismatch for " + github_name)
        staged[cnb_name] = path
    return staged


def execute_plan(client, tag, staged, expectations):
    """唯一写面:全部校验通过后逐资产上传(不可变;碰撞硬拒绝)。"""
    for cnb_name, path in staged.items():
        _, size, sha256 = expectations[cnb_name]
        client.upload_immutable(tag, path, cnb_name, sha256)
    print("Seeded %d assets to %s" % (len(staged), tag), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--legacy-index", type=Path, required=True)
    parser.add_argument("--github-repository", required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--plan", action="store_true", help="Download + verify only (read-only, default)")
    parser.add_argument("--execute", action="store_true", help="Verify then upload (requires CNB_RESOURCE_REPOSITORY + CNB_TOKEN)")
    args = parser.parse_args()
    try:
        if args.tag not in ALLOWED_TAGS:
            raise SeedAssetError("Unknown resource tag: " + args.tag)
        expectations = asr_expectations(args.catalog, args.legacy_index)
        if not expectations:
            raise SeedAssetError("No assets to seed")
        Path(args.work_dir).mkdir(parents=True, exist_ok=True)
        source = lambda tag, name, destination, max_bytes: gh_download_asset(
            args.github_repository, tag, name, destination, max_bytes)
        staged = plan_assets(args.tag, source, expectations, args.work_dir)
        if args.execute:
            token = os.environ.get("CNB_TOKEN")
            repository = os.environ.get("CNB_RESOURCE_REPOSITORY")
            if not token or not repository:
                raise SeedAssetError("CNB_RESOURCE_REPOSITORY and CNB_TOKEN are required for --execute")
            execute_plan(CNBReleaseClient(repository, token, UrllibCNBTransport()),
                         args.tag, staged, expectations)
        else:
            print("plan only: %d verified assets staged (no CNB writes)" % len(staged), flush=True)
        return 0
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, SeedAssetError, CNBReleaseError) as error:
        print("SEED-ERROR: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
