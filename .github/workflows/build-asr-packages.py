#!/usr/bin/env python3
"""Build reproducible complete ASR ZIPs from an already validated, pinned model tree."""
import argparse
import copy
from datetime import datetime
import hashlib
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import zipfile

from asr_package import (MAX_PACKAGE, MODELS, decode_json, digest_file, json_bytes,
                         manifest_files, safe_path, slug, validate_index, verify_packages)


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
    if {m["id"] for m in resolved["models"]} != MODELS:
        raise ValueError("Four resolved models are required")
    for model in resolved["models"]:
        expected = next(m for m in original["models"] if m["id"] == model["id"])
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


def build_packages(root, template, output):
    validate_index(template, complete=False)
    original, resolved, source_digest = source_manifest(root)
    output.mkdir(parents=True, exist_ok=True)
    result = copy.deepcopy(template)
    result["sourceManifestSHA256"] = source_digest
    result["packagingProfile"] = "zip-deflate9-v2"
    prepared = []
    # Validate all four source trees before creating any deliverable.
    for release in result["models"]:
        model_id = release["id"]
        model = next(m for m in resolved["models"] if m["id"] == model_id)
        if model["license"] != release["license"]:
            raise ValueError("Source/release license mismatch")
        manifest = {"formatVersion": 1, "models": [copy.deepcopy(model)],
                    "shared": copy.deepcopy(resolved["shared"]) if model_id != "zipformer" else []}
        # Download locations belong to the build cache. They must not change model ZIP
        # identity when a cache is reconstructed from an already verified Release.
        manifest["models"][0]["files"] = [{k: f[k] for k in ("role", "path", "bytes", "sha256")} for f in model["files"]]
        manifest["shared"] = [{k: f[k] for k in ("role", "path", "bytes", "sha256")} for f in manifest["shared"]]
        files = {f["path"]: checked_source(root, f) for f in manifest_files(manifest, model_id)}
        files["manifest.json"] = json_bytes(manifest)
        files["NOTICE.md"] = (root / "NOTICE.md").read_bytes()
        if release["license"] == "MIT":
            license_entry = next(f for f in model["files"] if f["role"] == "notice")
            files["LICENSE-MIT.txt"] = checked_source(root, license_entry)
        else:
            files["LICENSE-APACHE-2.0.txt"] = (root / "LICENSE-APACHE-2.0.txt").read_bytes()
        revision = release.get("artifactRevision", 2)
        if type(revision) is not int or revision < 1:
            raise ValueError("artifactRevision must be positive")
        revision = max(2, revision)  # v2 canonical manifest profile never overwrites an r1 package identity.
        built_at = release["builtAt"].replace("-", "")
        datetime.strptime(built_at, "%Y%m%d")
        name = f"{model_id}-{slug(release['version'])}-{built_at}-r{revision}.zip"
        release.update(url=name, packaging="zip", builtAt=built_at, artifactRevision=revision,
                       upstreamRevision=model["revision"], runtime="sherpa-onnx-1.13.4")
        release["expandedBytes"] = sum(len(v) if isinstance(v, bytes) else v.stat().st_size for v in files.values())
        prepared.append((release, files))
    for release, files in prepared:
        with tempfile.NamedTemporaryFile(dir=output, suffix=".zip", delete=False) as temporary:
            temporary_path = Path(temporary.name)
        try:
            print("Building " + release["url"], flush=True)
            write_zip(temporary_path, files, release["builtAt"])
            release["bytes"] = temporary_path.stat().st_size
            if release["bytes"] > MAX_PACKAGE:
                raise ValueError("Model package exceeds Release budget")
            release["sha256"] = digest_file(temporary_path)
            temporary_path.replace(output / release["url"])
        finally:
            temporary_path.unlink(missing_ok=True)
    receipt = verify_packages(result, output)
    (output / "index.json").write_bytes(json_bytes(result))
    (output / "package-validation.json").write_bytes(json_bytes(receipt))

    # Explicit baseline profile: offline Mandarin/English works before optional model downloads.
    bundle = output / "bundle/ASRModels"
    bundle.mkdir(parents=True, exist_ok=True)
    bundle_manifest = copy.deepcopy(original)
    bundle_manifest["bundledModels"] = ["zipformer"]
    (bundle / "manifest.json").write_bytes(json_bytes(bundle_manifest))
    for name in ("LICENSE-APACHE-2.0.txt", "NOTICE.md"):
        shutil.copyfile(root / name, bundle / name)
    zipformer = next(m for m in resolved["models"] if m["id"] == "zipformer")
    for item in zipformer["files"]:
        target = bundle / item["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(checked_source(root, item), target)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = build_packages(args.source_root, decode_json(args.index.read_bytes()), args.output)
        print(f"Built and verified {len(result['models'])} complete ASR packages", flush=True)
        return 0
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        print(f"ASR-BUILD-ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
