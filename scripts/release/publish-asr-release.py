#!/usr/bin/env python3
"""Verify complete signed ASR packages, then publish an immutable-assets GitHub Release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

from asr_package import decode_json, digest_file, json_bytes, validate_index, verify_packages
from model_trust import payload, payload_bytes, trusted_root, verify_catalog, verify_envelope

TAG = "asr-models"


def publication_plan(index, assets):
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


def gh(*args):
    result = subprocess.run(["gh", *args], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "GitHub CLI failed")
    return result.stdout


def api(endpoint, *, optional=False, paginate=False):
    args = ["gh", "api", endpoint]
    if paginate:
        args += ["--paginate", "--slurp"]
    for attempt in range(3):
        result = subprocess.run(args, text=True, capture_output=True)
        if result.returncode == 0:
            value = json.loads(result.stdout)
            return [item for page in value for item in page] if paginate else value
        if optional and "HTTP 404" in result.stderr:
            return None
        if attempt < 2:
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(result.stderr.strip() or "GitHub API failed")


def assets_for(repository, release_id):
    return api(f"repos/{repository}/releases/{release_id}/assets?per_page=100", paginate=True)


def find_release(repository, *, optional=False):
    # gh performs both published-tag REST and draft-tag GraphQL lookup. REST /tags
    # alone cannot resume the draft we just created.
    result = subprocess.run(["gh", "release", "view", TAG, "--repo", repository,
                             "--json", "databaseId,isDraft,url"], text=True, capture_output=True)
    if result.returncode:
        if optional and "release not found" in result.stderr.lower():
            return None
        raise RuntimeError(result.stderr.strip() or "Release lookup failed")
    value = json.loads(result.stdout)
    return {"id": value["databaseId"], "draft": value["isDraft"], "url": value["url"]}


def download_asset(repository, name, directory):
    gh("release", "download", TAG, "--repo", repository, "--pattern", name, "--dir", str(directory))
    return directory / name


def ensure_asset(repository, path, remote, *, immutable=True):
    checksum, size = digest_file(path), path.stat().st_size
    prior = next((a for a in remote if a["name"] == path.name), None)
    if prior:
        same = prior["size"] == size and prior.get("digest") == "sha256:" + checksum
        if not prior.get("digest") and prior["size"] == size:
            with tempfile.TemporaryDirectory() as directory:
                same = digest_file(download_asset(repository, path.name, Path(directory))) == checksum
        if same:
            print("Reusing " + path.name, flush=True)
            return
        if immutable:
            raise ValueError("Refusing to overwrite immutable Release asset: " + path.name)
    print("Uploading " + path.name, flush=True)
    args = ["release", "upload", TAG, str(path), "--repo", repository]
    if prior:
        args.append("--clobber")  # Only the verified catalog/index pointers may change.
    gh(*args)


def publish(args):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        raise ValueError("Invalid GitHub repository")
    index = decode_json(args.index.read_bytes())
    root_envelope = decode_json(args.root.read_bytes())
    catalog_envelope = decode_json(args.catalog.read_bytes())
    catalog = verify_catalog(root_envelope, catalog_envelope)
    if catalog["index"] != index or index["baseUrl"] != f"https://github.com/{args.repository}/releases/download/{TAG}":
        raise ValueError("Package index/repository differs from the signed authorization")
    receipt = verify_packages(index, args.directory)
    # All validation above precedes the first mutating remote operation.
    release = find_release(args.repository, optional=True)
    if release is None:
        with tempfile.TemporaryDirectory() as directory:
            notes = Path(directory) / "notes.md"
            notes.write_text("# Offline ASR model packages\n\nComplete model ZIPs, signed update metadata, and per-file verification.\n"
                             "App versions are defined by `version.txt`; this resource release is independent.\n")
            target = args.target or os.environ.get("GITHUB_SHA") or subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
            gh("release", "create", TAG, "--repo", args.repository, "--target", target,
               "--draft", "--latest=false", "--title", "ASR model packages", "--notes-file", str(notes))
        release = find_release(args.repository)
    remote = assets_for(args.repository, release["id"])
    publication_plan(index, remote)  # Detect content collisions before uploading anything.

    if any(a["name"] == "catalog.json" for a in remote):
        with tempfile.TemporaryDirectory() as directory:
            old_envelope = decode_json(download_asset(args.repository, "catalog.json", Path(directory)).read_bytes())
            old_payload = payload(old_envelope)
            old_root_file = args.catalog.parent / f"{old_payload['rootVersion']}.root.json"
            old_root = trusted_root(decode_json(old_root_file.read_bytes()))
            verify_envelope(old_envelope, old_root, "catalog")
            if old_payload["rootVersion"] > catalog["rootVersion"]:
                raise ValueError("Release root rollback rejected")
            if old_payload["rootVersion"] == catalog["rootVersion"]:
                verify_catalog(root_envelope, catalog_envelope, previous=old_envelope)
    for model in index["models"]:
        ensure_asset(args.repository, args.directory / model["url"], remote)

    root_files = sorted(args.catalog.parent.glob("[0-9]*.root.json"), key=lambda p: int(p.name.split(".")[0]))
    if not root_files:
        raise ValueError("Versioned trust root assets are required")
    previous = None
    for root_file in root_files:
        envelope = decode_json(root_file.read_bytes())
        checked = trusted_root(envelope, previous=previous)
        if root_file.name != f"{checked['version']}.root.json":
            raise ValueError("Root asset name/version mismatch")
        ensure_asset(args.repository, root_file, remote)
        previous = envelope

    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        versioned_catalog = directory / f"{catalog['catalogVersion']}.catalog.json"
        versioned_catalog.write_bytes(args.catalog.read_bytes())
        ensure_asset(args.repository, versioned_catalog, remote)
        validation = directory / f"{catalog['catalogVersion']}.package-validation.json"
        validation.write_bytes(json_bytes(receipt))
        ensure_asset(args.repository, validation, remote)
        # Exact index.json name regardless of the local input filename.
        public_index = directory / "index.json"
        public_index.write_bytes(json_bytes(index))
        ensure_asset(args.repository, public_index, remote, immutable=False)
        ensure_asset(args.repository, args.catalog, remote, immutable=False)
    current_assets = assets_for(args.repository, release["id"])
    if any(value == "upload" for value in publication_plan(index, current_assets).values()):
        raise ValueError("A required model asset is still missing")
    gh("release", "edit", TAG, "--repo", args.repository, "--draft=false", "--latest=false")
    url = f"https://github.com/{args.repository}/releases/tag/{TAG}"
    print(url, flush=True)
    return url


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["plan", "publish"])
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--assets", type=Path)
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--catalog", type=Path)
    parser.add_argument("--repository")
    parser.add_argument("--target")
    args = parser.parse_args()
    try:
        if args.action == "plan":
            if not args.assets:
                raise ValueError("--assets is required")
            print(json.dumps(publication_plan(decode_json(args.index.read_bytes()), decode_json(args.assets.read_bytes()))))
        else:
            if not all((args.directory, args.root, args.catalog, args.repository)):
                raise ValueError("--directory, --root, --catalog and --repository are required")
            publish(args)
        return 0
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        print(f"ASR-RELEASE-ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
