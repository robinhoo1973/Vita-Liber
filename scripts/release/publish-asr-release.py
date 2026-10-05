#!/usr/bin/env python3
"""Verify complete signed ASR packages, then publish immutable assets to a CNB Release.

2026-10-03 cutover (docs/superpowers/specs/2026-10-03-cnb-resource-only-cutover-design.md):
GitHub remains the build/CI platform; the Release publisher writes only to the CNB
resource repository. The fixed `catalog.json` alias and `index.json` are no longer
uploaded — clients obtain the highest numeric versioned catalog from the tag-page
inventory; the alias is not an authority.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

from asr_package import decode_json, json_bytes, validate_index, verify_packages
from cnb_release import CNBReleaseClient, CNBReleaseError, print_masked_upload_prefix, RecordingUploadTransport
from model_trust import payload, payload_bytes, trusted_root, verify_catalog, verify_envelope

TAG = "asr-models"


def publication_plan(index, assets):
    """Detect content collisions before uploading anything.

    `assets` uses the GitHub-style shape (name/size/digest); CNB inventory is
    normalized by `normalize_assets` before this call.
    """
    validate_index(index)
    names = [a["name"] for a in assets]
    if len(set(names)) != len(names):
        raise ValueError("Ambiguous duplicate Release assets")
    by_name = {a["name"]: a for a in assets}
    result = {}
    for model in index["models"]:
        asset = by_name.get(model["url"])
        if asset is None:
            result[model["url"]] = "upload"
        elif asset["size"] != model["bytes"] or (asset.get("digest") and asset["digest"] != "sha256:" + model["sha256"]):
            raise ValueError("Immutable asset has different content: " + model["url"])
        else:
            result[model["url"]] = "reuse" if asset.get("digest") else "verify"
    return result


def normalize_assets(cnb_assets):
    """Map CNB inventory entries to the plan shape (sha256 digest when declared)."""
    result = []
    for asset in cnb_assets:
        algo = asset.get("hash_algo") or asset.get("hashAlgo") or ""
        value = asset.get("hash_value") or asset.get("hashValue") or ""
        result.append({"name": asset.get("name"),
                       "size": asset.get("size"),
                       "digest": ("sha256:" + value) if algo == "sha256" and value else None})
    return result


def highest_remote_catalog(cnb_assets):
    """Highest numeric versioned catalog name (N.catalog.json), None when none exist.

    2026-10-06 单一 JSON 架构后仅用于历史资产面(旧 N.catalog.json)兼容
    判读;新架构远端目录资产为固定名 index.json,见 remote_catalog_name。
    """
    pattern = re.compile(r"^([1-9][0-9]*)\.catalog\.json$")
    candidates = []
    for asset in cnb_assets:
        match = pattern.fullmatch(asset.get("name") or "")
        if match:
            candidates.append((int(match.group(1)), asset["name"]))
    return max(candidates)[1] if candidates else None


def remote_catalog_name(cnb_assets):
    """固定名数据文件(2026-10-06 业主单一 JSON 架构):index.json 是唯一目录资产。"""
    return "index.json" if any((a.get("name") or "") == "index.json" for a in cnb_assets) else None


def check_remote_catalog_chain(client, args, catalog, remote_assets=None):
    """Reject rollback/equivocation against the remote fixed-name index.json.

    2026-10-06 单一 JSON 架构:远端固定名 index.json(签名信封)匿名下载、
    对本地根验签后比对单调性——TUF fixed-name 形态(无版本化副本),回滚
    防护由 payload 内 rootVersion/catalogVersion 单调闸 + 客户端持久化
    回滚守卫共同承担;同版本异字节 = 等价歧义硬错(语义不变)。
    """
    remote = client.list_assets(TAG) if remote_assets is None else remote_assets
    name = remote_catalog_name(remote)
    if name is None:
        return  # 首个发布:无可比对基线
    with tempfile.TemporaryDirectory() as temporary:
        destination = Path(temporary) / name
        client.download_asset(TAG, name, destination, max_bytes=2 << 20)
        old_envelope = decode_json(destination.read_bytes())
        old_payload = payload(old_envelope)
        old_root_file = args.catalog.parent / f"{old_payload['rootVersion']}.root.json"
        old_root = trusted_root(decode_json(old_root_file.read_bytes()))
        verify_envelope(old_envelope, old_root, "catalog")
        if old_payload["rootVersion"] > catalog["rootVersion"]:
            raise ValueError("Release root rollback rejected")
        # 目录版本号是 CI 全局单调计数(与根轮换无关)——跨根轮换也不得回退:
        # 旧根签的旧目录被重签进新根若沿用更小/相同版本号,客户端同根回滚门
        # 与基线楼层都拦不住条目回滚(2026-10-05 审查;发布侧补上这道门)。
        if old_payload.get("catalogVersion", 0) > catalog["catalogVersion"]:
            raise ValueError("Catalog version rollback rejected across root rotation")
        if old_payload.get("catalogVersion", 0) == catalog["catalogVersion"]:
            local_envelope = decode_json(args.catalog.read_bytes())
            if payload_bytes(local_envelope) != payload_bytes(old_envelope):
                raise ValueError("Catalog same-version equivocation rejected across root rotation")
        if old_payload["rootVersion"] == catalog["rootVersion"]:
            verify_catalog(decode_json(args.root.read_bytes()), decode_json(args.catalog.read_bytes()),
                           previous=old_envelope)


def publish(args, client):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        raise ValueError("Invalid CNB repository")
    index = decode_json(args.index.read_bytes())
    root_envelope = decode_json(args.root.read_bytes())
    catalog_envelope = decode_json(args.catalog.read_bytes())
    catalog = verify_catalog(root_envelope, catalog_envelope)
    # 目录必须钉 CNB 资源基址(GitHub 发布面已停用,cutover 定案 §5);
    # 与客户端 catalog() 的 baseUrl==root.assetBaseURL 断言同构。
    expected_base = f"https://cnb.cool/{args.repository}/-/releases/download/{TAG}"
    if catalog["index"] != index or index.get("baseUrl") != expected_base:
        raise ValueError("Package index/repository differs from the signed authorization")
    receipt = verify_packages(index, args.directory)
    # All validation above precedes the first mutating remote operation.
    remote = client.list_assets(TAG)
    check_remote_catalog_chain(client, args, catalog, remote_assets=remote)

    # 业主规则(2026-10-05):与 CNB 已有最新文件 hash 比对——相同跳过上传,
    # 不同则更新上传(overwrite)。App 侧始终按签名目录 sha256 校验,同名异内容
    # 的中间态 fail-closed,不构成安全放松。计划计算(publication_plan)只服务
    # `plan` 子命令;发布路径以 upload_immutable 为唯一规则owner——
    # 此前的 pre-flight 硬错会把「不同才更新上传」路径变成永久红(2026-10-05 审查)。
    for model in index["models"]:
        client.upload_immutable(TAG, args.directory / model["url"], model["url"], model["sha256"], overwrite=True)

    # 单一 JSON 架构(2026-10-06 业主裁定):CNB 只承载模型包 + index.json
    # (签名信封,固定名,payload 内单调 catalogVersion——TUF fixed-name
    # 形态)。包级签名验证由载荷内逐条目 packageSignature(Ed25519 对包
    # sha256 摘要的 2-of-3 多重签名)承担,App 侧验摘要签名 + 摘要匹配。
    # 固定名 + overwrite:远端同名存在时 check_remote_catalog_chain 的单调
    # 闸保证新版本号更高;客户端持久化回滚守卫防重放。
    client.upload_immutable(TAG, args.catalog, "index.json",
                            hashlib.sha256(args.catalog.read_bytes()).hexdigest(), overwrite=True)
    current_names = {a["name"] for a in normalize_assets(client.list_assets(TAG))}
    missing = [m["url"] for m in index["models"] if m["url"] not in current_names]
    if "index.json" not in current_names:
        missing.append("index.json")
    if missing:
        raise ValueError("A required model asset is still missing: " + missing[0])
    print(f"https://cnb.cool/{args.repository}/-/releases/tag/{TAG}", flush=True)
    return f"https://cnb.cool/{args.repository}/-/releases/tag/{TAG}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["plan", "publish"])
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--assets", type=Path)
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--catalog", type=Path)
    parser.add_argument("--repository")
    args = parser.parse_args()
    try:
        if args.action == "plan":
            if not args.assets:
                raise ValueError("--assets is required")
            assets = normalize_assets(decode_json(args.assets.read_bytes()))
            print(json.dumps(publication_plan(decode_json(args.index.read_bytes()), assets)))
        else:
            if not all((args.directory, args.root, args.catalog)):
                raise ValueError("--directory, --root and --catalog are required")
            repository = args.repository or os.environ.get("CNB_RESOURCE_REPOSITORY")
            token = os.environ.get("CNB_TOKEN")
            if not repository:
                raise ValueError("--repository or CNB_RESOURCE_REPOSITORY is required")
            if not token:
                raise ValueError("CNB_TOKEN is required for publish")
            transport = RecordingUploadTransport()
            client = CNBReleaseClient(repository, token, transport)
            publish(args, client)
            print_masked_upload_prefix(transport)
        return 0
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, CNBReleaseError) as error:
        print(f"ASR-RELEASE-ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
