#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""青囊书设计资产管线：SVG 母版 → Resources/Assets.xcassets + 预览 + Swift 常量。

用法：
    python3 design/tools/generate_assets.py            # 全量生成
产物（幂等，可重复运行）：
    design/icons/src/*.svg                矢量母版（可导入 Figma/Illustrator）
    design/illustrations/src/*.svg        插画母版
    design/brand/app-icon.svg             App 图标母版
    design/previews/contact-sheet-*.png   视觉走查拼图
    design/gallery.html                   浏览器可视化索引
    Resources/Assets.xcassets/            Xcode 资产目录（随 target 编译）
    App/DesignSystem/VLIcon.swift         类型安全图标常量
依赖：pip install cairosvg pillow
"""

import json
import sys
from pathlib import Path

import cairosvg
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).parent))
from icon_library import ICONS, GROUPS, group_of
from illustration_library import ILLUSTRATIONS, APP_ICON_SVG

ROOT = Path(__file__).resolve().parents[2]
SRC_ICONS = ROOT / "design/icons/src"
SRC_ILL = ROOT / "design/illustrations/src"
SRC_BRAND = ROOT / "design/brand"
PREVIEWS = ROOT / "design/previews"
CATALOG = ROOT / "Resources/Assets.xcassets"
SWIFT_OUT = ROOT / "App/DesignSystem/VLIcon.swift"

ICON_SCALES = [(1, 24), (2, 48), (3, 72)]           # pt 基准 24
ILL_PT = (160, 120)                                  # 插画基准点尺寸
ILL_SCALES = [(1, 160, 120), (2, 320, 240), (3, 480, 360)]

INFO = {"author": "xcode", "version": 1}

# ── 色板（ui-ux-spec §3.1 token 表；light/dark）──────────────────────────────

def C(l, d=None):
    return (l, d or l)

COLORS = {
    # brand / accent
    "brand-primary":      C("0A66C2", "4A9DE8"),
    "surface-tint-start": C("E6F0FC", "1E2846"),
    "surface-tint-end":   C("F8FAFE", "141930"),
    "bg-grouped":         C("EDF0F6", "0E1225"),
    # semantic
    "semantic-success":   C("34A853", "5BB974"),
    "semantic-warning":   C("E8A13A", "F0B45C"),
    "semantic-danger":    C("D93025", "E86A5C"),
    "alert-l2":           C("E8730C"),
    # grade 来源分级（GradeBadge）
    "grade-a":            C("0A66C2"),
    "grade-b":            C("5F6368"),
    "grade-c":            C("34A853"),
    "grade-d":            C("E8A13A"),
    "grade-e":            C("9334E6"),
    "grade-self":         C("7B8794"),
    # text
    "text-primary":       C("1C1C1E", "E8EAF2"),
    "text-secondary":     C("5B5B60", "9BA3B8"),
    "text-tertiary":      C("AEAEB2", "5A6078"),
    # 成员关系色（MemberConfirmBar「关系色」提案值，待 SP 定稿）
    "member-self":        C("0A66C2", "4A9DE8"),
    "member-partner":     C("D95970", "E88A9B"),
    "member-father":      C("3B7DD8", "6FA3E8"),
    "member-mother":      C("B85497", "D683BC"),
    "member-son":         C("2FA3A0", "63C4C1"),
    "member-daughter":    C("DE8A3C", "EDAF6E"),
    "member-family":      C("6B7FD8", "94A3E8"),
}


def wrap_outline(body: str) -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
        '<g fill="none" stroke="#000" stroke-width="1.5" '
        'stroke-linecap="round" stroke-linejoin="round">' + body + "</g></svg>"
    )


def wrap_filled(body: str) -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
        f'<g fill="#000" stroke="none">{body}</g></svg>'
    )


def wrap_illu(body: str) -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 180">'
        '<g fill="none" stroke="#000" stroke-width="4" opacity=".82" '
        'stroke-linecap="round" stroke-linejoin="round">' + body + "</g></svg>"
    )


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def render_png(svg: str, out: Path, w: int, h: int | None = None) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    cairosvg.svg2png(bytestring=svg.encode(), write_to=str(out), output_width=w, output_height=h)


def hexcomp(h: str) -> dict:
    return {"alpha": "1.000", "red": f"0x{h[0:2]}", "green": f"0x{h[2:4]}", "blue": f"0x{h[4:6]}"}


def colorset(light: str, dark: str | None) -> dict:
    colors = [{"color": {"color-space": "srgb", "components": hexcomp(light)}, "idiom": "universal"}]
    if dark and dark != light:
        colors.append({
            "appearances": [{"appearance": "luminosity", "value": "dark"}],
            "color": {"color-space": "srgb", "components": hexcomp(dark)},
            "idiom": "universal",
        })
    return {"colors": colors, "info": INFO}


def imageset(png_names: list[str], template: bool) -> dict:
    images = []
    for fname in png_names:
        entry = {"filename": fname, "idiom": "universal"}
        if "@1x" in fname:
            entry["scale"] = "1x"
        elif "@2x" in fname:
            entry["scale"] = "2x"
        elif "@3x" in fname:
            entry["scale"] = "3x"
        else:
            entry["scale"] = "1x"
        images.append(entry)
    data = {"images": images, "info": INFO}
    if template:
        data["properties"] = {"template-rendering-intent": "template"}
    return data


# ── 生成流程 ────────────────────────────────────────────────────────────────

def main() -> None:
    n_icons = n_ill = 0

    # 1) 图标母版 + 目录 imagesets ------------------------------------------
    for name, spec in ICONS.items():
        gdir = SRC_ICONS / group_of(name).lower()
        gdir.mkdir(parents=True, exist_ok=True)
        outline_svg = wrap_outline(spec["body"])
        (gdir / f"{name}.svg").write_text(outline_svg, encoding="utf-8")
        iset_dir = CATALOG / "Icons" / group_of(name) / f"{name}.imageset"
        files = []
        for scale, px in ICON_SCALES:
            fn = f"{name}@{scale}x.png"
            render_png(outline_svg, iset_dir / fn, px)
            files.append(fn)
        write_json(iset_dir / "Contents.json", imageset(files, template=True))
        n_icons += 1

        if spec.get("filled"):
            fname_f = f"{name}-filled"
            filled_svg = wrap_filled(spec["filled"])
            (gdir / f"{fname_f}.svg").write_text(filled_svg, encoding="utf-8")
            iset_f = CATALOG / "Icons" / group_of(name) / f"{fname_f}.imageset"
            files_f = []
            for scale, px in ICON_SCALES:
                fn = f"{fname_f}@{scale}x.png"
                render_png(filled_svg, iset_f / fn, px)
                files_f.append(fn)
            write_json(iset_f / "Contents.json", imageset(files_f, template=True))
            n_icons += 1

    # 2) 插画 -----------------------------------------------------------------
    for name, body in ILLUSTRATIONS.items():
        svg = wrap_illu(body)
        (SRC_ILL / f"{name}.svg").write_text(svg, encoding="utf-8")
        iset_dir = CATALOG / "Illustrations" / f"{name}.imageset"
        files = []
        for scale, w, h in ILL_SCALES:
            fn = f"{name}@{scale}x.png"
            render_png(svg, iset_dir / fn, w, h)
            files.append(fn)
        write_json(iset_dir / "Contents.json", imageset(files, template=True))
        n_ill += 1

    # 3) App 图标（1024，无透明通道）-------------------------------------------
    (SRC_BRAND / "app-icon.svg").write_text(APP_ICON_SVG, encoding="utf-8")
    iconset = CATALOG / "AppIcon.appiconset"
    iconset.mkdir(parents=True, exist_ok=True)
    tmp = PREVIEWS / "appicon-1024.png"
    render_png(APP_ICON_SVG, tmp, 1024, 1024)
    img = Image.open(tmp).convert("RGB")  # iOS 图标禁止 alpha
    img.save(iconset / "AppIcon1024.png")
    write_json(iconset / "Contents.json", {
        "images": [{
            "filename": "AppIcon1024.png", "idiom": "universal",
            "platform": "ios", "size": "1024x1024",
        }],
        "info": INFO,
    })

    # 4) 色板 colorsets ---------------------------------------------------------
    write_json(CATALOG / "AccentColor.colorset/Contents.json", colorset(*COLORS["brand-primary"]))
    for cname, (l, d) in COLORS.items():
        write_json(CATALOG / "Colors" / f"{cname}.colorset/Contents.json", colorset(l, d))

    # 5) 组目录与根 Contents.json ----------------------------------------------
    for sub in ["Icons", "Illustrations", "Colors"]:
        write_json(CATALOG / sub / "Contents.json", {"info": INFO})
    for g, _ in GROUPS:
        write_json(CATALOG / "Icons" / g / "Contents.json", {"info": INFO})
    write_json(CATALOG / "Contents.json", {"info": INFO})

    # 6) Swift 常量 -------------------------------------------------------------
    def camel(s: str) -> str:
        parts = s.split("-")
        return parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:] if p)

    lines = [
        "// AUTO-GENERATED — 请勿手改。重新生成：python3 design/tools/generate_assets.py",
        "// 命名映射见 design/README.md；资产位于 Resources/Assets.xcassets（template 渲染）。",
        "",
        "import SwiftUI",
        "",
        "/// 设计系统图标唯一出口（对齐 Localization/L10n.swift 的单出口纪律）。",
        "enum VLIcon {",
    ]
    for name in ICONS:
        base = "-".join(name.split("-")[1:])
        lines.append(f"    static let {camel(base)} = Image(\"{name}\")")
        if ICONS[name].get("filled"):
            lines.append(f"    static let {camel(base)}Filled = Image(\"{name}-filled\")")
    for name in ILLUSTRATIONS:
        lines.append(f"    static let {camel(name)} = Image(\"{name}\")")
    lines += ["}", ""]
    SWIFT_OUT.parent.mkdir(parents=True, exist_ok=True)
    SWIFT_OUT.write_text("\n".join(lines), encoding="utf-8")

    print(f"[ok] icons={n_icons} illustrations={n_ill} colors={len(COLORS)}")
    build_contact_sheets()
    build_gallery()
    print("[ok] gallery -> design/gallery.html")


# ── 预览与走查 ───────────────────────────────────────────────────────────────

FONT_CACHE = {}

def _font(size: int):
    if size not in FONT_CACHE:
        try:
            FONT_CACHE[size] = ImageFont.truetype(
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", size)
        except Exception:
            FONT_CACHE[size] = ImageFont.load_default()
    return FONT_CACHE[size]


def build_contact_sheets() -> None:
    cols, cell, label_h = 10, 72, 18
    items = []
    for name in ICONS:
        items.append((name, CATALOG / "Icons" / group_of(name) /
                      f"{name}.imageset/{name}@3x.png"))
    rows = (len(items) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell, rows * (cell + label_h)), "#F4F6FA")
    draw = ImageDraw.Draw(sheet)
    for i, (name, png) in enumerate(items):
        x, y = (i % cols) * cell, (i // cols) * (cell + label_h)
        if png.exists():
            glyph = Image.open(png).convert("RGBA")
            sheet.paste(glyph, (x + (cell - glyph.width) // 2,
                                y + (cell - glyph.height) // 2), glyph)
        draw.text((x + 4, y + cell + 2), name.replace("ic-", ""),
                  fill="#333", font=_font(11))
    sheet.save(PREVIEWS / "contact-sheet-icons.png")

    cols2, cw, ch, lh = 4, 320, 240, 22
    ill_names = list(ILLUSTRATIONS)
    rows2 = (len(ill_names) + cols2 - 1) // cols2
    sheet2 = Image.new("RGB", (cols2 * cw, rows2 * (ch + lh)), "#FFFFFF")
    draw2 = ImageDraw.Draw(sheet2)
    for i, name in enumerate(ill_names):
        x, y = (i % cols2) * cw, (i // cols2) * (ch + lh)
        png = CATALOG / "Illustrations" / f"{name}.imageset/{name}@2x.png"
        if png.exists():
            im = Image.open(png).convert("RGBA")
            im.thumbnail((cw - 16, ch - 16))
            sheet2.paste(im, (x + (cw - im.width) // 2, y + (ch - im.height) // 2), im)
        draw2.text((x + 8, y + ch + 3), name, fill="#333", font=_font(14))
    sheet2.save(PREVIEWS / "contact-sheet-illustrations.png")


def build_gallery() -> None:
    def inline(svg: str) -> str:
        return svg.replace("#000", "currentColor")

    cards = []
    for g, d in GROUPS:
        cells = []
        for name in d:
            spec = ICONS[name]
            svg = inline(wrap_outline(spec["body"]))
            extra = ""
            if spec.get("filled"):
                fsvg = inline(wrap_filled(spec["filled"]))
                extra = f'<div class="pair">{svg}<span class="sep"></span>{fsvg}</div>'
            else:
                extra = f'<div class="pair">{svg}</div>'
            cells.append(f'<figure>{extra}<figcaption>{name}</figcaption></figure>')
        cards.append(f'<section><h2>{g}</h2><div class="grid">{"".join(cells)}</div></section>')

    ill_cells = "".join(
        f'<figure class="ill">{inline(wrap_illu(b))}<figcaption>{n}</figcaption></figure>'
        for n, b in ILLUSTRATIONS.items())

    html = f"""<!doctype html>
<html lang="zh-Hans"><head><meta charset="utf-8">
<title>青囊书 · 图标与插画库</title>
<style>
  :root {{ --bg:#EEF1F7; --card:#fff; --fg:#1c1c1e; --muted:#5b5b60; }}
  .dark {{ --bg:#10141f; --card:#1b2130; --fg:#e8eaf2; --muted:#9ba3b8; }}
  body {{ margin:0; padding:32px; background:var(--bg); color:var(--fg);
         font:14px/1.5 -apple-system,"PingFang SC",sans-serif; transition:.25s }}
  header {{ display:flex; align-items:center; gap:16px; max-width:1180px; margin:0 auto 20px }}
  h1 {{ font-size:20px; margin:0 }}
  button {{ margin-left:auto; border:1px solid var(--muted); background:none; color:var(--fg);
           border-radius:10px; padding:6px 14px; cursor:pointer }}
  section {{ max-width:1180px; margin:0 auto 28px; background:var(--card); border-radius:16px;
            padding:20px 24px; box-shadow:0 8px 32px rgba(80,100,180,.08) }}
  h2 {{ font-size:15px; margin:0 0 14px; color:var(--muted) }}
  .grid {{ display:flex; flex-wrap:wrap; gap:10px }}
  figure {{ width:104px; margin:0; text-align:center }}
  .pair {{ display:flex; align-items:center; justify-content:center; gap:8px;
          height:64px; border-radius:12px; background:var(--bg);
          color:#0A66C2; font-size:26px }}
  figcaption {{ font-size:11px; color:var(--muted); margin-top:6px;
               word-break:break-all; line-height:1.3 }}
  figure.ill {{ width:auto }} figure.ill svg {{ width:280px; height:auto; display:block }}
</style></head><body>
<header><h1>青囊书 · Fluent 风格图标库</h1>
<button onclick="document.body.classList.toggle('dark')">深浅切换</button></header>
{"".join(cards)}
<section><h2>Illustrations · 单色线条空态插画（240×180）</h2>
<div class="grid">{ill_cells}</div></section>
<section><h2>App Icon · 1024</h2>
<img src="previews/appicon-1024.png" width="180" style="border-radius:40px">
<p style="color:var(--muted)">母版：design/brand/app-icon.svg（青囊药袋提环 × 医书 × 医疗十字）</p></section>
</body></html>"""
    (ROOT / "design/gallery.html").write_text(html, encoding="utf-8")


if __name__ == "__main__":
    main()
