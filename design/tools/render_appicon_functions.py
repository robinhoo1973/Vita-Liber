#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""App 图标 · 功能驱动候选组渲染脚本（讨论用）。

从 refactor/function-spec.md 的核心功能/旅程出发设计一组 App 图标候选，
每个候选代表一个产品功能语义（非抽象概念）：

  FN1 保险箱/信任（F1/F14）  —— 白色护盾 + 医疗十字：个人医疗信息保险箱
  FN2 用药依从（F9/F2）      —— 药囊 + 绿色对勾：按时吃药、如实记录（旅程 B）
  FN3 连续健康档案（F4/F5/F11）—— 文档 + 心电趋势线：以人为中心的连续档案
  FN4 AI 助手（F12）         —— 大脑 + 绿色星芒：可追溯的 AI 理解
  FN5 家庭档案（F3）         —— 双人剪影 + 青囊十字：一人一空间
  FN6 紧急救援（F15）        —— 心脏 + 医疗十字：关键时刻救命

统一品牌蓝渐变底（与 app 内 brand/primary 一致），白色主体字形，便于公平对比。
每个候选渲染 1024 + 60/40/20pt，并生成 design/previews/appicon-function-set.html。
用法：python3 design/tools/render_appicon_functions.py
依赖：cairosvg
"""

from pathlib import Path

import cairosvg

ROOT = Path(__file__).resolve().parents[2]
BRAND = ROOT / "design/brand"
PREVIEWS = ROOT / "design/previews"

BLUE_BG = """
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#1583E0"/>
      <stop offset=".55" stop-color="#0A66C2"/>
      <stop offset="1" stop-color="#064B92"/>
    </linearGradient>
    <radialGradient id="glow" cx=".3" cy=".18" r=".9">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity=".22"/>
      <stop offset=".55" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="white" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF"/>
      <stop offset="1" stop-color="#E2EDFB"/>
    </linearGradient>"""

SHELL = """
  <rect width="1024" height="1024" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="url(#glow)"/>
"""

# ── FN1 保险箱/信任：白盾 + 医疗十字 ──────────────────────────────────────
FN1 = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>{BLUE_BG}</defs>
  {SHELL}
  <path d="M340 318L512 232L684 318L684 516C684 666 610 748 512 794C414 748 340 666 340 516Z"
        fill="url(#white)"/>
  <ellipse cx="430" cy="360" rx="70" ry="40" fill="#FFFFFF" opacity=".35"/>
  <rect x="490" y="392" width="44" height="172" rx="20" fill="url(#bg)"/>
  <rect x="422" y="448" width="180" height="44" rx="20" fill="url(#bg)"/>
</svg>"""

# ── FN2 用药依从：药囊 + 绿色对勾 ─────────────────────────────────────────
FN2 = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>{BLUE_BG}</defs>
  {SHELL}
  <g transform="rotate(-22 512 512)">
    <rect x="380" y="280" width="264" height="464" rx="132" fill="url(#white)"/>
    <path d="M380 402L380 280a132 132 0 0 1 264 0l0 122Z" fill="#2F86E0"/>
    <rect x="380" y="392" width="264" height="20" rx="10" fill="#FFFFFF" opacity=".6"/>
  </g>
  <path d="M560 644L640 730L800 550" stroke="#4CCF7C" stroke-width="72"
        stroke-linecap="round" stroke-linejoin="round" fill="none"/>
</svg>"""

# ── FN3 连续健康档案：文档 + 心电趋势线 ───────────────────────────────────
FN3 = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>{BLUE_BG}</defs>
  {SHELL}
  <rect x="296" y="248" width="432" height="528" rx="60" fill="url(#white)"/>
  <path d="M636 248L728 248L728 340Z" fill="#BBD6F3"/>
  <path d="M636 248L636 340L728 340Z" fill="#DCEBFB"/>
  <path d="M356 500L470 500L506 420L546 580L580 500L668 500" stroke="#1E7AD4"
        stroke-width="46" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
</svg>"""

# ── FN4 AI 助手：大脑 + 绿色星芒 ─────────────────────────────────────────
FN4 = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>{BLUE_BG}</defs>
  {SHELL}
  <path d="M512 316C480 288 420 290 398 318C366 330 352 374 368 400C336 438 356 496 396 504C402 538 462 550 512 524Z"
        fill="url(#white)"/>
  <path d="M512 316C544 288 604 290 626 318C658 330 672 374 656 400C688 438 668 496 628 504C622 538 562 550 512 524Z"
        fill="url(#white)"/>
  <path d="M512 316L512 524" stroke="#A9C7EC" stroke-width="14" stroke-linecap="round"/>
  <path d="M430 380h42M436 424h40M586 380h-42M580 424h-40"
        stroke="#A9C7EC" stroke-width="12" stroke-linecap="round"/>
  <g transform="translate(716 336) rotate(45)">
    <rect x="-34" y="-9" width="68" height="18" rx="9" fill="#4CCF7C"/>
    <rect x="-9" y="-34" width="18" height="68" rx="9" fill="#4CCF7C"/>
  </g>
</svg>"""

# ── FN5 家庭档案：双人剪影 + 青囊十字 ────────────────────────────────────
FN5 = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>{BLUE_BG}</defs>
  {SHELL}
  <circle cx="430" cy="470" r="78" fill="url(#white)"/>
  <path d="M344 724C344 610 382 556 430 556C478 556 516 610 516 724Z" fill="url(#white)"/>
  <circle cx="618" cy="560" r="60" fill="url(#white)"/>
  <path d="M550 806C550 718 580 676 618 676C656 676 686 718 686 806Z" fill="url(#white)"/>
  <rect x="496" y="252" width="32" height="100" rx="15" fill="#3BC4B8"/>
  <rect x="452" y="294" width="120" height="32" rx="15" fill="#3BC4B8"/>
</svg>"""

# ── FN6 紧急救援：心脏 + 医疗十字 ────────────────────────────────────────
FN6 = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>{BLUE_BG}</defs>
  {SHELL}
  <path d="M512 826C392 728 268 634 268 480C268 366 362 282 474 318C512 330 512 368 512 368C512 368 512 330 550 318C662 282 756 366 756 480C756 634 632 728 512 826Z"
        fill="url(#white)"/>
  <rect x="494" y="428" width="36" height="148" rx="16" fill="url(#bg)"/>
  <rect x="448" y="470" width="128" height="36" rx="16" fill="url(#bg)"/>
</svg>"""

CANDIDATES = [
    ("FN1", "保险箱 · 信任（F1/F14）", FN1,
     "白盾 + 医疗十字 = 「个人医疗信息保险箱」。安全感最强，健康类 App 里几乎没有盾形，辨识度高。"),
    ("FN2", "用药 · 依从（F9/F2）", FN2,
     "药囊 + 绿色对勾 = 「按时吃药、如实记录」（旅程 B 慢病用药，最高价值）。成功绿呼应语义色。"),
    ("FN3", "健康档案 · 连续（F4/F5/F11）", FN3,
     "白色病历文档 + 蓝色心电趋势线 = 「以人为中心的连续健康档案」。"),
    ("FN4", "AI 助手 · 理解（F12）", FN4,
     "白色大脑 + 绿色星芒 = 「可追溯的 AI 辅助理解」。呼应 app 内 AI 插画的双脑/绿色 AI 徽标。"),
    ("FN5", "家庭 · 一人一空间（F3）", FN5,
     "双人剪影 + 青囊十字 = 「家庭成员档案」。直击家庭医疗记录定位。"),
    ("FN6", "紧急 · 救命（F15）", FN6,
     "心脏 + 医疗十字 = 「关键时刻救命的紧急信息卡」。最戳情感。"),
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
        (BRAND / f"app-icon-fn-{key}.svg").write_text(svg, encoding="utf-8")
        files = {}
        for size, sname in SIZES:
            rel = f"appicon-fn-{key}-{sname}.png"
            render(svg, PREVIEWS / rel, size)
            files[sname] = rel
        rendered[key] = {"label": label, "desc": desc, "files": files}
        print(f"[ok] fn-{key} {label}")
    out = PREVIEWS / "appicon-function-set.html"
    out.write_text(build_html(rendered), encoding="utf-8")
    print(f"[ok] {out.relative_to(ROOT)}")


def build_html(rendered: dict) -> str:
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
<title>青囊书 · App 图标候选组（功能驱动）</title>
<style>
  body {{ font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif;
         margin: 0; padding: 32px; background: #10131C; color: #E8ECF5; }}
  h1 {{ font-size: 22px; margin: 0 0 4px; }}
  h2 {{ font-size: 18px; margin: 0 0 12px; }}
  p  {{ margin: 4px 0; color: #AEB6C8; font-size: 13px; }}
  .note {{ color: #7E8AA6; font-size: 12px; margin-bottom: 24px; }}
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
  <h1>青囊书 · App 图标候选组（功能驱动）</h1>
  <p class="note">基于 refactor/function-spec.md 核心功能/旅程设计，每枚代表一个产品语义；统一品牌蓝渐变底便于公平对比。
     小尺寸按系统实际渲染（60/40/20 pt @3x），并附 ×3 放大。讨论版，非最终。</p>
  {secs}
</body>
</html>"""


if __name__ == "__main__":
    main()
