#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""青囊书 · 图标变更 Before/After 对比页生成器。

BEFORE = 变更前母版快照（--before-dir，默认 design/icons/src 当前态）
AFTER  = 变更后当前母版（design/icons/src）

输出 design/previews/icon-replace-before-after.html，纯评审用静态页。

用法：
  python3 design/tools/render_before_after.py --before-dir /tmp/before_snap
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC_ICONS = ROOT / "design/icons/src"
OUT_HTML = ROOT / "design/previews/icon-replace-before-after.html"

# 变更清单：(图标名, 变更类型, 说明)
CHANGES = [
    ("ic-organ-bone", "替换 → Lucide bone", "消除唯一 Tabler 供应商，并入 Lucide 源（ISC）"),
    ("ic-medicine-box", "替换 → Lucide pill-bottle", "药瓶/药盒语义强对应（ISC）"),
    ("ic-organ-hand", "替换 → Lucide hand", "手部器官强对应（ISC）"),
    ("ic-organ-donation", "替换 → Lucide heart-handshake", "心形+握手表达器官捐献（ISC）"),
    ("ic-refill", "替换 → Lucide package-plus", "补药=向包装添加（ISC）"),
    ("ic-tab-assistant", "一致性修正（非替换）", "黄点→白圈，对齐 ill-empty-ai 插画机器人"),
]

# 成员头像（V2.5 实现状态）：父母 = Material Symbols（Apache-2.0）；子女 = Font Awesome Free（CC BY 4.0）
AVATAR_NOTES = {
    "ic-member-father": "成年男子：Material Symbols man（宽肩直身）",
    "ic-member-mother": "成年女子：Material Symbols woman（裙形下摆）",
    "ic-member-son": "男孩：Font Awesome child（CC BY 4.0）",
    "ic-member-daughter": "女孩：Font Awesome child-dress（CC BY 4.0）",
}

GALLERY_CSS = """
  :root { --bg:#10141f; --card:#1b2130; --fg:#e8eaf2; --muted:#9ba3b8 }
  body { margin:0; padding:32px; background:var(--bg); color:var(--fg);
         font:14px/1.5 -apple-system,"PingFang SC",sans-serif }
  header { max-width:1100px; margin:0 auto 12px }
  h1 { font-size:20px; margin:0 0 6px }
  p.sub { color:var(--muted); margin:0 0 4px; font-size:12px }
  section { max-width:1100px; margin:0 auto 20px; background:var(--card);
            border-radius:16px; padding:20px 24px;
            box-shadow:0 8px 32px rgba(0,0,0,.3) }
  h2 { font-size:15px; margin:0 0 4px }
  .meta { color:var(--muted); font-size:12px; margin:0 0 16px }
  .pair { display:flex; gap:40px; align-items:center; flex-wrap:wrap }
  .cell { text-align:center }
  .cell .cap { font-size:12px; margin-top:8px }
  .cell.before .cap { color:var(--muted) }
  .cell.after .cap { color:#7ee0a3; font-weight:600 }
  .arrow { font-size:26px; color:var(--muted) }
  .tile { display:flex; align-items:center; justify-content:center; height:96px }
  .tile svg { width:88px; height:88px; filter:drop-shadow(0 6px 14px rgba(0,0,0,.4)) }
"""


def find_src(name: str) -> Path:
    for p in SRC_ICONS.rglob(f"{name}.svg"):
        return p
    raise FileNotFoundError(name)


def swap_glyph(tile: str, glyph: str) -> str:
    """把现有瓷砖的字形层整体替换为给定字形（保留渐变外壳与变换）。"""
    shadow_open = '<g transform="translate(14.26 14.96) scale('
    white_open = '<g transform="translate(12.96 12.96) scale('
    i_shadow = tile.find(shadow_open)
    if i_shadow == -1:
        raise ValueError("未找到阴影字形层")
    i_white = tile.find(white_open, i_shadow)
    if i_white == -1:
        raise ValueError("未找到白色字形层")
    shell = tile[:i_shadow]
    shadow_tag = tile[i_shadow: tile.find(">", i_shadow) + 1]
    white_tag = tile[i_white: tile.find(">", i_white) + 1]
    return f"{shell}{shadow_tag}{glyph.replace('#FFF', '#000')}</g>{white_tag}{glyph}</g></svg>"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--before-dir", default=None, type=Path)
    args = ap.parse_args()
    before_dir = args.before_dir or SRC_ICONS

    cells = []
    for name, kind, note in CHANGES:
        before = (before_dir / f"{name}.svg").read_text()
        after = find_src(name).read_text()
        cells.append(f"""
  <section>
    <h2>{name} ｜ {kind}</h2>
    <p class="meta">{note}</p>
    <div class="pair">
      <div class="cell before">
        <div class="tile">{before}</div>
        <div class="cap">BEFORE</div>
      </div>
      <div class="arrow">→</div>
      <div class="cell after">
        <div class="tile">{after}</div>
        <div class="cap">AFTER（已实现）</div>
      </div>
    </div>
  </section>""")

    # 成员头像（V2.5 实现状态：父母 Material / 子女 Font Awesome）
    for name in AVATAR_NOTES:
        before = (before_dir / f"{name}.svg").read_text()
        after = find_src(name).read_text()
        cells.append(f"""
  <section class="avatar">
    <h2>{name} ｜ 成员头像（已实现）</h2>
    <p class="meta">{AVATAR_NOTES[name]} ｜ 关系色不变</p>
    <div class="pair">
      <div class="cell before">
        <div class="tile">{before}</div>
        <div class="cap">BEFORE（手绘原版）</div>
      </div>
      <div class="arrow">→</div>
      <div class="cell after">
        <div class="tile">{after}</div>
        <div class="cap">AFTER（已实现）</div>
      </div>
    </div>
  </section>""")

    page = f"""<!doctype html>
<html lang="zh-Hans"><head><meta charset="utf-8">
<title>青囊书 · 图标变更 Before/After 对比</title>
<style>{GALLERY_CSS}
</style></head>
<body>
<header>
  <h1>图标变更 · Before / After 对比（V2.5）</h1>
  <p class="sub">5 枚字形替换为 Lucide（ISC）；AI Tab 黄点→白圈；成员头像已实现：父母 Material Symbols（Apache-2.0）、子女 Font Awesome（CC BY 4.0）；瓷砖外壳不变</p>
</header>
{''.join(cells)}
</body></html>"""
    OUT_HTML.write_text(page)
    print(f"已生成：{OUT_HTML}")


if __name__ == "__main__":
    main()
