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
import time
import tempfile

from asr_package import decode_json, validate_index, verify_packages, decode_manifest_data_file
from asr_overview import OVERVIEW_NAME, build as build_overview, verify as verify_overview
from asr_release_page import render_release_body
from cnb_release import (CNBReleaseClient, CNBReleaseError, print_masked_upload_prefix,
                         RecordingUploadTransport, release_notes_for_tag)
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


def remote_catalog_name(cnb_assets):
    """固定名数据文件(2026-10-06 业主单一 JSON 架构):index.json 是唯一目录资产。"""
    return "manifest.json" if any((a.get("name") or "") == "manifest.json" for a in cnb_assets) else None


def check_remote_catalog_chain(client, args, catalog, remote_assets=None):
    """Reject rollback/equivocation against the remote fixed-name index.json.

    2026-10-06 单一 JSON 架构:远端固定名 index.json(签名信封)匿名下载、
    对本地根验签后比对单调性——TUF fixed-name 形态(无版本化副本),回滚
    防护由 payload 内 rootVersion/catalogVersion 单调闸 + 客户端持久化
    回滚守卫共同承担;同版本异字节 = 等价歧义硬错(语义不变)。

    返回远端旧载荷（或 None）——发布页动态段据此生成「与上一版相比」增量行
    （委员会 S3，2026-10-07）；首个发布无基线 = 整行省略。
    """
    remote = client.list_assets(TAG) if remote_assets is None else remote_assets
    name = remote_catalog_name(remote)
    if name is None:
        return None  # 首个发布:无可比对基线（发布页增量行整行省略）
    with tempfile.TemporaryDirectory() as temporary:
        destination = Path(temporary) / name
        client.download_asset(TAG, name, destination, max_bytes=2 << 20)
        old_envelope = decode_json(destination.read_bytes())
        old_payload = payload(old_envelope)
        # 版本化根(N.root.json)所在目录:默认与候选目录同址(本地/测试),
        # CI 显式 --root-store Resources/ASRModelUpdates(2026-10-07 审查:
        # 此前 CI 从不暂存根文件 → 有远端基线时必 FileNotFoundError,
        # 固定名首发布早退掩盖了该回归)。
        root_store = getattr(args, "root_store", None)
        store = Path(root_store) if root_store else args.catalog.parent
        old_root_file = store / f"{old_payload['rootVersion']}.root.json"
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
    return old_payload


def publish(args, client):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        raise ValueError("Invalid CNB repository")
    index = decode_manifest_data_file(args.index)
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
    previous_payload = check_remote_catalog_chain(client, args, catalog, remote_assets=remote)

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
    client.upload_immutable(TAG, args.catalog, "manifest.json",
                            hashlib.sha256(args.catalog.read_bytes()).hexdigest(), overwrite=True)
    current_names = {a["name"] for a in normalize_assets(client.list_assets(TAG))}
    missing = [m["url"] for m in index["models"] if m["url"] not in current_names]
    if "manifest.json" not in current_names:
        missing.append("manifest.json")
    if missing:
        raise ValueError("A required model asset is still missing: " + missing[0])
    # 人读概览（2026-10-07 委员会恢复批）：固定名 overview.json 与 manifest 同批
    # 覆盖发布——纯函数自签名载荷（可重跑同字节），自验不通过或上传失败仅告警：
    # 展示面绝不阻塞数据发布（医疗 v3 同纪律；非权威件，安全判定一律以签名为准）。
    try:
        payload_bytes = _envelope_payload_bytes(args.catalog)
        overview_bytes = build_overview(payload_bytes)
        verify_overview(overview_bytes, payload_bytes)
        overview_path = args.catalog.parent / OVERVIEW_NAME
        overview_path.write_bytes(overview_bytes)
        client.upload_immutable(TAG, overview_path, OVERVIEW_NAME,
                                hashlib.sha256(overview_bytes).hexdigest(), overwrite=True)
        document = json.loads(overview_bytes)
        print("overview.json 已发布：families=%d tiers=%d bytes=%d"
              % (document["totals"]["families"], document["totals"]["tiers"],
                 document["totals"]["bytes"]), flush=True)
    except (CNBReleaseError, ValueError, OSError, KeyError, TypeError) as error:
        print("::warning::overview.json 生成/上传失败(不阻塞发布): " + str(error),
              file=sys.stderr)
    # 发布页正文(委员会 S3 设计,2026-10-07):永久头(三语模板)+ 动态段(版本三元组/
    # 家族×档位统计/增量行——全部取自签名载荷,零新文案、零墙钟)。提交点之后刷新;
    # 失败仅告警:页面正文是展示面,绝不阻塞数据发布(与医疗纪律同构)。
    try:
        _, permanent_body = release_notes_for_tag(TAG)
        page_body = render_release_body(permanent_body, catalog, previous_payload)
        client.update_release_body(TAG, page_body)
        print("发布页正文已刷新", flush=True)
    except (CNBReleaseError, ValueError, OSError, KeyError, TypeError) as error:
        print("::warning::发布页正文刷新失败(不阻塞发布): " + str(error), file=sys.stderr)
    # README 同步触发(业主 2026-10-07 方案 B:发布器 → api_trigger → CNB 管线)。
    # 通知通道失败不阻塞发布:README 是索引提示面,同步管线幂等且可手动按钮重跑。
    try:
        receipt = client.start_readme_sync(TAG)
        sn = str(receipt.get("sn"))
        print("readme-sync 已触发: sn=" + sn, flush=True)
        _confirm_readme_sync(client, sn)
    except (CNBReleaseError, ValueError, OSError) as error:
        print("::warning::README 同步触发失败(不阻塞发布,可手动重同步): " + str(error),
              file=sys.stderr)
    print(f"https://cnb.cool/{args.repository}/-/releases/tag/{TAG}", flush=True)
    return f"https://cnb.cool/{args.repository}/-/releases/tag/{TAG}"


def _confirm_readme_sync(client, sn, attempts=3, interval=10):
    """下游确认（平台席 2026-10-07）：触发成功 ≠ 同步成功——有界轮询 build 状态。

    非 success / 查询异常一律 ::warning::（展示面不阻塞发布；业主「README 未更新」
    的观测盲区由此闭环：日志将出现明确的「readme-sync 完成: status=success」）。
    """
    for attempt in range(1, attempts + 1):
        try:
            status = client.readme_sync_status(sn)
        except (CNBReleaseError, ValueError, OSError, KeyError, TypeError, RuntimeError) as error:
            print("::warning::readme-sync 状态查询失败(不阻塞发布): " + str(error),
                  file=sys.stderr)
            return
        state = str(status.get("status", ""))
        if state == "success":
            print("readme-sync 完成: status=success sn=" + sn, flush=True)
            return
        if attempt < attempts:
            time.sleep(interval)
    print("::warning::readme-sync 未在 %d 次查询内完成(最后状态=%s, sn=%s)——可手动重同步"
          % (attempts, state, sn), file=sys.stderr)


def _envelope_payload_bytes(catalog_path):
    import base64 as _base64
    raw = decode_json(Path(catalog_path).read_bytes())
    if isinstance(raw, dict) and "payload" in raw and "signatures" in raw:
        return _base64.b64decode(raw["payload"])
    return Path(catalog_path).read_bytes()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["plan", "publish"])
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--assets", type=Path)
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--root-store", type=Path,
                        help="版本化根目录(N.root.json 所在;默认=catalog 同目录)")
    parser.add_argument("--catalog", type=Path)
    parser.add_argument("--repository")
    args = parser.parse_args()
    try:
        if args.action == "plan":
            if not args.assets:
                raise ValueError("--assets is required")
            assets = normalize_assets(decode_json(args.assets.read_bytes()))
            print(json.dumps(publication_plan(decode_manifest_data_file(args.index), assets)))
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
