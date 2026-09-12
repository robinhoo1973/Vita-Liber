#!/usr/bin/env python3
"""Prepare a complete pinned ASR tree, preferring verified Release packages as a cache."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys

from asr_package import decode_json, validate_index

TOOLS = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--source", type=Path, default=TOOLS.parents[1] / "Resources/ASRModels")
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--repository", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        raise ValueError("Invalid repository")
    index = decode_json(args.index.read_bytes())
    validate_index(index)
    args.root.mkdir(parents=True, exist_ok=True)
    args.cache.mkdir(parents=True, exist_ok=True)
    for name in ("manifest.json", "NOTICE.md", "LICENSE-APACHE-2.0.txt"):
        shutil.copyfile(args.source / name, args.root / name)
    cached = True
    for model in index["models"]:
        result = subprocess.run(["gh", "release", "download", "asr-models", "--repo", args.repository,
                                 "--pattern", model["url"], "--dir", str(args.cache), "--skip-existing"],
                                text=True, capture_output=True)
        if result.returncode:
            print("Release cache unavailable; using pinned upstream resources: " + result.stderr.strip(), flush=True)
            cached = False
            break
    if cached:
        result = subprocess.run([sys.executable, str(TOOLS / "materialize-asr-packages.py"),
                                 "--index", str(args.index), "--directory", str(args.cache),
                                 "--source-manifest", str(args.source / "manifest.json"), "--root", str(args.root)])
        if result.returncode:
            print("Release cache did not match the pinned sources; verifying/fetching upstream", flush=True)
    # This rechecks every file and the source digest; a cache never bypasses source validation.
    subprocess.run([sys.executable, str(TOOLS / "fetch-asr-models.py"), "--root", str(args.root)], check=True)


if __name__ == "__main__":
    main()
