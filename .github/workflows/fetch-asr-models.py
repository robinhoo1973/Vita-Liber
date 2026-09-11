#!/usr/bin/env python3
"""Build-time only: materialize the pinned offline ASR resources; never used by the app."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile
import tarfile
import shutil
import time


def validate_entries(entries):
    seen = set()
    for item in entries:
        path = PurePosixPath(item["path"])
        if path.is_absolute() or ".." in path.parts or "\\" in item["path"] or str(path) in seen:
            raise ValueError("Invalid or duplicate resource path: " + item["path"])
        if not item["url"].startswith("https://") or not re.fullmatch(r"[a-f0-9]{64}", item["sha256"]):
            raise ValueError("Expected HTTPS and a pinned SHA-256: " + item["path"])
        if type(item["bytes"]) is not int or not 0 < item["bytes"] <= 1_100_000_000:
            raise ValueError("Invalid size: " + item["path"])
        seen.add(str(path))


def valid_file(path, item):
    if not path.is_file() or path.is_symlink() or path.stat().st_size != item["bytes"]:
        return False
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest() == item["sha256"]


def ensure_file(root, item, check_only=False):
    destination = root / item["path"]
    if not destination.resolve().is_relative_to(root.resolve()):
        raise ValueError("Resource escapes root: " + item["path"])
    if valid_file(destination, item):
        return
    if check_only:
        raise ValueError("Missing or corrupt bundled ASR asset: " + item["path"])
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, suffix=".download", delete=False) as handle:
        temporary = Path(handle.name)
    try:
        # 5WHY（CI 34655743251）：HuggingFace 瞬态丢包（curl 退出 56）使整步
        # 硬失败——--retry 2 无退避挡不住分钟级抖动。双层重试：curl 层
        # 4 次带退避（transient 错误族）+ python 层 3 轮间隔重试（跨轮
        # sleep，覆盖上游持续性抖动）。每轮 SHA-256 校验兜底，坏下载绝不落盘。
        for attempt in range(3):
            try:
                subprocess.run([
                    "curl", "--fail", "--silent", "--show-error", "--location",
                    "--retry", "4", "--retry-delay", "8",
                    "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "30",
                    "--speed-time", "60", "--speed-limit", "1024",
                    "--max-time", "600", "--max-filesize", str(item["bytes"]),
                    "--output", str(temporary), item["url"],
                ], check=True)
                break
            except subprocess.CalledProcessError as curl_error:
                if attempt == 2:
                    raise
                time.sleep(15 * (attempt + 1))
                if temporary.exists():
                    temporary.unlink(missing_ok=True)
        if not valid_file(temporary, item):
            raise ValueError("SHA-256/size mismatch: " + item["path"])
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def extract_parts(root, archive_path, config):
    files = []
    with tarfile.open(archive_path, "r:bz2") as archive:
        for part in config["parts"]:
            name = config["root"] + "/" + part["member"]
            member = archive.getmember(name)
            destination = root / part["path"]
            if not member.isfile() or not 0 < member.size <= 1_100_000_000 or not destination.resolve().is_relative_to(root.resolve()):
                raise ValueError("Invalid ASR archive member: " + name)
            destination.parent.mkdir(parents=True, exist_ok=True)
            temporary = destination.with_suffix(destination.suffix + ".extracting")
            digest = hashlib.sha256()
            try:
                with archive.extractfile(member) as source, temporary.open("wb") as target:
                    for chunk in iter(lambda: source.read(1024 * 1024), b""):
                        digest.update(chunk)
                        target.write(chunk)
                if temporary.stat().st_size != member.size:
                    raise ValueError("Truncated archive member: " + name)
                temporary.replace(destination)
            finally:
                temporary.unlink(missing_ok=True)
            files.append({"role": part["role"], "path": part["path"], "bytes": member.size,
                "sha256": digest.hexdigest(), "url": config["url"]})
    return files


def ensure_archive(root, model, previous, check_only):
    old = next((item for item in previous.get("models", []) if item["id"] == model["id"]), None)
    if old and old.get("archive", {}).get("sha256") == model["archive"]["sha256"] and old["files"]:
        expected = {(item["role"], item["path"]) for item in model["archive"]["parts"]}
        actual = {(item["role"], item["path"]) for item in old["files"]}
        if actual == expected and len(old["files"]) == len(expected) and all(valid_file(root / item["path"], item) for item in old["files"]):
            return old["files"]
    if check_only:
        raise ValueError("Missing or corrupt resolved ASR archive: " + model["id"])
    with tempfile.TemporaryDirectory(prefix="vitaliber-asr-") as directory:
        item = dict(model["archive"], path="model.tar.bz2", role="archive")
        validate_entries([item])
        ensure_file(Path(directory), item)
        # 每个文件hash取自已通过固定归档hash验证的字节；生成清单与资源一同签名。
        return extract_parts(root, Path(directory) / item["path"], model["archive"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2] / "Resources" / "ASRModels")
    parser.add_argument("--check", action="store_true", help="Verify packaged files without downloading")
    parser.add_argument("--manifest-only", action="store_true")
    args = parser.parse_args()
    raw_manifest = (args.root / "manifest.json").read_bytes()
    manifest = json.loads(raw_manifest)
    source_digest = hashlib.sha256(raw_manifest).hexdigest()
    if manifest["formatVersion"] != 1 or {m["id"] for m in manifest["models"]} != {"qwen3", "zipformer", "dolphin", "whisper"}:
        raise ValueError("Unexpected ASR manifest/version")
    entries = [entry for model in manifest["models"] for entry in model["files"]] + manifest["shared"]
    validate_entries(entries)
    total = sum(entry["bytes"] for entry in entries)
    if total > 2_000_000_000:
        raise ValueError("ASR asset budget exceeds 2 GB; re-evaluate the pinned model set")
    archives = [m for m in manifest["models"] if "archive" in m]
    for model in archives:
        validate_entries([dict(model["archive"], path="model.tar.bz2", role="archive")])
    print(f"ASR manifest: {len(entries)} pinned files ({total:,} bytes) + {len(archives)} pinned archives", flush=True)
    if args.manifest_only:
        return
    resolved_path = args.root / "resolved-manifest.json"
    previous = json.loads(resolved_path.read_text(encoding="utf-8")) if resolved_path.exists() else {}
    if previous.get("sourceDigest") != source_digest:
        previous = {}
    for model in archives:
        model["files"] = ensure_archive(args.root, model, previous, args.check)
    for entry in entries:
        ensure_file(args.root, entry, check_only=args.check)
        print("Verified " + entry["path"], flush=True)
    all_files = [file for model in manifest["models"] for file in model["files"]] + manifest["shared"]
    validate_entries(all_files)
    unpacked = sum(file["bytes"] for file in all_files)
    if unpacked > 2_000_000_000:
        raise ValueError("Unpacked ASR assets exceed 2 GB")
    if not args.check:
        manifest["sourceDigest"] = source_digest
        temporary = resolved_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        temporary.replace(resolved_path)
    print(f"Verified bundled ASR total: {unpacked:,} bytes", flush=True)


if __name__ == "__main__":
    main()
