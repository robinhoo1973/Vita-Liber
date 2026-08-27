#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""App 图标 · 三功能合一候选渲染脚本（讨论用）。

按用户对 App 图标的核心信息定义，一枚图标同时体现三件事：
  1. 医疗资料与历史档案记录  → 一本翻开的医书（白色主体）
  2. 医疗相关事件提醒        → 书脊上悬挂的铃铛（琥珀色，呼应 warning 语义色）
  3. 亲友之间紧急医疗事件求助 → 书页中央印着的红心 + 白色医疗十字（紧急语义色）

变体：
  M1 蓝底（主推）    —— 品牌蓝渐变底 + 白书 + 琥珀铃铛 + 红心白十字
  M2 深青底（差异化） —— 深青（青囊之"青"）底，其余同 M1
  M3 蓝底 · 铃铛角标 —— 同 M1，但铃铛改为书页右上角的小徽标（对比悬挂 vs 角标）

每个变体渲染 1024 + 60/40/20pt，生成 design/previews/appicon-core3.html。
用法：python3 design/tools/render_appicon_core.py
依赖：cairosvg
"""

from pathlib import Path

import cairosvg

ROOT = Path(__file__).resolve().parents[2]
BRAND = ROOT / "design/brand"
PREVIEWS = ROOT / "design/previews"

# ── 三要素共享几何 ─────────────────────────────────────────────────────────

# 医书（白色主体）+ 书底投影
BOOK = """
  <ellipse cx="512" cy="782" rx="320" ry="30" fill="#053B72" opacity=".28"/>
  <path d="M512 478C440 430 336 420 214 420L214 660C336 660 440 684 512 724Z" fill="url(#white)"/>
  <path d="M512 478C584 430 688 420 810 420L810 660C688 660 584 684 512 724Z" fill="url(#white)"/>
  <path d="M512 480L512 724" stroke="#9CC4EA" stroke-width="14" stroke-linecap="round"/>
  <path d="M300 462C380 452 452 456 512 478M724 462C644 452 572 456 512 478"
        stroke="#C9E0F6" stroke-width="10" stroke-linecap="round" fill="none"/>
"""

# 红心 + 白十字（书页中央）—— cross_fill 可换色
def heart(cross_fill: str) -> str:
    return f"""
  <path d="M512 668C440 612 396 560 396 512C396 462 438 424 480 440C512 452 512 474 512 474C512 474 512 452 544 440C586 424 628 462 628 512C628 560 584 612 512 668Z"
        fill="url(#heart)"/>
  <ellipse cx="470" cy="470" rx="24" ry="14" fill="#FFFFFF" opacity=".30"/>
  <rect x="496" y="528" width="32" height="108" rx="14" fill="{cross_fill}"/>
  <rect x="458" y="558" width="108" height="32" rx="14" fill="{cross_fill}"/>
"""

# 悬挂铃铛（书脊上方）
BELL_HANG = """
  <path d="M482 216a30 30 0 1 1 60 0" stroke="url(#bell)" stroke-width="18"
        stroke-linecap="round" fill="none"/>
  <circle cx="512" cy="250" r="14" fill="url(#bell)"/>
  <path d="M432 400C432 296 458 264 512 264C566 264 592 296 592 400L592 412C592 428 580 436 562 436L462 436C444 436 432 428 432 412Z"
        fill="url(#bell)"/>
  <ellipse cx="484" cy="318" rx="15" ry="26" fill="#FFFFFF" opacity=".35"/>
  <circle cx="512" cy="456" r="14" fill="url(#bell)"/>
"""

# 角标铃铛（书页右上角，小型）—— 复用悬挂铃铛形状做平移缩放
def bell_badge() -> str:
    inner = BELL_HANG.replace('<ellipse cx="484" cy="318" rx="15" ry="26" fill="#FFFFFF" opacity=".35"/>',
                              '<ellipse cx="484" cy="318" rx="15" ry="26" fill="#FFFFFF" opacity=".30"/>')
    return f'<g transform="translate(694 436) scale(0.55) translate(-512 -350)">{inner}</g>'


def defs(bg: str, bell: str, heart_fill: str) -> str:
    return f"""
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">{bg}</linearGradient>
    <radialGradient id="glow" cx=".3" cy=".18" r=".9">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity=".22"/>
      <stop offset=".55" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="white" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF"/>
      <stop offset="1" stop-color="#E2EDFB"/>
    </linearGradient>
    <linearGradient id="bell" x1="0" y1="0" x2=".6" y2="1">{bell}</linearGradient>
    <linearGradient id="heart" x1="0" y1="0" x2=".6" y2="1">{heart_fill}</linearGradient>"""


SHELL = """
  <rect width="1024" height="1024" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="url(#glow)"/>
"""

BLUE_STOPS = '<stop offset="0" stop-color="#1583E0"/><stop offset=".55" stop-color="#0A66C2"/><stop offset="1" stop-color="#064B92"/>'
TEAL_STOPS = '<stop offset="0" stop-color="#129C89"/><stop offset=".55" stop-color="#0B6B60"/><stop offset="1" stop-color="#06473F"/>'
AMBER_STOPS = '<stop offset="0" stop-color="#FFC04D"/><stop offset="1" stop-color="#F08F1E"/>'
RED_STOPS = '<stop offset="0" stop-color="#F2647C"/><stop offset="1" stop-color="#D93025"/>'
WHITE_BELL = '<stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#DCEBFB"/>'
LIGHT_HEART = '<stop offset="0" stop-color="#D6E9FB"/><stop offset="1" stop-color="#A9CCF0"/>'

# M1 蓝底主推
M1 = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>{defs(BLUE_STOPS, AMBER_STOPS, RED_STOPS)}</defs>
  {SHELL}{BELL_HANG}{BOOK}{heart("#FFFFFF")}
</svg>"""

# M2 深青底
M2 = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>{defs(TEAL_STOPS, AMBER_STOPS, RED_STOPS)}</defs>
  {SHELL}{BELL_HANG}{BOOK}{heart("#FFFFFF")}
</svg>"""

# M3 蓝底 · 铃铛右上角徽标 + 冷色克制（白铃、浅蓝心、蓝十字）
M3 = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>{defs(BLUE_STOPS, WHITE_BELL, LIGHT_HEART)}</defs>
  {SHELL}{bell_badge()}{BOOK}{heart("#0A66C2")}
</svg>"""

CANDIDATES = [
    ("M1", "三合一 · 蓝底（主推）", M1,
     "白书=档案记录 · 琥珀铃铛（悬挂）=事件提醒 · 红心白十字=亲友紧急求助。"),
    ("M2", "三合一 · 深青底（差异化）", M2,
     "同 M1 三要素；深青底（青囊之青）跳出蓝海。"),
    ("M3", "三合一 · 蓝底·铃铛角标（克制冷色）", M3,
     "铃铛改为书页右上角小徽标（对比悬挂）；冷色克制版：白铃、浅蓝心、蓝十字。"),
]

SIZES = [(1024, "1024"), (180, "60pt"), (120, "40pt"), (60, "20pt")]


def render(svg_text: str, path: Path, size: int) -> None:
    cairosvg.svg2png(bytestring=svg_text.encode("utf-8"),
                     write_to=str(path), output_width=size, output_height=size)


def main() -> None:
    BRAND.mkdir(parents=True, exist_ok=True)
    PREVIEWS.mkdir(parents=True, exist_ok=True)
    rendered = {}
    for key, label, svg, desc in CANDIDATES:
        (BRAND / f"app-icon-core-{key}.svg").write_text(svg, encoding="utf-8")
        files = {}
        for size, sname in SIZES:
            rel = f"appicon-core-{key}-{sname}.png"
            render(svg, PREVIEWS / rel, size)
            files[sname] = rel
        rendered[key] = {"label": label, "desc": desc, "files": files}
        print(f"[ok] core-{key} {label}")
    out = PREVIEWS / "appicon-core3.html"
    out.write_text(build_html(rendered), encoding="utf-8")
    print(f"[ok] {out.relative_to(ROOT)}")


def build_html(rendered: dict) -> str:
    legend = """
  <div class="legend">
    <p><b>三要素映射</b>：<span class="k" style="background:#FFFFFF;border:1px solid #9CC4EA"></span> 医书 = ① 医疗资料与历史档案记录
      · <span class="k" style="background:linear-gradient(135deg,#FFC04D,#F08F1E)"></span> 铃铛 = ② 医疗相关事件提醒
      · <span class="k" style="background:linear-gradient(135deg,#F2647C,#D93025)"></span> 红心白十字 = ③ 亲友之间紧急医疗事件求助</p>
  </div>"""

    def fig(key, title, desc, files):
        big = f'<img src="{files["1024"]}" style="width:180px;height:180px;border-radius:40px;box-shadow:0 8px 24px rgba(0,0,0,.25)">'
        smalls = "".join(
            f'<span class="s"><img src="{files[lab]}" style="width:{px}px;height:{px}px;border-radius:{px*0.22:.0f}px">{lab}</span>'
            for lab, px in (("60pt", 60), ("40pt", 40), ("20pt", 20)))
        zooms = "".join(
            f'<span class="s"><img src="{files[lab]}" style="width:{px*3}px;height:{px*3}px;border-radius:{px*3*0.22:.0f}px">{lab}×3</span>'
            for lab, px in (("60pt", 60), ("40pt", 40), ("20pt", 20)))
        return f"""<section id="{key}">
  <h2>{title}</h2>
  <div class="row">
    <div class="big">{big}</div>
    <div class="meta">
      <p>{desc}</p>
      <p class="sizes">实际尺寸：{smalls}</p>
      <p class="sizes">放大 3× 查看：{zooms}</p>
    </div>
  </div>
</section>"""

    secs = "".join(fig(k, v["label"], v["desc"], v["files"]) for k, v in rendered.items())
    return f"""<!DOCTYPE html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<title>青囊书 · App 图标（三功能合一）</title>
<style>
  body {{ font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif;
         margin: 0; padding: 32px; background: #10131C; color: #E8ECF5; }}
  h1 {{ font-size: 22px; margin: 0 0 4px; }}
  h2 {{ font-size: 18px; margin: 0 0 12px; }}
  p  {{ margin: 4px 0; color: #AEB6C8; font-size: 13px; }}
  .note {{ color: #7E8AA6; font-size: 12px; margin-bottom: 16px; }}
  .legend {{ background: #1A1F2E; border: 1px solid #2A3147; border-radius: 12px;
             padding: 12px 16px; margin-bottom: 20px; }}
  .legend p {{ color: #D6DCEA; font-size: 13px; }}
  .k {{ display: inline-block; width: 14px; height: 14px; border-radius: 4px;
        vertical-align: -2px; margin: 0 4px 0 12px; }}
  section {{ background: #1A1F2E; border: 1px solid #2A3147; border-radius: 16px;
             padding: 20px; margin-bottom: 20px; }}
  .row {{ display: flex; gap: 24px; align-items: flex-start; }}
  .big {{ flex: 0 0 auto; }}
  .meta {{ flex: 1; }}
  .sizes {{ display: flex; gap: 16px; align-items: flex-end; flex-wrap: wrap; }}
  .s {{ display: inline-flex; flex-direction: column; align-items: center; gap: 4px;
        font-size: 11px; color: #7E8AA6; }}
  .s img {{ display: block; box-shadow: 0 4px 12px rgba(0,0,0,.35); }}
</style>
</head>
<body>
  <h1>青囊书 · App 图标（三功能合一）</h1>
  <p class="note">讨论版，非最终。基于 refactor/function-spec.md：F4/F5/F11（档案）、F9/F2/F10（提醒）、F15/F24/F18（亲友紧急求助）。</p>
  {legend}
  {secs}
</body>
</html>"""


if __name__ == "__main__":
    main()
