#!/usr/bin/env python3
"""Validate all adopted ASR ZIPs without extracting or executing their payloads."""
import argparse
from pathlib import Path
import sys
from asr_package import decode_json, json_bytes, verify_packages


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    try:
        receipt = verify_packages(decode_json(args.index.read_bytes()), args.directory)
        if args.receipt:
            args.receipt.parent.mkdir(parents=True, exist_ok=True)
            args.receipt.write_bytes(json_bytes(receipt))
        for model in receipt["models"]:
            print(f"VERIFIED {model['id']}: {model['bytes']} bytes, SHA-256 {model['sha256']}", flush=True)
        return 0
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        print(f"ASR-PACKAGE-ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
