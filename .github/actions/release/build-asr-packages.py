#!/usr/bin/env python3
"""Build reproducible complete ASR ZIPs from an already validated, pinned model tree."""
import argparse
import copy
from datetime import datetime, timezone
import hashlib
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import zipfile

from asr_package import (MAX_PACKAGE, MODELS, decode_json, decode_manifest_data_file, digest_file, json_bytes,
                         manifest_files, safe_path, slug, validate_index, verify_packages)
from asr_envelope import ENCRYPTION_SCHEME, encrypt_package, env_package_key, identity_string, is_envelope_file


def derive_version(policy, revision):
    """全自动升级批（2026-10-07）：上游修订滚动时的版本标签派生（config versionPolicy）。

    dateSource=filename → revision 本身即版本串（github-release 资产名版本段）；
    否则 = {prefix}-{短修订}（prefix 缺省时为短修订）。与 slug() 组合后进入
    包名/身份键——同修订必得同标签，不同修订必得不同标签。
    """
    policy = policy or {}
    if policy.get("dateSource") == "filename":
        return revision
    prefix = policy.get("prefix") or ""
    short = revision[:8]
    return (prefix + "-" + short) if prefix else short


def resolved_model(resolved, model_id, variant):
    match = next((m for m in resolved["models"]
                  if m["id"] == model_id and m.get("variant") == variant), None)
    if match is None:
        raise ValueError("Resolved model missing for (id, variant): " + model_id + "/" + str(variant))
    return match


def source_manifest(root):
    raw = (root / "manifest.json").read_bytes()
    original = decode_json(raw)
    resolved_path = root / "resolved-manifest.json"
    if resolved_path.exists():
        resolved = decode_json(resolved_path.read_bytes())
        if resolved.get("sourceDigest") != hashlib.sha256(raw).hexdigest():
            raise ValueError("Resolved manifest does not match the pinned source manifest")
    else:
        resolved = original
    if not ({m["id"] for m in resolved["models"]} <= MODELS):
        raise ValueError("Unknown ASR model family in resolved manifest")
    for model in resolved["models"]:
        expected = next((m for m in original["models"]
                         if m["id"] == model["id"] and m.get("variant") == model.get("variant")), None)
        if expected is None:
            raise ValueError("Resolved model missing from pinned manifest: " + model["id"])
        inventory = expected.get("archive", {}).get("parts", expected["files"])
        if ({(f["role"], f["path"]) for f in model["files"]}
                != {(f["role"], f["path"]) for f in inventory} or model["revision"] != expected["revision"]):
            raise ValueError("Resolved model inventory/revision mismatch")
    return original, resolved, hashlib.sha256(raw).hexdigest()


def checked_source(root, item):
    path = root / safe_path(item["path"])
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError("Model source escapes root")
    if not path.is_file() or path.stat().st_size != item["bytes"] or digest_file(path) != item["sha256"]:
        raise ValueError("Missing or corrupt source: " + item["path"])
    return path


def write_zip(path, files, built_at):
    date = datetime.strptime(built_at, "%Y%m%d")
    if not 1980 <= date.year <= 2107:
        raise ValueError("Package date is outside ZIP timestamp range")
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9, allowZip64=True) as archive:
        for name in sorted(files):
            info = zipfile.ZipInfo(safe_path(name), (date.year, date.month, date.day, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | 0o644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            # ZipInfo.compress_level is public in 3.13; its earlier spelling is kept for 3.12 CI hosts.
            info._compresslevel = 9
            source = files[name]
            with archive.open(info, "w", force_zip64=True) as destination:
                if isinstance(source, bytes):
                    destination.write(source)
                else:
                    with source.open("rb") as handle:
                        shutil.copyfileobj(handle, destination, length=1024**2)


def build_packages(root, template, output, reuse=None, version_policies=None):
    original, resolved, source_digest = source_manifest(root)
    # 模板家族集必须与源清单一致(数据驱动齐备合同:新家族随数据文件自然收紧)。
    validate_index(template, complete=False,
                   expected_families={m["id"] for m in original["models"]})
    output.mkdir(parents=True, exist_ok=True)
    result = copy.deepcopy(template)
    result["sourceManifestSHA256"] = source_digest
    result["packagingProfile"] = "zip-deflate9-v2"
    prepared = []
    # Validate every source tree before creating any deliverable.
    for release in result["models"]:
        model_id = release["id"]
        model = resolved_model(resolved, model_id, release.get("variant"))
        if model["license"] != release["license"]:
            raise ValueError("Source/release license mismatch")
        manifest = {"formatVersion": 1, "models": [copy.deepcopy(model)],
                    "shared": copy.deepcopy(resolved["shared"]) if model_id != "zipformer" else []}
        # Download locations belong to the build cache. They must not change model ZIP
        # identity when a cache is reconstructed from an already verified Release.
        manifest["models"][0]["files"] = [{k: f[k] for k in ("role", "path", "bytes", "sha256")} for f in model["files"]]
        manifest["shared"] = [{k: f[k] for k in ("role", "path", "bytes", "sha256")} for f in manifest["shared"]]
        files = {f["path"]: checked_source(root, f) for f in manifest_files(manifest, model_id, release.get("variant"))}
        files["manifest.json"] = json_bytes(manifest)
        files["NOTICE.md"] = (root / "NOTICE.md").read_bytes()
        if release["license"] == "MIT":
            license_entry = next(f for f in model["files"] if f["role"] == "notice")
            files["LICENSE-MIT.txt"] = checked_source(root, license_entry)
        else:
            files["LICENSE-APACHE-2.0.txt"] = (root / "LICENSE-APACHE-2.0.txt").read_bytes()
        current_rev = model["revision"]
        template_rev = release.get("upstreamRevision")
        if template_rev is not None and template_rev != current_rev:
            # 全自动升级批（2026-10-07 业主裁决）：解析器滚动了源 revision →
            # 动态派生新身份（version=config versionPolicy / builtAt=当日 /
            # artifactRevision=r+1）。新包名 ⇒ 缓存必不命中 ⇒ 强制重建；
            # 身份键含 version ⇒ 加密信封 key/nonce 随之变化（新修订=新字节）。
            policy = (version_policies or {}).get((release["id"], release.get("variant")))
            release["version"] = derive_version(policy, current_rev)
            built_at = datetime.now(timezone.utc).strftime("%Y%m%d")
            revision = max(2, int(release.get("artifactRevision", 1)) + 1)
        else:
            revision = release.get("artifactRevision", 2)
            if type(revision) is not int or revision < 1:
                raise ValueError("artifactRevision must be positive")
            # v2 canonical manifest profile never overwrites an r1 package identity.
            revision = max(2, revision)
            built_at = release["builtAt"].replace("-", "")
        datetime.strptime(built_at, "%Y%m%d")
        # 文件名含 variant 段:同 id 多档同名互覆在打包公式层即被排除
        # (2026-10-05 委员会;validate_index 的跨条目 url 唯一性是第二道闸)。
        name = f"{model_id}-{slug(release['variant'])}-{slug(release['version'])}-{built_at}-r{revision}.zip"
        release.update(url=name, packaging="zip", builtAt=built_at, artifactRevision=revision,
                       upstreamRevision=model["revision"], runtime="sherpa-onnx-1.13.4")
        prepared.append((release, files))
    for release, files in prepared:
        # 复用已验证 Release ZIP（2026-09-13 审查加固）：重建的字节取决于
        # runner zlib 版本——镜像升级的 deflate 差异会让重建包与已签名
        # sha256 不符，阻塞 TestFlight。签名目录授权同内容时直接复用
        # 发布物，确定性承诺不依赖 zlib 实现。候选（未签名模板无 sha256）
        # 仍走重建。
        if reuse is not None:
            cached = Path(reuse) / release["url"]
            if (cached.is_file() and not cached.is_symlink() and release.get("sha256")
                    and digest_file(cached) == release["sha256"]):
                shutil.copyfile(cached, output / release["url"])
                release["bytes"] = cached.stat().st_size
                # R1 声明随实际字节(2026-10-05 审查修正):缓存物为加密信封时把
                # encryption 对齐为 aes256gcm-v1——模板未含该键时目录会声明
                # 明文包而字节是信封字节(App 跳过解密直接解压必失败)。
                release["encryption"] = ENCRYPTION_SCHEME if is_envelope_file(cached) else release.get("encryption")
                # expandedBytes 保留签名模板值,不按现源树重算(CI 37266485372
                # 实证:遗留 zip 内清单无 variant 键,现源树 manifest 已带
                # variant,重算差字节致「Expanded byte count mismatch」)。
                print("Reusing verified Release ZIP " + release["url"], flush=True)
                continue
        with tempfile.NamedTemporaryFile(dir=output, suffix=".zip", delete=False) as temporary:
            temporary_path = Path(temporary.name)
        encrypted_path = Path(str(temporary_path) + ".enc")
        try:
            print("Building " + release["url"], flush=True)
            write_zip(temporary_path, files, release["builtAt"])
            # 构建分支:expandedBytes 按实际写入的 zip 条目字节和计算
            # (files 即条目内容,与 write_zip 同源)。
            release["expandedBytes"] = sum(
                len(v) if isinstance(v, bytes) else v.stat().st_size for v in files.values())
            if temporary_path.stat().st_size > MAX_PACKAGE:
                raise ValueError("Model package exceeds Release budget")
            # R1(2026-10-05 业主指令):下载包必须加密+压缩。zip 整体进
            # aes256gcm-v1 信封(确定性——同内容同信封字节,R2 哈希比对与
            # reuse 缓存都不受 runner zlib 差异影响);index sha256/bytes 覆盖
            # 信封字节,App 侧先验 sha 再解密再解压。缺 ASR_PACKAGE_KEY = 硬红。
            key = env_package_key()
            encrypt_package(key, identity_string(release["id"], release.get("variant"), release["version"], release.get("artifactRevision")),
                            temporary_path, encrypted_path)
            release["encryption"] = ENCRYPTION_SCHEME
            release["bytes"] = encrypted_path.stat().st_size
            if release["bytes"] > MAX_PACKAGE:
                raise ValueError("Encrypted model package exceeds Release budget")
            release["sha256"] = digest_file(encrypted_path)
            encrypted_path.replace(output / release["url"])
        finally:
            temporary_path.unlink(missing_ok=True)
            encrypted_path.unlink(missing_ok=True)
    receipt = verify_packages(result, output, expected_families={m["id"] for m in original["models"]})
    (output / "index.json").write_bytes(json_bytes(result))
    (output / "package-validation.json").write_bytes(json_bytes(receipt))

    # Explicit baseline profile: offline Mandarin/English works before optional model downloads.
    # 离线基线剖面由数据文件声明（2026-10-05 目录驱动：源清单 bundledModels 是唯一事实源，
    # 脚本不再写死随包档位——多档化后随包只取声明档，避免基线体积随目录档数膨胀）。
    bundle = output / "bundle/ASRModels"
    bundle.mkdir(parents=True, exist_ok=True)
    # S-M7：随包清单必须与钉版源清单一致（仅多出 bundledModels 键）——
    # fetch-asr-models.require_same_source_manifest 在 App 构建侧逐字段比对，
    # 任何裁剪/改写即硬错；随包档位由 App 侧按 bundledModels 声明解析。
    bundle_manifest = copy.deepcopy(original)
    declared = original.get("bundledModels")
    if not isinstance(declared, list) or not declared:
        raise ValueError("Source manifest must declare bundledModels")
    (bundle / "manifest.json").write_bytes(json_bytes(bundle_manifest))
    for name in ("LICENSE-APACHE-2.0.txt", "NOTICE.md"):
        shutil.copyfile(root / name, bundle / name)
    for declaration in declared:
        bundled = resolved_model(resolved, declaration["id"], declaration.get("variant"))
        for item in bundled.get("files", []):
            target = bundle / item["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(checked_source(root, item), target)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--reuse-directory", type=Path)
    parser.add_argument("--config", type=Path,
                        help="模型 config（versionPolicy 来源；全自动升级批）")
    args = parser.parse_args()
    try:
        policies = {}
        if args.config is not None:
            config = decode_json(args.config.read_bytes())
            for entry in config.get("models", []):
                policies[(entry["id"], entry.get("variant"))] = entry.get("versionPolicy") or {}
        result = build_packages(args.source_root, decode_manifest_data_file(args.index), args.output,
                                reuse=args.reuse_directory, version_policies=policies)
        print(f"Built and verified {len(result['models'])} complete ASR packages", flush=True)
        return 0
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        print(f"ASR-BUILD-ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
