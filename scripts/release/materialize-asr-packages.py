#!/usr/bin/env python3
"""Reuse verified Release ZIPs as a pinned build cache, without trusting their source claims."""
import argparse
import contextlib
import copy
import hashlib
from pathlib import Path
import shutil
import sys
import tempfile
import zipfile

from asr_package import decode_json, digest_file, json_bytes, manifest_files, verify_packages
from asr_envelope import decrypt_package, env_package_key, identity_string


@contextlib.contextmanager
def _package_zip(index, directory, release):
    """打开包为 zip:加密信封(2026-10-05 R1)先解密到临时文件,明文直通。"""
    path = directory / release["url"]
    if release.get("encryption") != "aes256gcm-v1":
        try:
            archive = zipfile.ZipFile(path)
        except (zipfile.BadZipFile, zipfile.LargeZipFile) as error:
            raise ValueError("Invalid ZIP package: " + release["url"]) from error
        with archive:
            yield archive
        return
    temporary = tempfile.NamedTemporaryFile(prefix="asr-materialize-", suffix=".zip", delete=False)
    temporary_path = Path(temporary.name)
    try:
        decrypt_package(env_package_key(),
                        identity_string(release["id"], release.get("variant"), release["version"], release.get("artifactRevision")),
                        path, temporary_path)
        with zipfile.ZipFile(temporary_path) as archive:
            yield archive
    finally:
        temporary_path.unlink(missing_ok=True)


def materialize(index_path, directory, source_manifest, root):
    index = decode_json(index_path.read_bytes())
    verify_packages(index, directory)
    raw = source_manifest.read_bytes()
    pins = decode_json(raw)
    resolved = copy.deepcopy(pins)
    for release in index["models"]:
        pin = next((m for m in resolved["models"]
                    if m["id"] == release["id"] and m.get("variant") == release.get("variant")), None)
        if pin is None:
            raise ValueError("Pinned manifest has no entry for (id, variant): " + release["id"])
        with _package_zip(index, directory, release) as archive:
            package = decode_json(archive.read("manifest.json"))
            model = package["models"][0]
            expected = pin.get("archive", {}).get("parts", pin["files"])
            if ({(f["role"], f["path"]) for f in model["files"]}
                    != {(f["role"], f["path"]) for f in expected}):
                raise ValueError("Release package does not implement the pinned model inventory")
            if pin.get("archive"):
                if model.get("archive", {}).get("sha256") != pin["archive"]["sha256"]:
                    raise ValueError("Release archive does not match the pinned upstream archive")
            else:
                expected_files = {(f["role"], f["path"]): (f["bytes"], f["sha256"]) for f in pin["files"]}
                if any(expected_files[(f["role"], f["path"])] != (f["bytes"], f["sha256"]) for f in model["files"]):
                    raise ValueError("Release weights do not match pinned source hashes")
            shared = pins["shared"] if release["id"] != "zipformer" else []
            # VAD 清单是文件**集合**身份(与上方模型文件集合口径一致)——按
            # 元组集合比对,源清单顺序调整不得误拒已验证缓存(2026-10-05 审查)。
            if {(f["path"], f["sha256"], f["bytes"]) for f in package.get("shared", [])} != {
                    (f["path"], f["sha256"], f["bytes"]) for f in shared}:
                raise ValueError("Release VAD does not match pinned source")
            # World A(2026-10-05):遗留包内清单无 variant 键——身份绑定由
            # 文件清单与 pin 的 (role,path,bytes,sha256) 全等校验承担,内清单
            # 档位键缺失时按 None 匹配(与 verify_package 同源容差)。
            for item in manifest_files(package, release["id"], model.get("variant")):
                destination = root / item["path"]
                destination.parent.mkdir(parents=True, exist_ok=True)
                if not destination.resolve().is_relative_to(root.resolve()) or destination.is_symlink():
                    raise ValueError("Build cache escapes root")
                if destination.is_file() and destination.stat().st_size == item["bytes"] and digest_file(destination) == item["sha256"]:
                    continue
                temporary = destination.with_suffix(destination.suffix + ".materializing")
                try:
                    with archive.open(item["path"]) as source, temporary.open("wb") as target:
                        shutil.copyfileobj(source, target, length=1024**2)
                    temporary.replace(destination)
                finally:
                    temporary.unlink(missing_ok=True)
            original_urls = {(f["role"], f["path"]): f["url"] for f in pin["files"]}
            pin["files"] = [dict(f, url=pin["archive"]["url"] if pin.get("archive") else original_urls[(f["role"], f["path"])])
                            for f in model["files"]]
    root.mkdir(parents=True, exist_ok=True)
    (root / "manifest.json").write_bytes(raw)
    resolved["sourceDigest"] = hashlib.sha256(raw).hexdigest()
    (root / "resolved-manifest.json").write_bytes(json_bytes(resolved))
    for name in ("NOTICE.md", "LICENSE-APACHE-2.0.txt"):
        shutil.copyfile(source_manifest.parent / name, root / name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--source-manifest", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    try:
        materialize(args.index, args.directory, args.source_manifest, args.root)
        print("Verified model packages materialized as a pinned build cache")
        return 0
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        print(f"ASR-CACHE-ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
