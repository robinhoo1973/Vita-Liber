#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Lucide 字形固化脚本（ISC License）。

用法：python3 design/tools/vendor_lucide.py <lucide icons 目录>

<lucide icons 目录>：lucide-static npm 包（node_modules/lucide-static/icons）
或 GitHub lucide-icons/lucide 的 icons/ 目录。

按 LUCIDE 映射复制上游图标并重命名为青囊书内部名（ic-*）→ design/icons/lucide/。
固化后重跑：python3 design/tools/generate_assets.py
"""

import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# our_name -> lucide 包内图标名
LUCIDE_MAP = {
    "ic-organ-bone": "bone",
    "ic-medicine-box": "pill-bottle",
    "ic-organ-hand": "hand",
    "ic-organ-donation": "heart-handshake",
    "ic-refill": "package-plus",
}


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("用法：python3 design/tools/vendor_lucide.py <lucide icons 目录>")
    src = Path(sys.argv[1])
    out = ROOT / "design/icons/lucide"
    out.mkdir(parents=True, exist_ok=True)

    for ours, upstream in LUCIDE_MAP.items():
        s = src / f"{upstream}.svg"
        if not s.exists():
            print(f"[skip] {upstream}.svg 不存在（{s}）")
            continue
        shutil.copy(s, out / f"{ours}.svg")
        print(f"[ok] {upstream}.svg -> {ours}.svg")

    print("提示：许可见 design/icons/lucide/NOTICE.md；出处由 generate_assets.py 写入 provenance.json")


if __name__ == "__main__":
    main()
