#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""青囊书设计资产管线（Fluent 彩色瓷砖风）。

风格：渐变圆角瓷砖底 + 白色字形 + 顶部高光/底部内阴影（参照 Fluent icon pack 视觉语言）。
字形来源优先级：Fluent(MIT) → Health Icons(CC0) → Tabler(MIT) → 自绘补位；AI/vision 等特例由项目自有字形覆盖。
用法：python3 design/tools/generate_assets.py    # 全量生成（幂等）

产物：
    design/icons/src/*.svg            瓷砖母版
    design/illustrations/src/*.svg    插画母版
    design/brand/app-icon.svg         App 图标母版
    design/icons/provenance.json      字形出处清单（审计用）
    design/previews/contact-sheet-*   走查拼图
    design/gallery.html               浏览器索引
    Resources/Assets.xcassets/        Xcode 资产目录
    App/DesignSystem/VLIcon.swift     Swift 常量
依赖：pip install cairosvg pillow
"""

import json
import re
import sys
from datetime import date
from pathlib import Path

import cairosvg
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).parent))
from icon_library import ICONS, GROUPS, group_of, COLORED, ACCENTS
from illustration_library import ILLUSTRATIONS, APP_ICON_SVG
from fluent_map import FLUENT, HEALTH_MAP, TABLER_MAP, MDI_MAP, LUCIDE, MATERIAL, FONTAWESOME

ROOT = Path(__file__).resolve().parents[2]
SRC_ICONS = ROOT / "design/icons/src"
FLUENT_DIR = ROOT / "design/icons/fluent"
HEALTH_DIR = ROOT / "design/icons/healthicons"
LUCIDE_DIR = ROOT / "design/icons/lucide"
TABLER_DIR = ROOT / "design/icons/tabler"
MDI_DIR = ROOT / "design/icons/mdi"
MATERIAL_DIR = ROOT / "design/icons/materialsymbols"
FA_DIR = ROOT / "design/icons/fontawesome"
SRC_ILL = ROOT / "design/illustrations/src"
SRC_BRAND = ROOT / "design/brand"
PREVIEWS = ROOT / "design/previews"
CATALOG = ROOT / "Resources/Assets.xcassets"
SWIFT_OUT = ROOT / "App/DesignSystem/VLIcon.swift"

TILE_SCALES = [(1, 48), (2, 96), (3, 144)]           # 瓷砖基准 48pt
ILL_SCALES = [(1, 160, 120), (2, 320, 240), (3, 480, 360)]
INFO = {"author": "xcode", "version": 1}

# ── 瓷砖渐变色（top-left → bottom-right）─────────────────────────────────────

BRAND_BLUE = ("#3F8EE8", "#1E5FC0")
ROSE = ("#FF6578", "#DE3350")
AMBER = ("#FFAE3D", "#EF7A0E")
VIOLET = ("#9C6BFF", "#6432CE")
GREEN = ("#35C08C", "#11895F")
SKY = ("#38A3E8", "#1773C6")
BLUE = ("#5B8DEF", "#3A63D6")
SLATE = ("#7D89A4", "#57637D")
DARKSLATE = ("#56627D", "#37425A")
INDIGO = ("#6474E8", "#3D4BC2")
RED = ("#FF5A6E", "#D62841")

GROUP_DEFAULT = {
    "Tab": BRAND_BLUE, "Common": ("#6C8FE8", "#3F63C4"), "Medical": SKY,
    "Symptoms": BLUE, "Members": BLUE, "Security": INDIGO, "Pro": VIOLET,
    "Equipment": SKY, "Organs": SKY,
}

OVERRIDES = {
    # Tab 五色（参照参考图的多彩排布）
    "ic-tab-home": BRAND_BLUE, "ic-tab-records": ROSE, "ic-tab-reminders": AMBER,
    "ic-tab-assistant": VIOLET, "ic-tab-me": GREEN,
    # 通用操作语义色
    "ic-add": GREEN, "ic-delete": ROSE, "ic-check-circle": GREEN, "ic-sync": GREEN,
    "ic-photo": GREEN, "ic-tag": GREEN, "ic-thumbs-up": GREEN, "ic-person-add": GREEN,
    "ic-close": SLATE, "ic-chevron-left": SLATE, "ic-chevron-right": SLATE,
    "ic-chevron-down": SLATE, "ic-more": SLATE, "ic-filter": SLATE,
    "ic-keypad-delete": SLATE, "ic-archive": SLATE, "ic-settings": SLATE,
    "ic-clock": SLATE, "ic-thumbs-down": SLATE,
    "ic-camera": DARKSLATE, "ic-eye": DARKSLATE, "ic-eye-off": DARKSLATE,
    "ic-cloud-off": ("#98A1B3", "#6B7488"), "ic-device": SLATE, "ic-restore-purchase": SLATE,
    "ic-sym-custom": SLATE,
    "ic-calendar": BLUE, "ic-edit": BLUE, "ic-scan-document": BLUE,
    "ic-observe-frame": BLUE, "ic-share": BLUE, "ic-export": BLUE, "ic-import": BLUE,
    "ic-info": BLUE, "ic-help": BLUE, "ic-folder": BLUE, "ic-timeline": BLUE,
    "ic-prescription": BLUE, "ic-doctor": BLUE,
    "ic-star": ("#FFC53D", "#EFA415"),
    "ic-warning": AMBER, "ic-pill": AMBER,
    "ic-error": ROSE, "ic-mic": ROSE, "ic-bookmark": ROSE, "ic-stop-octagon": ROSE,
    "ic-waveform": VIOLET, "ic-headset": VIOLET,
    # 医疗
    "ic-imaging-ecg": ROSE, "ic-medicine-box": ROSE, "ic-emergency-card": RED,
    "ic-blood-drop": RED, "ic-sos": RED,
    "ic-vaccine": ("#2FBDB3", "#0E8A81"),
    "ic-allergy": ("#FF8AB3", "#E8518A"),
    "ic-thermometer": ("#FF8A65", "#E85B3D"),
    "ic-vitals-chart": GREEN, "ic-appointment": GREEN, "ic-refill": GREEN,
    # 症状宫格
    "ic-sym-stool": ("#A5764F", "#7C5230"), "ic-sym-urine": ("#FFC53D", "#EFA415"),
    "ic-sym-skin": ("#FF9AA8", "#E86A7E"), "ic-sym-swelling": ("#FF8A65", "#E85B3D"),
    "ic-sym-generic": ROSE, "ic-sym-secretion": VIOLET,
    # 成员关系色
    "ic-member-self": BRAND_BLUE, "ic-member-partner": ROSE,
    "ic-member-father": SKY, "ic-member-mother": ("#E869A9", "#C43E85"),
    "ic-member-son": GREEN, "ic-member-daughter": AMBER, "ic-member-family": BLUE,
    # 检查设备 / 器官扩展
    "ic-ct": BLUE, "ic-mri": INDIGO, "ic-xray": DARKSLATE, "ic-ultrasound": SKY,
    "ic-blood-pressure": ROSE, "ic-blood-sugar": AMBER, "ic-surgery": SLATE,
    "ic-ointment": SKY, "ic-herbal": GREEN, "ic-ward-bed": BLUE,
    "ic-wheelchair": BLUE, "ic-inhaler": ("#2FBDB3", "#0E8A81"),
    "ic-organ-heart": ("#E0475C", "#B02338"), "ic-organ-lungs": ("#FF8AB3", "#E8518A"),
    "ic-organ-liver": ("#A5764F", "#7C5230"), "ic-organ-stomach": AMBER,
    "ic-organ-kidney": ("#DE7A68", "#B84E3E"), "ic-organ-intestine": ("#FF9AA8", "#E86A7E"),
    "ic-organ-brain": VIOLET, "ic-organ-bone": SLATE, "ic-organ-ear": SLATE,
    "ic-organ-mouth": ROSE, "ic-organ-nose": SKY, "ic-organ-eye": BLUE,
    "ic-organ-hand": SKY, "ic-organ-foot": SLATE,
    "ic-organ-tooth": ("#2FBDB3", "#0E8A81"), "ic-organ-ear": SLATE,
    # 器官/器械扩展 V1.8
    "ic-organ-lungs": ("#FF8AB3", "#E8518A"), "ic-organ-liver": ("#A5764F", "#7C5230"),
    "ic-organ-kidney": ("#DE7A68", "#B84E3E"), "ic-organ-mouth": ROSE,
    "ic-organ-nose": SKY, "ic-organ-tooth": ("#2FBDB3", "#0E8A81"),
    "ic-organ-joints": SLATE, "ic-organ-spine": INDIGO, "ic-organ-skull": SLATE,
        "ic-organ-blood-cells": RED, "ic-organ-donation": ROSE,
    "ic-organ-thyroid": SKY, "ic-organ-throat": ROSE,
    "ic-organ-prostate": INDIGO, "ic-organ-bladder": AMBER,
    "ic-thermometer-digital": SKY, "ic-medicines": GREEN, "ic-medicine-bottle": SKY,
    "ic-syringe-vaccine": ("#2FBDB3", "#0E8A81"), "ic-hearing-aid": SLATE,
    "ic-intravenous-drip": SKY, "ic-ventilator": INDIGO, "ic-oxygen-tank": ("#2FBDB3", "#0E8A81"),
    "ic-ambulance": ROSE, "ic-crutches": SLATE, "ic-pulse-oximeter": INDIGO,
    "ic-test-tubes": SKY, "ic-microscope": INDIGO, "ic-bandage-adhesive": ("#FFD8A8", "#F0A415"),
    "ic-ppe-mask": ("#2FBDB3", "#0E8A81"), "ic-ppe-gloves": ("#2FBDB3", "#0E8A81"),
    "ic-urine-sample": AMBER,
    # 安全 / Pro
    "ic-shield": SKY, "ic-audit-shield": SKY, "ic-cloud-subscription": SKY,
    "ic-family-share": GREEN,
}


def tile_colors(name: str) -> tuple[str, str]:
    return OVERRIDES.get(name, GROUP_DEFAULT[group_of(name)])


# ── SVG 组装 ────────────────────────────────────────────────────────────────

def _rgb(h: str) -> tuple[int, int, int]:
    return int(h[1:3], 16), int(h[3:5], 16), int(h[5:7], 16)


def _hex(r: int, g: int, b: int) -> str:
    return f"#{max(0,min(255,r)):02X}{max(0,min(255,g)):02X}{max(0,min(255,b)):02X}"


def darken(h: str, f: float = 0.78) -> str:
    r, g, b = _rgb(h)
    return _hex(int(r * f), int(g * f), int(b * f))


def mix(h1: str, h2: str, t: float) -> str:
    a, b = _rgb(h1), _rgb(h2)
    return _hex(*[int(a[i] + (b[i] - a[i]) * t) for i in range(3)])


def fluent_glyph(name: str, filled: bool):
    """按优先级读取 vendor 字形：Fluent(24) → HealthIcons(48) → Lucide(24) → Tabler(24) → MDI(24) → MaterialSymbols(960) → FontAwesome(512)。
    返回 (内部元素, 栅格尺寸) 或 None。"""
    candidates = [
        (FLUENT_DIR / (f"{name}.filled.svg" if filled else f"{name}.svg"), 24, "fluent"),
        (HEALTH_DIR / f"{name}.svg", 48, "healthicons"),
        (LUCIDE_DIR / f"{name}.svg", 24, "lucide"),
        (TABLER_DIR / f"{name}.svg", 24, "tabler"),
        (MDI_DIR / f"{name}.svg", 24, "mdi"),
        (FA_DIR / f"{name}.svg", 512, "fontawesome"),
        (MATERIAL_DIR / f"{name}.svg", 960, "materialsymbols"),
    ]
    for path, grid, src in candidates:
        if path.exists():
            text = path.read_text(encoding="utf-8")
            m = re.search(r"<svg[^>]*>(.*)</svg>", text, re.S)
            if m:
                body = m.group(1)
                body = body.replace("currentColor", "#FFF")
                if src == "fontawesome":
                    # 512 栅格实心：viewBox 320×512 非方形 → x 平移 96 使内容居中
                    body = f'<g transform="translate(96 0)">{body}</g>'
                elif src == "materialsymbols":
                    # 960 栅格实心剪影：viewBox y 偏移 -960 → 归一化到 0..960
                    body = f'<g transform="translate(0 960)">{body}</g>'
                elif grid == 48:  # 48 栅格描边 2 → 视觉对齐 Fluent 24/1.5
                    body = re.sub(r'stroke-width="2"', 'stroke-width="3"', body)
                elif src in ("lucide", "tabler", "mdi"):
                    # 24 栅格描边源统一收敛 1.5；Lucide 的描边属性在根元素上，
                    # 必须在本组声明 stroke 才能被子元素继承（否则瓷砖内不可见）
                    body = body.replace('stroke-width="2"', 'stroke-width="1.5"')
                    body = ('<g fill="none" stroke="#FFF" stroke-width="1.5" '
                            'stroke-linecap="round" stroke-linejoin="round">'
                            + body + "</g>")
                return body, grid, src
    return None


def own_glyph(name: str, filled: bool) -> str:
    spec = ICONS[name]
    body = (spec.get("filled") if filled else None) or spec["body"]
    body = body.replace("#000", "#FFF")
    if filled:
        return f'<g fill="#FFF" stroke="none">{body}</g>'
    return (
        '<g fill="none" stroke="#FFF" stroke-width="1.5" '
        'stroke-linecap="round" stroke-linejoin="round">' + body + "</g>"
    )


def tile_svg(name: str, c1: str, c2: str, glyph, grid: int = 24) -> str:
    """Fluent 徽章瓷砖（技法借鉴 3dicons/Fluency，素材原创）：
    三段色相偏移渐变 → 左上径向光晕 → 斜向玻璃光带 → 底部弧形内阴影
    → 内圈描边 → 字形投影 → 白色字形。glyph 可为 str(24栅格) 或 (str, grid)。"""
    if isinstance(glyph, tuple):
        glyph, grid = glyph
    uid = name.replace("-", "_")
    c3 = darken(c2, 0.76)
    cm = mix(c1, c2, 0.55)
    shadow = re.sub(r'(fill|stroke)="#[0-9A-Fa-f]{3,6}"', r'\1="#000"', glyph)
    gscale = 2.92 * 24 / grid          # 24栅格→2.92；48栅格→1.46（渲染尺寸一致 ≈70px）
    gpad = (96 - grid * gscale) / 2    # 居中边距
    gtf = f"translate({gpad:.2f} {gpad:.2f}) scale({gscale:.3f})"
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96">'
        "<defs>"
        f'<linearGradient id="g{uid}" x1="0" y1="0" x2=".9" y2="1">'
        f'<stop offset="0" stop-color="{c1}"/>'
        f'<stop offset=".52" stop-color="{cm}"/>'
        f'<stop offset="1" stop-color="{c3}"/></linearGradient>'
        f'<radialGradient id="r{uid}" cx=".28" cy=".18" r=".95">'
        '<stop offset="0" stop-color="#FFFFFF" stop-opacity=".34"/>'
        '<stop offset=".55" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>'
        f'<linearGradient id="s{uid}" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#FFFFFF" stop-opacity=".26"/>'
        '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>'
        f'<clipPath id="c{uid}"><rect x="4" y="4" width="88" height="88" rx="24"/></clipPath>'
        "</defs>"
        f'<rect x="4" y="4" width="88" height="88" rx="24" fill="url(#g{uid})"/>'
        f'<g clip-path="url(#c{uid})">'
        f'<rect x="4" y="4" width="88" height="88" fill="url(#r{uid})"/>'
        f'<rect x="-26" y="-40" width="152" height="66" rx="33" '
        f'transform="rotate(-19 48 8)" fill="url(#s{uid})"/>'
        '<ellipse cx="48" cy="102" rx="58" ry="30" fill="#000000" opacity=".10"/>'
        '<rect x="6" y="6" width="84" height="84" rx="22" fill="none" '
        'stroke="#FFFFFF" stroke-opacity=".16" stroke-width="3"/>'
        "</g>"
        f'<g transform="translate({gpad + 1.3:.2f} {gpad + 2.0:.2f}) scale({gscale:.3f})" '
        f'fill="#000" stroke="#000" opacity=".14">{shadow}</g>'
        f'<g transform="{gtf}" fill="#FFF" stroke="none">{glyph}</g>'
        "</svg>"
    )


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def render_png(svg: str, out: Path, w: int, h: int | None = None) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    cairosvg.svg2png(bytestring=svg.encode(), write_to=str(out), output_width=w, output_height=h)


def hexcomp(h: str) -> dict:
    return {"alpha": "1.000", "red": f"0x{h[0:2]}", "green": f"0x{h[2:4]}", "blue": f"0x{h[4:6]}"}


def C(l, d=None):
    return (l, d or l)


COLORS = {
    "brand-primary": C("0A66C2", "4A9DE8"),
    "surface-tint-start": C("E6F0FC", "1E2846"),
    "surface-tint-end": C("F8FAFE", "141930"),
    "bg-grouped": C("EDF0F6", "0E1225"),
    "semantic-success": C("34A853", "5BB974"),
    "semantic-warning": C("E8A13A", "F0B45C"),
    "semantic-danger": C("D93025", "E86A5C"),
    "alert-l2": C("E8730C"),
    "grade-a": C("0A66C2"), "grade-b": C("5F6368"), "grade-c": C("34A853"),
    "grade-d": C("E8A13A"), "grade-e": C("9334E6"), "grade-self": C("7B8794"),
    "text-primary": C("1C1C1E", "E8EAF2"),
    "text-secondary": C("5B5B60", "9BA3B8"),
    "text-tertiary": C("AEAEB2", "5A6078"),
    "member-self": C("0A66C2", "4A9DE8"), "member-partner": C("D95970", "E88A9B"),
    "member-father": C("3B7DD8", "6FA3E8"), "member-mother": C("B85497", "D683BC"),
    "member-son": C("2FA3A0", "63C4C1"), "member-daughter": C("DE8A3C", "EDAF6E"),
    "member-family": C("6B7FD8", "94A3E8"),
}


def colorset(light: str, dark: str | None) -> dict:
    colors = [{"color": {"color-space": "srgb", "components": hexcomp(light)}, "idiom": "universal"}]
    if dark and dark != light:
        colors.append({
            "appearances": [{"appearance": "luminosity", "value": "dark"}],
            "color": {"color-space": "srgb", "components": hexcomp(dark)},
            "idiom": "universal",
        })
    return {"colors": colors, "info": INFO}


def imageset(png_names: list[str]) -> dict:
    images = [{"filename": f, "idiom": "universal", "scale": f[-5]} for f in png_names]
    return {"images": images, "info": INFO}  # 彩色瓷砖：默认渲染（非 template）


# ── 主流程 ───────────────────────────────────────────────────────────────────

def main() -> None:
    provenance, n_icons = {}, 0

    for name in ICONS:
        c1, c2 = tile_colors(name)
        group = group_of(name)

        variants = [(False, name)]
        if ICONS[name].get("filled"):
            variants.append((True, f"{name}-filled"))

        for filled, fname in variants:
            accent = None if filled else ACCENTS.get(name)
            res = fluent_glyph(name, filled)
            if res is not None:
                glyph, grid, src = res[0], res[1], res[2]
                upstream = {"fluent": FLUENT, "healthicons": HEALTH_MAP,
                            "lucide": LUCIDE, "tabler": TABLER_MAP,
                            "mdi": MDI_MAP, "materialsymbols": MATERIAL,
                            "fontawesome": FONTAWESOME}[src].get(name)
            elif not filled and name in COLORED:
                glyph, grid, src, upstream = f"<g>{COLORED[name]}</g>", 24, "own-color", None
            else:
                glyph, grid, src, upstream = own_glyph(name, filled), 24, "own", None
            if accent:
                glyph += f"<g>{accent}</g>"
            provenance[fname] = {"source": src, "upstream": upstream}
            svg = tile_svg(fname, c1, c2, glyph, grid)
            (SRC_ICONS / group.lower()).mkdir(parents=True, exist_ok=True)
            (SRC_ICONS / group.lower() / f"{fname}.svg").write_text(svg, encoding="utf-8")

            iset = CATALOG / "Icons" / group / f"{fname}.imageset"
            files = []
            for scale, px in TILE_SCALES:
                fn = f"{fname}@{scale}x.png"
                render_png(svg, iset / fn, px)
                files.append(fn)
            write_json(iset / "Contents.json", imageset(files))
            n_icons += 1

    # 插画 ---------------------------------------------------------------------
    for name, body in ILLUSTRATIONS.items():
        svg = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 180">{body}</svg>'
        (SRC_ILL / f"{name}.svg").write_text(svg, encoding="utf-8")
        iset = CATALOG / "Illustrations" / f"{name}.imageset"
        files = []
        for scale, w, h in ILL_SCALES:
            fn = f"{name}@{scale}x.png"
            render_png(svg, iset / fn, w, h)
            files.append(fn)
        write_json(iset / "Contents.json", imageset(files))
        provenance[name] = {"source": "own", "upstream": None}

    # App 图标 -------------------------------------------------------------------
    # 位图母版优先：若存在 design/brand/app-icon.png（如 AI 生成图标），直接缩放写入，
    # 否则回退到 SVG 母版渲染。两路都同时刷新 design/brand/app-icon.svg 供参考。
    (SRC_BRAND / "app-icon.svg").write_text(APP_ICON_SVG, encoding="utf-8")
    iconset = CATALOG / "AppIcon.appiconset"
    iconset.mkdir(parents=True, exist_ok=True)
    tmp = PREVIEWS / "appicon-1024.png"
    raster_master = SRC_BRAND / "app-icon.png"
    if raster_master.exists():
        im = Image.open(raster_master).convert("RGB").resize((1024, 1024), Image.LANCZOS)
        im.save(tmp)
        im.save(iconset / "AppIcon1024.png")
    else:
        render_png(APP_ICON_SVG, tmp, 1024, 1024)
        Image.open(tmp).convert("RGB").save(iconset / "AppIcon1024.png")
    write_json(iconset / "Contents.json", {
        "images": [{"filename": "AppIcon1024.png", "idiom": "universal",
                    "platform": "ios", "size": "1024x1024"}],
        "info": INFO,
    })

    # 色板 / 组目录 ----------------------------------------------------------------
    write_json(CATALOG / "AccentColor.colorset/Contents.json", colorset(*COLORS["brand-primary"]))
    for cname, (l, d) in COLORS.items():
        write_json(CATALOG / "Colors" / f"{cname}.colorset/Contents.json", colorset(l, d))
    for sub in ["Icons", "Illustrations", "Colors"]:
        write_json(CATALOG / sub / "Contents.json", {"info": INFO})
    for g, _ in GROUPS:
        write_json(CATALOG / "Icons" / g / "Contents.json", {"info": INFO})
    write_json(CATALOG / "Contents.json", {"info": INFO})

    # 出处清单 -----------------------------------------------------------------------
    n_fluent = sum(1 for v in provenance.values() if v["source"] == "fluent")
    n_hi = sum(1 for v in provenance.values() if v["source"] == "healthicons")
    n_lu = sum(1 for v in provenance.values() if v["source"] == "lucide")
    n_tb = sum(1 for v in provenance.values() if v["source"] == "tabler")
    n_mdi = sum(1 for v in provenance.values() if v["source"] == "mdi")
    n_ms = sum(1 for v in provenance.values() if v["source"] == "materialsymbols")
    n_fa = sum(1 for v in provenance.values() if v["source"] == "fontawesome")
    write_json(ROOT / "design/icons/provenance.json", {
        "generated": str(date.today()),
        "glyph_license": "Fluent MIT / Health Icons CC0 / Lucide ISC / Tabler MIT / Material Symbols Apache-2.0 / Font Awesome CC-BY-4.0 / project-owned",
        "notice": "design/icons/NOTICE.md",
        "counts": {"total": len(provenance), "fluent": n_fluent, "healthicons": n_hi,
                   "lucide": n_lu, "tabler": n_tb, "mdi": n_mdi, "materialsymbols": n_ms,
                   "fontawesome": n_fa,
                   "own": len(provenance) - n_fluent - n_hi - n_lu - n_tb - n_mdi - n_ms - n_fa},
        "assets": provenance,
    })

    # 5.5) 孤儿清理（组重命名/条目移除后残留）
    prov_names = set(provenance.keys())
    import shutil
    icons_root = CATALOG / "Icons"
    for grp_dir in list(icons_root.iterdir()):
        if not grp_dir.is_dir():
            continue
        if grp_dir.name not in {g for g, _ in GROUPS}:
            shutil.rmtree(grp_dir)
            continue
        for iset in grp_dir.glob("*.imageset"):
            fname = iset.name.removesuffix(".imageset")
            base = fname.removesuffix("-filled")
            if fname not in prov_names or group_of(base) != grp_dir.name:
                shutil.rmtree(iset)

    # Swift 常量 ----------------------------------------------------------------------
    def camel(s: str) -> str:
        parts = s.split("-")
        return parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:] if p)

    # Swift 保留字：作为属性名声明时必须反引号转义，否则编译期 error（ERR#28）。
    # 宁可多转义——反引号对非保留字是恒等语法，不改变 API 名。
    SWIFT_KEYWORDS = {
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func",
        "import", "init", "inout", "internal", "let", "open", "operator", "private",
        "precedencegroup", "protocol", "public", "rethrows", "static", "struct",
        "subscript", "typealias", "var", "break", "case", "catch", "continue", "default",
        "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat",
        "return", "throw", "throws", "switch", "where", "while", "Any", "as", "await",
        "false", "is", "nil", "self", "Self", "super", "true", "try", "_",
    }

    def esc(ident: str) -> str:
        """保留字转义。必须在拼接完整标识符之后调用（如 xxxFilled）。"""
        return f"`{ident}`" if ident in SWIFT_KEYWORDS else ident

    lines = [
        "// AUTO-GENERATED — 请勿手改。重新生成：python3 design/tools/generate_assets.py",
        "// 风格：Fluent 彩色瓷砖（字形出处见 design/icons/provenance.json）。",
        "",
        "import SwiftUI",
        "",
        "/// 设计系统图标唯一出口（对齐 Localization/L10n.swift 的单出口纪律）。",
        "/// 瓷砖基准 48pt；更大尺寸用 .resizable().frame(width:height:)。",
        "enum VLIcon {",
    ]
    for name in ICONS:
        base = "-".join(name.split("-")[1:])
        lines.append(f"    static let {esc(camel(base))} = Image(\"{name}\")")
        if ICONS[name].get("filled"):
            lines.append(f"    static let {esc(camel(base) + 'Filled')} = Image(\"{name}-filled\")")
    for name in ILLUSTRATIONS:
        lines.append(f"    static let {esc(camel(name))} = Image(\"{name}\")")
    lines += ["}", ""]
    SWIFT_OUT.parent.mkdir(parents=True, exist_ok=True)
    SWIFT_OUT.write_text("\n".join(lines), encoding="utf-8")

    print(f"[ok] icons={n_icons} illustrations={len(ILLUSTRATIONS)} colors={len(COLORS)} "
          f"sources: fluent={n_fluent} healthicons={n_hi} lucide={n_lu} tabler={n_tb} "
          f"mdi={n_mdi} materialsymbols={n_ms} fontawesome={n_fa} own={len(provenance) - n_fluent - n_hi - n_lu - n_tb - n_mdi - n_ms - n_fa}")
    build_contact_sheets()
    build_gallery()
    print("[ok] gallery -> design/gallery.html")


# ── 预览与走查 ───────────────────────────────────────────────────────────────

_FONT_CACHE = {}

def _font(size: int):
    if size not in _FONT_CACHE:
        try:
            _FONT_CACHE[size] = ImageFont.truetype(
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", size)
        except Exception:
            _FONT_CACHE[size] = ImageFont.load_default()
    return _FONT_CACHE[size]


def build_contact_sheets() -> None:
    cols, cell, label_h = 8, 96, 18
    items = [(n, CATALOG / "Icons" / group_of(n) / f"{n}.imageset/{n}@2x.png") for n in ICONS]
    rows = (len(items) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell, rows * (cell + label_h)), "#F4F6FA")
    draw = ImageDraw.Draw(sheet)
    for i, (name, png) in enumerate(items):
        x, y = (i % cols) * cell, (i // cols) * (cell + label_h)
        if png.exists():
            glyph = Image.open(png).convert("RGBA")
            sheet.paste(glyph, (x + (cell - glyph.width) // 2, y + 2), glyph)
        draw.text((x + 6, y + cell), name.replace("ic-", ""), fill="#333", font=_font(11))
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
    def tile_inline(name: str) -> str:
        c1, c2 = tile_colors(name)
        res = fluent_glyph(name, False)
        if res is not None:
            glyph = (res[0], res[1])
        else:
            glyph = own_glyph(name, False)
        return tile_svg(name, c1, c2, glyph)

    cards = []
    for g, d in GROUPS:
        cells = []
        for name in d:
            pair = f'<div class="tile">{tile_inline(name)}</div>'
            if ICONS[name].get("filled"):
                c1, c2 = tile_colors(name)
                fres = fluent_glyph(name, True)
                if fres is not None:
                    fglyph = (fres[0], fres[1])
                else:
                    fglyph = own_glyph(name, True)
                fsvg = tile_svg(name + "-filled", c1, c2, fglyph)
                pair += f'<div class="tile dark">{fsvg}</div>'
            cells.append(f'<figure>{pair}<figcaption>{name}</figcaption></figure>')
        cards.append(f'<section><h2>{g}</h2><div class="grid">{"".join(cells)}</div></section>')

    ill_cells = "".join(
        f'<figure class="ill"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 180">{b}</svg>'
        f'<figcaption>{n}</figcaption></figure>'
        for n, b in ILLUSTRATIONS.items())

    html = f"""<!doctype html>
<html lang="zh-Hans"><head><meta charset="utf-8">
<title>青囊书 · Fluent 瓷砖图标库</title>
<style>
  :root {{ --bg:#10141f; --card:#1b2130; --fg:#e8eaf2; --muted:#9ba3b8 }}
  body {{ margin:0; padding:32px; background:var(--bg); color:var(--fg);
         font:14px/1.5 -apple-system,"PingFang SC",sans-serif }}
  header {{ display:flex; align-items:center; gap:16px; max-width:1180px; margin:0 auto 20px }}
  h1 {{ font-size:20px; margin:0 }}
  section {{ max-width:1180px; margin:0 auto 28px; background:var(--card); border-radius:16px;
            padding:20px 24px; box-shadow:0 8px 32px rgba(0,0,0,.3) }}
  h2 {{ font-size:15px; margin:0 0 14px; color:var(--muted) }}
  .grid {{ display:flex; flex-wrap:wrap; gap:12px }}
  figure {{ width:112px; margin:0; text-align:center }}
  .tile {{ display:flex; align-items:center; justify-content:center; height:56px }}
  .tile svg {{ width:52px; height:52px; filter:drop-shadow(0 4px 8px rgba(0,0,0,.35)) }}
  .tile.dark svg {{ width:44px; height:44px; opacity:.95 }}
  figcaption {{ font-size:11px; color:var(--muted); margin-top:6px; word-break:break-all }}
  figure.ill {{ width:auto }} figure.ill svg {{ width:280px; height:auto; display:block }}
</style></head><body>
<header><h1>青囊书 · Fluent 彩色瓷砖图标库</h1></header>
{"".join(cards)}
<section><h2>Illustrations · 彩色扁平空态插画（240×180）</h2>
<div class="grid">{ill_cells}</div></section>
<section><h2>App Icon · 1024</h2>
<img src="previews/appicon-1024.png" width="180" style="border-radius:40px">
<p style="color:var(--muted)">字形出处：design/icons/provenance.json（Fluent MIT + 自绘）</p></section>
</body></html>"""
    (ROOT / "design/gallery.html").write_text(html, encoding="utf-8")


if __name__ == "__main__":
    main()
