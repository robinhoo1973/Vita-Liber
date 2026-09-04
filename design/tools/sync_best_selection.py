#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""将 design/icons/src 中的精选母版同步为 Xcode 资源。

与 generate_assets.py 的 185 枚生成基线不同，本工具消费
design/icons/best_selection.json 中的 211 枚去重精选清单。它只读取设计母版，
生成 Resources/Assets.xcassets、VLIcon.swift 和 provenance.json，避免手改产物。
"""

from __future__ import annotations

import json

from swift_ident import swift_identifier
import shutil
from datetime import date
from pathlib import Path

import cairosvg


ROOT = Path(__file__).resolve().parents[2]
SRC_ICONS = ROOT / "design/icons/src"
SELECTION = ROOT / "design/icons/best_selection.json"
CATALOG = ROOT / "Resources/Assets.xcassets"
SWIFT_OUT = ROOT / "App/DesignSystem/VLIcon.swift"
PROVENANCE = ROOT / "design/icons/provenance.json"

GROUPS = {
    "tab": "Tab",
    "common": "Common",
    "medical": "Medical",
    "symptoms": "Symptoms",
    "members": "Members",
    "security": "Security",
    "pro": "Pro",
    "equipment": "Equipment",
    "organs": "Organs",
}
GROUP_ORDER = list(GROUPS)
SCALES = (1, 2, 3)
INFO = {"author": "xcode", "version": 1}


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def imageset_contents(name: str) -> dict:
    return {
        "images": [
            {"filename": f"{name}@{scale}x.png", "idiom": "universal", "scale": f"{scale}x"}
            for scale in SCALES
        ],
        "info": INFO,
    }




def load_selection() -> list[dict]:
    selection = json.loads(SELECTION.read_text(encoding="utf-8"))
    icons = selection["icons"]
    if len(icons) != selection["count"]:
        raise ValueError(f"selection count mismatch: {len(icons)} != {selection['count']}")
    keys = [f"{entry['group']}/{entry['name']}" for entry in icons]
    if len(keys) != len(set(keys)):
        raise ValueError("selection contains duplicate group/name entries")
    names = [entry["name"] for entry in icons]
    if len(names) != len(set(names)):
        raise ValueError("selection contains duplicate Xcode asset names")
    return icons


def render_icons(icons: list[dict]) -> None:
    active: dict[str, set[str]] = {group: set() for group in GROUPS}
    for entry in icons:
        group = entry["group"]
        name = entry["name"]
        if group not in GROUPS:
            raise ValueError(f"unknown group: {group}")
        source = SRC_ICONS / group / f"{name}.svg"
        if not source.exists():
            raise FileNotFoundError(source)
        active[group].add(name)
        imageset = CATALOG / "Icons" / GROUPS[group] / f"{name}.imageset"
        imageset.mkdir(parents=True, exist_ok=True)
        for child in imageset.iterdir():
            if child.suffix == ".png":
                child.unlink()
        for scale in SCALES:
            output = imageset / f"{name}@{scale}x.png"
            cairosvg.svg2png(
                url=str(source),
                write_to=str(output),
                output_width=48 * scale,
                output_height=48 * scale,
            )
        write_json(imageset / "Contents.json", imageset_contents(name))

    icons_root = CATALOG / "Icons"
    for group, display_group in GROUPS.items():
        group_dir = icons_root / display_group
        group_dir.mkdir(parents=True, exist_ok=True)
        for imageset in group_dir.glob("*.imageset"):
            if imageset.stem not in active[group]:
                shutil.rmtree(imageset)
        write_json(group_dir / "Contents.json", {"info": INFO})
    write_json(icons_root / "Contents.json", {"info": INFO})


def render_swift(icons: list[dict]) -> None:
    lines = [
        "// AUTO-GENERATED — 请勿手改。重新生成：python3 design/tools/sync_best_selection.py",
        "// 精选图标母版见 design/icons/src；出处见 design/icons/provenance.json。",
        "",
        "import SwiftUI",
        "",
        "/// 青囊书精选图标唯一出口。",
        "enum VLIcon {",
    ]
    for entry in icons:
        lines.append(f'    static let {swift_identifier(entry["name"])} = Image("{entry["name"]}")')
    for illustration in sorted((ROOT / "design/illustrations/src").glob("*.svg")):
        name = illustration.stem
        lines.append(f'    static let {swift_identifier(name)} = Image("{name}")')
    lines += ["}", ""]
    SWIFT_OUT.write_text("\n".join(lines), encoding="utf-8")


def render_provenance(icons: list[dict]) -> None:
    assets = {}
    for entry in icons:
        # 落库闭环（审查问题 D）：origin 一律归一化为仓库内自引用，
        # 外部来源保留在 source/upstream/license 字段，不再依赖本机挂载路径。
        repo_origin = f"design/icons/src/{entry['group']}/{entry['name']}.svg"
        assets[entry["name"]] = {
            "source": entry.get("source", "curated"),
            "upstream": entry.get("upstream"),
            "license": entry.get("license"),
            "origin": repo_origin,
            "palette": entry.get("palette"),
            "status": entry.get("status"),
        }
    for illustration in sorted((ROOT / "design/illustrations/src").glob("*.svg")):
        assets[illustration.stem] = {"source": "own", "upstream": None}
    write_json(PROVENANCE, {
        "generated": str(date.today()),
        "selection": "design/icons/best_selection.json",
        "glyph_license": "Fluent MIT / Health Icons CC0 / Lucide ISC / Material Symbols Apache-2.0 / Font Awesome CC-BY-4.0 / project-owned",
        "notice": "design/icons/NOTICE.md",
        "counts": {
            "total": len(assets),
            "icons": len(icons),
            "illustrations": len(assets) - len(icons),
        },
        "assets": assets,
    })


def freeze_selection() -> None:
    """落库闭环：把 best_selection.json 的 originPath 归一化为仓库内自引用。
    外部挂载路径仅用于精选过程；冻结后任何机器（无 OneDrive 挂载）均可复现。"""
    selection = json.loads(SELECTION.read_text(encoding="utf-8"))
    changed = 0
    for entry in selection["icons"]:
        repo_path = f"design/icons/src/{entry['group']}/{entry['name']}.svg"
        if entry.get("originPath") != repo_path:
            entry["originPath"] = repo_path
            changed += 1
    if changed:
        selection["frozen"] = True
        write_json(SELECTION, selection)
        print(f"[freeze] originPath 已归一化为仓库内自引用（{changed} 条）")
    else:
        print("[freeze] 已冻结，无需变更")


def main() -> None:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--freeze", action="store_true",
                    help="落库闭环：将 originPath 归一化为仓库内自引用后同步")
    args = ap.parse_args()
    if args.freeze:
        freeze_selection()
    icons = load_selection()
    render_icons(icons)
    render_swift(icons)
    render_provenance(icons)
    print(f"[ok] best icons={len(icons)} resources=3x{len(icons)}")


if __name__ == "__main__":
    main()
