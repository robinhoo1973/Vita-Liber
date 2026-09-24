#!/usr/bin/env python3
"""The App release version is owned by version.txt, independently of GitHub Releases."""
import argparse
from pathlib import Path
import re
import sys


def read_version(path: Path) -> str:
    raw = path.read_bytes()
    if len(raw) > 128:
        raise ValueError("version.txt is too large")
    value = raw.decode("utf-8-sig").strip()
    if len(value) > 64 or not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", value):
        raise ValueError("version.txt must contain one major.minor.patch version (for example 0.0.1)")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version-file", type=Path, default=Path("version.txt"))
    parser.add_argument("--run-number", type=int, required=True)
    parser.add_argument("--run-attempt", type=int, required=True)
    parser.add_argument("--code-hash", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        version = read_version(args.version_file)
        if args.run_number < 1 or args.run_attempt < 1:
            raise ValueError("build number and attempt must be positive")
        if not re.fullmatch(r"[0-9a-f]{8,40}", args.code_hash):
            raise ValueError("invalid commit hash")
        build = f"{args.run_number:03d}.{args.run_attempt}"
        with args.output.open("a", encoding="utf-8") as output:
            output.write(f"version={version}\nbuild={build}\nhash={args.code_hash}\n")
        print(f"version.txt → Version {version} | Build {build} | Code Hash {args.code_hash}")
        return 0
    except (OSError, UnicodeError, ValueError) as error:
        print(f"::error::App version configuration: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
