#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""App 图标 · 「家人托心」候选渲染脚本（讨论用，第二轮方向）。

针对用户四点反馈重做方向：
  ① 必须出现"人/亲友"元素
  ② 浑然一体、非三物拼贴 → 以「一本大医书」为唯一主体，人物与红心成为书页上的场景
  ③ 质感更正式 → 玻璃拟态：多层渐变、高光、柔和投影、单一光源
  ④ 风格 → 玻璃拟态 / 多彩渐变

三功能映射：
  医书（白色玻璃主体）            = ① 医疗资料与历史档案记录
  书脊上方琥珀铃铛（玻璃拟态）     = ② 医疗相关事件提醒
  书页上家人四手相托红心白十字     = ③ 亲友之间紧急医疗事件求助

变体：
  N1 蓝底 · 家人托心（主推）    —— 成人+孩子全身人形托心
  N2 深青底 · 家人托心          —— 同 N1，深青底差异化
  N3 蓝底 · 双手托心            —— 无全身人形，两只手从书页托起红心（更克制）

用法：python3 design/tools/render_appicon_family.py
依赖：cairosvg
"""

from pathlib import Path

import cairosvg

ROOT = Path(__file__).resolve().parents[2]
BRAND = ROOT / "design/brand"
PREVIEWS = ROOT / "design/previews"


def defs(bg_stops: str) -> str:
    return f"""
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">{bg_stops}</linearGradient>
    <radialGradient id="glow" cx=".3" cy=".16" r=".95">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity=".26"/>
      <stop offset=".5" stop-color="#FFFFFF" stop-opacity=".06"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="page" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF"/>
      <stop offset="1" stop-color="#D4E8FA"/>
    </linearGradient>
    <linearGradient id="block" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#DCEBFB"/>
      <stop offset="1" stop-color="#AECBF0"/>
    </linearGradient>
    <linearGradient id="skin" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#F7FBFF"/>
      <stop offset="1" stop-color="#DCEAFB"/>
    </linearGradient>
    <linearGradient id="bell" x1="0" y1="0" x2=".6" y2="1">
      <stop offset="0" stop-color="#FFC04D"/>
      <stop offset="1" stop-color="#F08F1E"/>
    </linearGradient>
    <linearGradient id="heart" x1="0" y1="0" x2=".6" y2="1">
      <stop offset="0" stop-color="#F76B84"/>
      <stop offset="1" stop-color="#D93025"/>
    </linearGradient>"""


SHELL = """
  <rect width="1024" height="1024" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="url(#glow)"/>
  <path d="M0 0L1024 210L1024 0Z" fill="#FFFFFF" opacity=".05"/>
"""

# 琥珀铃铛（书脊上方悬挂）
BELL = """
  <path d="M492 152a20 20 0 1 1 40 0" stroke="url(#bell)" stroke-width="14"
        stroke-linecap="round" fill="none"/>
  <circle cx="512" cy="180" r="9" fill="url(#bell)"/>
  <path d="M468 274C468 218 484 198 512 198C540 198 556 218 556 274L556 284C556 296 546 302 532 302L492 302C478 302 468 296 468 284Z"
        fill="url(#bell)"/>
  <ellipse cx="494" cy="236" rx="9" ry="15" fill="#FFFFFF" opacity=".38"/>
  <circle cx="512" cy="316" r="9" fill="url(#bell)"/>
"""

# 白色医书（唯一主体，带书体厚度：书脊块 + 层叠书页边）
BOOK = """
  <ellipse cx="512" cy="826" rx="330" ry="22" fill="#053B72" opacity=".30"/>
  <!-- 书体厚度（书脊块：底部圆角 + 层叠书页边线） -->
  <path d="M236 700L236 778Q236 810 268 810L756 810Q788 810 788 778L788 700Z" fill="url(#block)"/>
  <path d="M250 722H774M250 744H774M250 766H774M250 788H774"
        stroke="#AECBF0" stroke-width="12" stroke-linecap="round" opacity=".8"/>
  <!-- 翻开的两页（坐落在书体之上） -->
  <path d="M512 400C448 354 344 342 224 342L224 682C344 682 448 698 512 710Z" fill="url(#page)"/>
  <path d="M512 400C576 354 680 342 800 342L800 682C680 682 576 698 512 710Z" fill="url(#page)"/>
  <path d="M512 402L512 710" stroke="#9CC4EA" stroke-width="14" stroke-linecap="round"/>
  <path d="M302 386C384 376 458 382 512 400M722 386C640 376 566 382 512 400"
        stroke="#C9E0F6" stroke-width="10" stroke-linecap="round" fill="none"/>
"""

# 红心 + 白十字（书页中央，放大为主角）
HEART = """
  <ellipse cx="512" cy="712" rx="112" ry="20" fill="#7A1020" opacity=".18"/>
  <path d="M512 700C448 646 396 608 396 556C396 512 428 482 462 494C512 506 512 526 512 526C512 526 512 506 562 494C596 482 628 512 628 556C628 608 576 646 512 700Z"
        fill="url(#heart)"/>
  <ellipse cx="474" cy="528" rx="18" ry="11" fill="#FFFFFF" opacity=".35"/>
  <rect x="496" y="536" width="32" height="108" rx="15" fill="#FFFFFF"/>
  <rect x="464" y="572" width="96" height="32" rx="15" fill="#FFFFFF"/>
"""

# 家人（成人 + 孩子）在红心两侧，伸手托心
FAMILY = """
  <!-- 成人（左）：足部投影 + 身体 -->
  <ellipse cx="344" cy="694" rx="46" ry="10" fill="#7C9FC9" opacity=".30"/>
  <circle cx="344" cy="606" r="44" fill="url(#skin)"/>
  <path d="M290 690C290 668 312 642 344 642C376 642 398 668 398 690Z" fill="url(#skin)"/>
  <!-- 孩子（右）：足部投影 + 身体 -->
  <ellipse cx="676" cy="704" rx="36" ry="8" fill="#7C9FC9" opacity=".30"/>
  <circle cx="676" cy="634" r="32" fill="url(#skin)"/>
  <path d="M640 700C640 678 656 662 676 662C696 662 712 678 712 700Z" fill="url(#skin)"/>
  <!-- 双手（四手）托心 -->
  <path d="M398 664C408 638 420 612 444 592" stroke="url(#skin)" stroke-width="26"
        stroke-linecap="round" fill="none"/>
  <path d="M634 686C624 658 610 630 580 604" stroke="url(#skin)" stroke-width="22"
        stroke-linecap="round" fill="none"/>
"""

# 双手托心（无全身人形，从书页托起大心）
HANDS = """
  <path d="M440 700C454 640 464 602 472 566" stroke="url(#skin)" stroke-width="34"
        stroke-linecap="round" fill="none"/>
  <path d="M584 700C570 640 560 602 552 566" stroke="url(#skin)" stroke-width="34"
        stroke-linecap="round" fill="none"/>
"""

BLUE_STOPS = '<stop offset="0" stop-color="#1685E2"/><stop offset=".55" stop-color="#0A66C2"/><stop offset="1" stop-color="#064B92"/>'
TEAL_STOPS = '<stop offset="0" stop-color="#129C89"/><stop offset=".55" stop-color="#0B6B60"/><stop offset="1" stop-color="#06473F"/>'


def build(bg: str, middle: str) -> str:
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>{defs(bg)}</defs>
  {SHELL}{BELL}{BOOK}{middle}{HEART}
</svg>"""


CANDIDATES = [
    ("N1", "家人托心 · 蓝底（主推）", build(BLUE_STOPS, FAMILY),
     "一本全家医书为唯一主体；书页上成人与孩子四手相托红心白十字（亲友紧急求助）；书脊挂琥珀铃（提醒）。"),
    ("N2", "家人托心 · 深青底（差异化）", build(TEAL_STOPS, FAMILY),
     "同 N1 三要素；深青底（青囊之青）跳出蓝海。"),
    ("N3", "双手托心 · 蓝底（克制成）", build(BLUE_STOPS, HANDS),
     "无全身人形，改为双手从书页托起红心——更克制，仍含「人/托举」语义。"),
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
        (BRAND / f"app-icon-family-{key}.svg").write_text(svg, encoding="utf-8")
        files = {}
        for size, sname in SIZES:
            rel = f"appicon-family-{key}-{sname}.png"
            render(svg, PREVIEWS / rel, size)
            files[sname] = rel
        rendered[key] = {"label": label, "desc": desc, "files": files}
        print(f"[ok] family-{key} {label}")
    out = PREVIEWS / "appicon-family.html"
    out.write_text(build_html(rendered), encoding="utf-8")
    print(f"[ok] {out.relative_to(ROOT)}")


def build_html(rendered: dict) -> str:
    legend = """
  <div class="legend">
    <p><b>三功能映射</b>：<span class="k" style="background:linear-gradient(135deg,#FFFFFF,#D4E8FA)"></span> 医书 = ① 医疗资料与历史档案记录
      · <span class="k" style="background:linear-gradient(135deg,#FFC04D,#F08F1E)"></span> 铃铛 = ② 医疗相关事件提醒
      · <span class="k" style="background:linear-gradient(135deg,#F76B84,#D93025)"></span> 家人托心白十字 = ③ 亲友之间紧急医疗事件求助</p>
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
<title>青囊书 · App 图标（家人托心）</title>
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
  <h1>青囊书 · App 图标（家人托心）</h1>
  <p class="note">讨论版第二轮，非最终。以一本医书为唯一主体（档案），书页上是「家人托心」（亲友紧急求助），书脊挂铃（提醒）——浑然一体、玻璃拟态/多彩渐变。</p>
  {legend}
  {secs}
</body>
</html>"""


if __name__ == "__main__":
    main()
