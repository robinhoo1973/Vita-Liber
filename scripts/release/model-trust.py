#!/usr/bin/env python3
"""Verify public model metadata and generate the App-signature-protected build baseline."""
import argparse
from pathlib import Path
import sys
from asr_package import decode_json, json_bytes
from model_trust import build_baseline, verify_catalog


def _index_diff(expected, actual):
    """返回 signed(expected) 与 built(actual) 的第一条字段级差异路径(模型 id 先行)。"""
    def walk(a, b, path):
        if type(a) is not type(b):
            return f"{path}: type {type(a).__name__} != {type(b).__name__}"
        if isinstance(a, dict):
            for k in a:
                if k not in b:
                    return f"{path}.{k}: missing in built"
                d = walk(a[k], b[k], f"{path}.{k}")
                if d:
                    return d
            for k in b:
                if k not in a:
                    return f"{path}.{k}: extra in built"
            return None
        if isinstance(a, list):
            if len(a) != len(b):
                return f"{path}: list len {len(a)} != {len(b)}"
            for i, (x, y) in enumerate(zip(a, b)):
                d = walk(x, y, f"{path}[{i}]")
                if d:
                    return d
            return None
        if a != b:
            return f"{path}: {a!r} != {b!r}"
        return None
    return walk(expected, actual, "index") or "(identical)"

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["verify", "build"])
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--index", type=Path)
    parser.add_argument("--previous-catalog", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--asset-kind", default="asr")
    parser.add_argument("--content-sha256")
    args = parser.parse_args()
    try:
        root = decode_json(args.root.read_bytes())
        envelope = decode_json(args.catalog.read_bytes())
        previous = decode_json(args.previous_catalog.read_bytes()) if args.previous_catalog else None
        catalog = verify_catalog(root, envelope, previous=previous, asset_kind=args.asset_kind)
        if args.content_sha256 and catalog.get("contentSha256") != args.content_sha256:
            raise ValueError("Signed catalog contentSha256 mismatch")
        if args.index and catalog["index"] != decode_json(args.index.read_bytes()):
            # 字段级差异定位（2026-10-05 World A 排障）：报出第一条不一致路径，
            # 避免「整索引不等」盲猜（此前连红三轮各修一处才露下一处）。
            detail = _index_diff(catalog["index"], decode_json(args.index.read_bytes()))
            raise ValueError(
                "Built model index differs from the signed catalog (first diff: %s); "
                "generate a candidate and sign it first" % detail)
        if args.action == "build":
            if not args.output:
                raise ValueError("--output is required for build")
            args.output.parent.mkdir(parents=True, exist_ok=True)
            temporary = args.output.with_suffix(".tmp")
            temporary.write_bytes(json_bytes(build_baseline(root, envelope)))
            temporary.replace(args.output)
        count = len(catalog.get("index", {}).get("models", []))
        print(f"MODEL-TRUST-OK: asset={args.asset_kind}, root={catalog['rootVersion']}, catalog={catalog['catalogVersion']}, entries={count}")
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"MODEL-TRUST-ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
