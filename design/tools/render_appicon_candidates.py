#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""App 图标候选草稿渲染脚本（讨论用，不影响正式 app-icon.svg / 管线产物）。

三个候选：
  A1 · 青囊提环书（蓝底）     —— 单焦点「书 + 青囊挂饰」，品牌蓝渐变，玻璃高光
  A2 · 青囊提环书（深青底）   —— 同一符号，深青（青囊之"青"）底 + 琥珀药袋（呼应插画琥珀点缀）
  C  · 负空间医疗十字         —— 白书形瓦片 + 十字负空间，极简单形

每个候选渲染 1024 全尺寸 + 60pt/40pt/20pt（@3x：180/120/60px）小尺寸，并生成
design/previews/appicon-candidates.html 对比页（含当前正式图标作基线）。
用法：python3 design/tools/render_appicon_candidates.py
依赖：cairosvg
"""

from pathlib import Path

import cairosvg

ROOT = Path(__file__).resolve().parents[2]
BRAND = ROOT / "design/brand"
PREVIEWS = ROOT / "design/previews"

# ── 共享渐变 / 底色定义 ─────────────────────────────────────────────────────

def blue_bg_defs():
    return """
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#1583E0"/>
      <stop offset=".55" stop-color="#0A66C2"/>
      <stop offset="1" stop-color="#064B92"/>
    </linearGradient>
    <radialGradient id="glow" cx=".3" cy=".18" r=".9">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity=".22"/>
      <stop offset=".55" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>"""

def teal_bg_defs():
    return """
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#129C89"/>
      <stop offset=".55" stop-color="#0B6B60"/>
      <stop offset="1" stop-color="#06473F"/>
    </linearGradient>
    <radialGradient id="glow" cx=".3" cy=".18" r=".9">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity=".20"/>
      <stop offset=".55" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>"""

# 书页 / 青囊 / 提环渐变
BOOK_DEFS = """
    <linearGradient id="page" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF"/>
      <stop offset="1" stop-color="#D7E9FA"/>
    </linearGradient>"""

POUCH_TEAL_DEFS = """
    <linearGradient id="pouch" x1="0" y1="0" x2=".6" y2="1">
      <stop offset="0" stop-color="#3BC4B8"/>
      <stop offset="1" stop-color="#0E8A81"/>
    </linearGradient>"""

POUCH_AMBER_DEFS = """
    <linearGradient id="pouch" x1="0" y1="0" x2=".6" y2="1">
      <stop offset="0" stop-color="#FFC04D"/>
      <stop offset="1" stop-color="#E87E10"/>
    </linearGradient>"""

# ── 候选 A：青囊提环书 ─────────────────────────────────────────────────────
# 单焦点：一本大开的医书，一枚青囊（药袋）带提环，像书签一样挂在书脊上方，
# 药袋上白色医疗十字。整体 = 书 + 青囊挂饰，收敛为一个主体。

A_BOOK_POUCH = """
  <g transform="translate(0 36)">
    <!-- 书底部接触阴影 -->
    <ellipse cx="512" cy="796" rx="330" ry="34" fill="#053B72" opacity=".30"/>
    <!-- 医书两页 -->
    <path d="M512 396C440 344 336 334 214 334L214 646C336 646 440 668 512 704Z" fill="url(#page)"/>
    <path d="M512 396C588 344 692 334 814 334L814 646C692 646 588 668 512 704Z" fill="url(#page)"/>
    <path d="M512 396L512 704" stroke="#9CC4EA" stroke-width="14" stroke-linecap="round"/>
    <path d="M296 384C380 374 452 376 512 394M728 384C644 374 572 376 512 394"
          stroke="#C9E0F6" stroke-width="10" stroke-linecap="round" fill="none"/>
    <!-- 药袋在书页上的投影 -->
    <ellipse cx="512" cy="540" rx="128" ry="26" fill="#064B92" opacity=".16"/>
    <!-- 提环 -->
    <path d="M460 250a52 52 0 1 1 104 0" stroke="url(#pouch)" stroke-width="26"
          stroke-linecap="round" fill="none"/>
    <!-- 提环与袋口的连接带 -->
    <rect x="470" y="252" width="84" height="30" rx="15" fill="#0A5F58"/>
    <!-- 青囊袋身 -->
    <rect x="434" y="288" width="156" height="244" rx="66" fill="url(#pouch)"/>
    <ellipse cx="470" cy="332" rx="46" ry="28" fill="#FFFFFF" opacity=".18"/>
    <!-- 白色医疗十字 -->
    <rect x="488" y="384" width="48" height="132" rx="22" fill="#FFFFFF"/>
    <rect x="436" y="426" width="152" height="48" rx="22" fill="#FFFFFF"/>
  </g>"""

CAND_A1 = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>{blue_bg_defs()}{BOOK_DEFS}{POUCH_TEAL_DEFS}</defs>
  <rect width="1024" height="1024" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="url(#glow)"/>
  {A_BOOK_POUCH}
</svg>"""

CAND_A2 = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>{teal_bg_defs()}{BOOK_DEFS}{POUCH_AMBER_DEFS}</defs>
  <rect width="1024" height="1024" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="url(#glow)"/>
  {A_BOOK_POUCH}
</svg>"""

# ── 候选 C：负空间医疗十字 ──────────────────────────────────────────────────
# 极简单形：白「书」形瓦片（顶边两条书页线），中央蓝色医疗十字由负空间切出。

CAND_C = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>{blue_bg_defs()}
    <linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF"/>
      <stop offset="1" stop-color="#DCEAFB"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="url(#glow)"/>
  <!-- 白书形瓦片 -->
  <rect x="220" y="220" width="584" height="584" rx="150" fill="url(#tile)"/>
  <!-- 书页线（十字上方，暗示"书"） -->
  <rect x="352" y="268" width="320" height="12" rx="6" fill="#9CC4EA"/>
  <rect x="352" y="302" width="320" height="12" rx="6" fill="#9CC4EA"/>
  <!-- 医疗十字负空间（露出底色） -->
  <rect x="490" y="330" width="44" height="380" rx="20" fill="url(#bg)"/>
  <rect x="318" y="490" width="388" height="44" rx="20" fill="url(#bg)"/>
</svg>"""

CANDIDATES = [
    ("A1", "青囊提环书 · 蓝底", CAND_A1,
     "单焦点「书 + 青囊挂饰」；品牌蓝渐变；玻璃高光；药袋白十字。"),
    ("A2", "青囊提环书 · 深青底", CAND_A2,
     "同一符号；深青（青囊之青）底 + 琥珀药袋（呼应插画琥珀点缀），差异化最强。"),
    ("C", "负空间医疗十字 · 蓝底", CAND_C,
     "极简单形：白书瓦片 + 蓝色十字负空间；顶边书页线暗示「医书」。"),
]

# 渲染尺寸：1024 全尺寸 + 60pt/40pt/20pt（@3x 即 180/120/60px）
SIZES = [
    (1024, "1024"),
    (180, "60pt"),
    (120, "40pt"),
    (60, "20pt"),
]


def render(svg_text: str, path: Path, size: int) -> None:
    cairosvg.svg2png(bytestring=svg_text.encode("utf-8"),
                     write_to=str(path), output_width=size, output_height=size)


def main() -> None:
    BRAND.mkdir(parents=True, exist_ok=True)
    PREVIEWS.mkdir(parents=True, exist_ok=True)

    # 1) 写母版 + 渲染全尺寸与小尺寸
    rendered = {}  # key -> {label, desc, files: {sizeLabel: relPath}}
    for key, label, svg, desc in CANDIDATES:
        (BRAND / f"app-icon-cand-{key}.svg").write_text(svg, encoding="utf-8")
        files = {}
        for size, sname in SIZES:
            rel = f"appicon-cand-{key}-{sname}.png"
            render(svg, PREVIEWS / rel, size)
            files[sname] = rel
        rendered[key] = {"label": label, "desc": desc, "files": files}
        print(f"[ok] cand-{key} {label}")

    # 2) 基线：当前正式图标
    cur = BRAND / "app-icon.svg"
    if cur.exists():
        files = {}
        for size, sname in SIZES:
            rel = f"appicon-current-{sname}.png"
            render(cur.read_text(encoding="utf-8"), PREVIEWS / rel, size)
            files[sname] = rel
        rendered["CUR"] = {"label": "当前正式图标（基线）", "desc": "",
                           "files": files}
        print("[ok] current baseline")

    # 3) 对比页
    html = build_html(rendered)
    out = PREVIEWS / "appicon-candidates.html"
    out.write_text(html, encoding="utf-8")
    print(f"[ok] {out.relative_to(ROOT)}")


def build_html(rendered: dict) -> str:
    def fig(key, title, desc, files, big=True):
        big_img = f'<img src="{files["1024"]}" style="width:180px;height:180px;border-radius:40px;box-shadow:0 8px 24px rgba(0,0,0,.25)">' if big else ""
        smalls = "".join(
            f'<span class="s"><img src="{files[lab]}" style="width:{px}px;height:{px}px;border-radius:{px*0.22:.0f}px">{lab}</span>'
            for lab, px in (("60pt", 60), ("40pt", 40), ("20pt", 20)))
        zooms = "".join(
            f'<span class="s"><img src="{files[lab]}" style="width:{px*3}px;height:{px*3}px;border-radius:{px*3*0.22:.0f}px">{lab}×3</span>'
            for lab, px in (("60pt", 60), ("40pt", 40), ("20pt", 20)))
        desc_txt = f"<p>{desc}</p>" if desc else ""
        return f"""<section id="{key}">
  <h2>{title}</h2>
  <div class="row">
    <div class="big">{big_img}</div>
    <div class="meta">{desc_txt}
      <p class="sizes">实际尺寸：{smalls}</p>
      <p class="sizes">放大 3× 查看：{zooms}</p>
    </div>
  </div>
</section>"""

    secs = []
    if "CUR" in rendered:
        secs.append(fig("CUR", rendered["CUR"]["label"], rendered["CUR"]["desc"],
                        rendered["CUR"]["files"]))
    for key in ("A1", "A2", "C"):
        if key in rendered:
            secs.append(fig(key, rendered[key]["label"], rendered[key]["desc"],
                            rendered[key]["files"]))

    return f"""<!DOCTYPE html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<title>青囊书 · App 图标候选草稿（讨论版）</title>
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
  <h1>青囊书 · App 图标候选草稿</h1>
  <p class="note">讨论版（非最终）：A1 / A2 为「青囊提环书」单焦点方案（蓝底 / 深青底），C 为负空间十字方案。
     小尺寸按系统实际渲染（60/40/20 pt @3x），并附 ×3 放大便于查看。</p>
  {''.join(secs)}
</body>
</html>"""


if __name__ == "__main__":
    main()
