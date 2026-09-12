#!/usr/bin/env python3
"""Verify public model metadata and generate the App-signature-protected build baseline."""
import argparse
from pathlib import Path
import sys
from asr_package import decode_json, json_bytes
from model_trust import build_baseline, verify_catalog


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["verify", "build"])
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--index", type=Path)
    parser.add_argument("--previous-catalog", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        root = decode_json(args.root.read_bytes())
        envelope = decode_json(args.catalog.read_bytes())
        previous = decode_json(args.previous_catalog.read_bytes()) if args.previous_catalog else None
        catalog = verify_catalog(root, envelope, previous=previous)
        if args.index and catalog["index"] != decode_json(args.index.read_bytes()):
            raise ValueError("Built model index differs from the signed catalog; generate a candidate and sign it first")
        if args.action == "build":
            if not args.output:
                raise ValueError("--output is required for build")
            args.output.parent.mkdir(parents=True, exist_ok=True)
            temporary = args.output.with_suffix(".tmp")
            temporary.write_bytes(json_bytes(build_baseline(root, envelope)))
            temporary.replace(args.output)
        print(f"MODEL-TRUST-OK: root {catalog['rootVersion']}, catalog {catalog['catalogVersion']}, {len(catalog['index']['models'])} packages")
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"MODEL-TRUST-ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
