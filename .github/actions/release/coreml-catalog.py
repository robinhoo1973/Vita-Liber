#!/usr/bin/env python3
"""Write the bundled Core ML catalog from the compiled model artifact.

Xcode compiles ``Resources/CoreMLModels/<name>.mlmodel`` to
``<name>.mlmodelc`` (a directory). This script selects the largest file inside
the compiled directory as the integrity target, computes sha256/bytes, and
writes the runtime ``catalog.json`` next to the compiled model.

Why the largest file: a compiled CoreML model is a directory whose weight blob
is the dominant file; its name varies across coremlcompiler versions
(weights.bin, coremldata.bin, ...). Picking the largest file is deterministic
for a given artifact and avoids hard-coding a version-specific name. The app
verifies that file's size + sha256 before loading.

Usage:
  python3 coreml-catalog.py --model-dir <compiled.mlmodelc> \\
      --source <catalog.json> --output <catalog.json>
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def largest_file(directory: Path) -> Path:
    files = [path for path in directory.rglob("*") if path.is_file()]
    if not files:
        raise SystemExit(f"compiled model has no files: {directory}")
    return max(files, key=lambda path: (path.stat().st_size, str(path)))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    catalog = json.loads(args.source.read_text(encoding="utf-8"))
    target = largest_file(args.model_dir)
    data = target.read_bytes()
    relative = target.relative_to(args.model_dir).as_posix()
    catalog["modelFile"] = args.model_dir.name
    catalog["hashFile"] = relative
    catalog["sha256"] = hashlib.sha256(data).hexdigest()
    catalog["bytes"] = len(data)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True)
                           + "\n", encoding="utf-8")
    print(f"catalog: {args.output} model={catalog['modelFile']} "
          f"hashFile={relative} bytes={len(data)} sha256={catalog['sha256'][:12]}…")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
