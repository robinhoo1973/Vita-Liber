#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""多源字形 vendor：Health Icons(CC0, 48栅格) + Tabler(MIT, 24栅格)。

用法：python3 design/tools/vendor_iconify.py <node_modules 根目录>
产物：design/icons/healthicons/{our}.svg、design/icons/tabler/{our}.svg
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from fluent_map import HEALTH_MAP, TABLER_MAP, MDI_MAP

ROOT = Path(__file__).resolve().parents[2]
DEST_HI = ROOT / "design/icons/healthicons"
DEST_TB = ROOT / "design/icons/tabler"
DEST_MDI = ROOT / "design/icons/mdi"


def load_iconify(pkg: str):
    data = json.loads((Path(pkg) / "icons.json").read_text())
    return data["icons"], data.get("width", 24), data.get("height", 24)


def main() -> None:
    nm = Path(sys.argv[1]).expanduser().resolve()
    hi_icons, hi_w, hi_h = load_iconify(nm / "@iconify-json/healthicons")
    tb_icons, tb_w, tb_h = load_iconify(nm / "@iconify-json/tabler")
    mdi_icons, mdi_w, mdi_h = load_iconify(nm / "@iconify-json/mdi")

    DEST_HI.mkdir(parents=True, exist_ok=True)
    DEST_TB.mkdir(parents=True, exist_ok=True)
    DEST_MDI.mkdir(parents=True, exist_ok=True)

    def write_svg(dest: Path, our: str, body: str, w: int, h: int) -> None:
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}">'
               f"{body}</svg>")
        (dest / f"{our}.svg").write_text(svg, encoding="utf-8")

    expected = set()
    n_hi = n_tb = 0
    for our, name in HEALTH_MAP.items():
        if name not in hi_icons:
            print(f"[warn] healthicons 缺失: {name}")
            continue
        write_svg(DEST_HI, our, hi_icons[name]["body"], hi_w, hi_h)
        expected.add(f"{our}.svg")
        n_hi += 1
    for f in DEST_HI.glob("*.svg"):
        if f.name not in expected:
            f.unlink()
            print(f"[prune] healthicons: {f.name}")
    for our, name in TABLER_MAP.items():
        if name not in tb_icons:
            print(f"[warn] tabler 缺失: {name}")
            continue
        write_svg(DEST_TB, our, tb_icons[name]["body"], tb_w, tb_h)
        n_tb += 1
    for f in DEST_TB.glob("*.svg"):
        if f.name.removesuffix(".svg") not in TABLER_MAP:
            f.unlink()
    n_mdi = 0
    for our, name in MDI_MAP.items():
        if name not in mdi_icons:
            print(f"[warn] mdi 缺失: {name}")
            continue
        write_svg(DEST_MDI, our, mdi_icons[name]["body"], mdi_w, mdi_h)
        n_mdi += 1
    for f in DEST_MDI.glob("*.svg"):
        if f.name.removesuffix(".svg") not in MDI_MAP:
            f.unlink()
    print(f"[ok] healthicons={n_hi} tabler={n_tb} mdi={n_mdi}")


if __name__ == "__main__":
    main()
