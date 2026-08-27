#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成「图标生成规格与重构需求」Markdown 文档。

从真实数据源读取（保证与当前实现一致）：
  - design/tools/icon_library.py   ：ICONS / GROUPS / group_of / COLORED / ACCENTS
  - design/tools/fluent_map.py     ：FLUENT / HEALTH_MAP / LUCIDE / MATERIAL / FONTAWESOME
  - design/tools/generate_assets.py：GROUP_DEFAULT / OVERRIDES / tile_colors / tile_svg 模板
  - design/icons/provenance.json   ：逐图标实际字形来源

产物：design/icon-spec.md —— 可作为「自动重构全部 SVG 图标」的需求文件。
用法：python3 design/tools/gen_icon_spec.py
"""

import json
import re
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).parent))
import icon_library as IL
import fluent_map as FM
import generate_assets as GA

PROV = json.loads((ROOT / "design/icons/provenance.json").read_text(encoding="utf-8"))["assets"]
OUT = ROOT / "design/icon-spec.md"

# 用途语义提示（前缀规则之外的已知语义，源自主文档 / icon-gap-list）
USAGE = {
    # Tab
    "ic-tab-home": "首页 Today（F2）· 今日任务/快速拍摄", "ic-tab-records": "健康档案 Records（F4-F8/F11）· 时间轴",
    "ic-tab-reminders": "提醒 Reminders（F9/F10）· 用药/复诊", "ic-tab-assistant": "AI 助手 Assistant（F12）",
    "ic-tab-me": "我的 Profile（F14/F21/F22）",
    # 症状宫格（F8 步骤1）
    "ic-sym-pain": "症状宫格·疼痛", "ic-sym-fever": "症状宫格·发热", "ic-sym-stool": "症状宫格·大便",
    "ic-sym-urine": "症状宫格·小便", "ic-sym-bleeding": "症状宫格·出血", "ic-sym-skin": "症状宫格·皮肤",
    "ic-sym-custom": "症状宫格·其他/自定义",
    # 成员（F3 默认头像）
    "ic-member-father": "成员默认头像·父（Material man）", "ic-member-mother": "成员默认头像·母（Material woman）",
    "ic-member-son": "成员默认头像·子（FA child）", "ic-member-daughter": "成员默认头像·女（FA child-dress）",
    "ic-member-grandfather": "成员默认头像·祖父", "ic-member-grandmother": "成员默认头像·祖母",
}

SOURCE_LABEL = {
    "fluent": "Fluent UI System Icons（MIT，24 栅格，regular/filled 双态）",
    "healthicons": "Health Icons（CC0，48 栅格描边）",
    "lucide": "Lucide（ISC，24 栅格描边）",
    "tabler": "Tabler（MIT，24 栅格描边）",
    "mdi": "Material Design Icons（Apache-2.0，24 栅格描边）",
    "materialsymbols": "Material Symbols（Apache-2.0，960 栅格实心）",
    "fontawesome": "Font Awesome Free（CC BY 4.0，512 栅格实心）",
    "own": "项目自绘（icon_library.py）",
    "own-color": "项目自绘·语义色填充（COLORED）",
}


def hx(c):
    return f"#{c[0]:02X}{c[1]:02X}{c[2]:02X}" if isinstance(c, tuple) else c


def group_table(group: str, names: list) -> str:
    rows = []
    for n in names:
        c1, c2 = GA.tile_colors(n)
        prov = PROV.get(n, {})
        src = prov.get("source", "?")
        up = prov.get("upstream")
        dual = "✅ outline+filled" if (isinstance(IL.ICONS[n], dict) and IL.ICONS[n].get("filled")) else ""
        colored = "✅" if n in IL.COLORED else ""
        accent = "✅" if n in IL.ACCENTS else ""
        usage = USAGE.get(n, "—")
        rows.append(
            f"| `{n}` | {usage} | `{hx(c1)}→{hx(c2)}` | {SOURCE_LABEL.get(src, src)}"
            + (f" `{up}`" if up else "") + f" | {dual} | {colored} | {accent} |"
        )
    return "\n".join(rows)


def main() -> None:
    groups = [(g, [k for k in d.keys()]) for g, d in IL.GROUPS]
    total = sum(len(d) for _, d in IL.GROUPS)

    md = []
    md.append("# 青囊书图标库 · 生成规格与重构需求（Icon Generation Spec）")
    md.append("")
    md.append(f"> 版本：V1.0 · {date.today().isoformat()}")
    md.append("> 用途：作为**自动重构全部 SVG 图标**的需求文件；实现者应能仅凭本文 + 数据源复现全部产物。")
    md.append("> 数据可信度：本文档由 `design/tools/gen_icon_spec.py` **程序化生成**，逐图标读取 `icon_library.py` / `fluent_map.py` / `generate_assets.py` / `provenance.json`，与当前实现完全一致。口径：**180 枚图标定义**（Tab 五枚含 outline+filled 双态 → **185 枚渲染母版**），另 7 张插画，合计 provenance 192 项。")
    md.append("")
    md.append("## 目录")
    md.append("- [1. 生成原则](#1-生成原则)")
    md.append("- [2. 展现方式（瓷砖解剖）](#2-展现方式瓷砖解剖)")
    md.append("- [3. 分类与配色](#3-分类与配色)")
    md.append("- [4. 逐图标规格](#4-逐图标规格)")
    md.append("- [5. 来源与许可](#5-来源与许可)")
    md.append("- [6. 重构验收标准（DoD）](#6-重构验收标准dod)")
    md.append("")

    # ── 1. 生成原则 ────────────────────────────────────────────────
    md.append("## 1. 生成原则")
    md.append("")
    md.append("| # | 原则 | 说明 |")
    md.append("|---|---|---|")
    md.append("| P1 | 风格 | Fluent 彩色徽章瓷砖：**渐变瓷砖底 + 白色字形 + 光影层次**（技法借鉴 Icons8 Fluency/Pulsar、3dicons，素材原创） |")
    md.append("| P2 | 画布/栅格 | 字形画布 24×24（安全区 2..22，常规描边 1.5px 圆头圆角）；渲染画布 96×96 瓷砖 |")
    md.append("| P3 | 字形来源 | 按优先级 vendor：**Fluent → Health Icons → Lucide → Tabler → MDI → Font Awesome → Material Symbols → 自绘**（见 §5 许可） |")
    md.append("| P4 | 着色 | 分组默认色 + 语义色覆盖（OVERRIDES）+ 双色字形（COLORED）+ 局部色块（ACCENTS）四级，见 §3 |")
    md.append("| P5 | 命名 | kebab-case + 领域前缀：`ic-tab-*` 五模块 Tab、`ic-sym-*` 症状宫格、`ic-member-*` 成员头像、`ic-organ-*` 器官、`ic-*` 通用/医疗/安全/Pro |")
    md.append("| P6 | 双态 | Tab 五枚同时产出 outline + filled 双态（ADR-021 同一枚举） |")
    md.append("| P7 | 产出一致 | 禁手改 `Resources/` 与 `VLIcon.swift`；改源后必须重跑 `generate_assets.py`（幂等） |")
    md.append("")
    md.append("**产物清单**（一键管线 `python3 design/tools/generate_assets.py`）：")
    md.append(f"- `design/icons/src/<group>/*.svg` —— 96×96 瓷砖母版（185 枚：180 定义 + 5 filled）")
    md.append("- `Resources/Assets.xcassets/Icons/<group>/*.imageset` —— PNG @1x 48 / @2x 96 / @3x 144（默认彩色渲染）")
    md.append("- `App/DesignSystem/VLIcon.swift` —— 自动生成 Swift 常量")
    md.append("- `design/gallery.html` —— 浏览器可视化索引")
    md.append("- `design/icons/provenance.json` —— 逐图标字形出处审计")
    md.append("")

    # ── 2. 展现方式 ────────────────────────────────────────────────
    md.append("## 2. 展现方式（瓷砖解剖）")
    md.append("")
    md.append("### 2.1 瓷砖结构（96×96 画布）")
    md.append("")
    md.append("| 图层 | 规格 |")
    md.append("|---|---|")
    md.append("| 瓷砖 | 88×88、圆角 24（≈27% squircle 观感），位于 (4,4) |")
    md.append("| 底渐变 | 三段色相偏移对角渐变：`c1 → mix(c1,c2,0.55) → darken(c2,0.76)`（c1/c2 见 §3） |")
    md.append("| 左上径向光晕 | `cx=.28 cy=.18 r=.95`，白 34%→0 |")
    md.append("| 斜向玻璃光带 | 白色 26%→0 渐变带，`rotate(-19°)` |")
    md.append("| 底部弧形内阴影 | 黑 10% 椭圆（底部厚、向上渐隐） |")
    md.append("| 内圈描边 | 白 16%、3px、圆角 22 |")
    md.append("| 字形投影 | 黑色 14%，偏移 `+1.3,+2.0` 栅格单位 |")
    md.append("| 字形 | 白色（`#FFF`），`fill` 或 `fill:none stroke:#FFF 1.5` |")
    md.append("")
    md.append("### 2.2 字形栅格变换")
    md.append("")
    md.append("```text")
    md.append("gscale = 2.92 * 24 / grid     # 24栅格→2.92；48栅格→1.46（渲染尺寸一致 ≈70px）")
    md.append("gpad   = (96 - grid * gscale) / 2   # 居中边距")
    md.append("字形层  = <g transform=\"translate(gpad gpad) scale(gscale)\">")
    md.append("投影层  = <g transform=\"translate(gpad+1.3 gpad+2.0) scale(gscale)\" opacity=.14>")
    md.append("```")
    md.append("")
    md.append("### 2.3 各来源适配规则")
    md.append("")
    md.append("| 来源 | 栅格 | 适配 |")
    md.append("|---|---|---|")
    md.append("| Fluent | 24 | regular/filled 双文件；`currentColor`→`#FFF` |")
    md.append("| Health Icons | 48 | `stroke-width=\"2\"`→`\"3\"`（视觉对齐 Fluent 1.5） |")
    md.append("| Lucide / Tabler / MDI | 24 | 描边收敛 `1.5`；**必须**包 `<g fill=\"none\" stroke=\"#FFF\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\">`（Lucide 描边属性在根元素，不包则不可见） |")
    md.append("| Font Awesome | 512 | viewBox 320×512 非方形 → `<g transform=\"translate(96 0)\">` 居中 |")
    md.append("| Material Symbols | 960 | viewBox y 偏移 -960 → `<g transform=\"translate(0 960)\">` 归一化 |")
    md.append("| 自绘 | 24 | 单色黑绘制 → 运行时替换 `#000`→`#FFF`；filled 包 `<g fill=\"#FFF\" stroke=\"none\">` |")
    md.append("")

    # ── 3. 分类与配色 ────────────────────────────────────────────────
    md.append("## 3. 分类与配色")
    md.append("")
    md.append("### 3.1 九大分组与默认瓷砖色")
    md.append("")
    md.append("| 分组 | 图标数 | 默认瓷砖色 c1→c2 | 语义 |")
    md.append("|---|---|---|---|")
    group_meta = {
        "Tab": ("五模块导航（ADR-021）"), "Common": ("通用操作/交互"), "Medical": ("医疗业务"),
        "Symptoms": ("症状观察宫格 F8"), "Members": ("成员默认头像 F3"), "Security": ("安全与审计 F1/F14"),
        "Pro": ("Pro/订阅"), "Equipment": ("医疗设备/器械"), "Organs": ("人体器官"),
    }
    for g, names in groups:
        c1, c2 = GA.GROUP_DEFAULT[g]
        md.append(f"| {g} | {len(names)} | `{hx(c1)}→{hx(c2)}` | {group_meta[g]} |")
    md.append(f"| **合计** | **{total} 定义**（Tab 五枚双态 → 185 渲染母版） | | |")
    md.append("")
    md.append("### 3.2 语义色覆盖（OVERRIDES，优先于分组默认）")
    md.append("")
    md.append("Tab 五色：`ic-tab-home` 品牌蓝、`ic-tab-records` 玫红、`ic-tab-reminders` 琥珀、`ic-tab-assistant` 紫、`ic-tab-me` 绿。")
    md.append("")
    md.append("通用操作语义色：新增/确认/同步/拍照/标签/赞/加人 = 绿；删除/错误 = 玫红；提醒角标 = 红；其余见 `generate_assets.py` 的 `OVERRIDES`（器官按器官语义配色：肺粉、肝褐、肾橙红、脊柱靛蓝等）。")
    md.append("")
    md.append("### 3.3 双色字形（COLORED）与局部色块（ACCENTS）")
    md.append("")
    md.append("| 类型 | 图标 | 语义色 |")
    md.append("|---|---|---|")
    md.append(f"| COLORED | {', '.join('`'+k+'`' for k in IL.COLORED)} | 血滴红 / 尿液琥珀 / 过敏粉 / 处方胶囊琥珀 |")
    md.append(f"| ACCENTS | {', '.join('`'+k+'`' for k in IL.ACCENTS)} | 提醒角标红、药箱红十字、医院红十字、病床红点 |")
    md.append("")
    md.append("> 注：`ic-emergency-card` 因警示红瓷砖上红十字对比度不足，不做红色叠加（保留白十字）。")
    md.append("")

    # ── 4. 逐图标规格 ────────────────────────────────────────────────
    md.append("## 4. 逐图标规格")
    md.append("")
    md.append("列说明：**瓷砖色** = 实际渲染渐变（分组默认或语义覆盖）；**字形来源** = provenance 实际命中源；**上游名** = vendor 包内名称；**双态** = Tab outline+filled；**彩色** = COLORED；**色块** = ACCENTS。")
    md.append("")
    for g, names in groups:
        md.append(f"### 4.{groups.index((g, names)) + 1} {g}（{len(names)} 枚）")
        md.append("")
        md.append("| 图标名 | 用途/语义 | 瓷砖色 | 字形来源 | 双态 | 彩色 | 色块 |")
        md.append("|---|---|---|---|---|---|---|")
        md.append(group_table(g, names))
        md.append("")

    # ── 5. 来源与许可 ────────────────────────────────────────────────
    md.append("## 5. 来源与许可")
    md.append("")
    md.append("| 来源 | 许可 | 栅格 | 说明 |")
    md.append("|---|---|---|---|")
    md.append("| Fluent UI System Icons | MIT © Microsoft | 24 | regular/filled 双态，主源 |")
    md.append("| Health Icons | CC0 | 48 | 医学专用描边 |")
    md.append("| Lucide | ISC | 24 | 交互/点缀增量主源 |")
    md.append("| Tabler | MIT | 24 | 暂空（0 枚） |")
    md.append("| MDI | Apache-2.0 | 24 | 暂空（0 枚） |")
    md.append("| Material Symbols | Apache-2.0 | 960 | 成员父母头像（man/woman） |")
    md.append("| Font Awesome Free | CC BY 4.0 | 512 | 成员子女头像（child / child-dress），需署名 |")
    md.append("| 项目自绘 | — | 24 | `icon_library.py` 内 `#000` 单色定义 |")
    md.append("")
    md.append("> 汇总声明见 `design/icons/NOTICE.md`；逐图标出处见 `design/icons/provenance.json`（本次生成时来源分布：")
    md.append(f"> {json.dumps(PROV and {s: sum(1 for v in PROV.values() if v.get('source') == s) for s in set(v.get('source','?') for v in PROV.values())}, ensure_ascii=False)}）。")
    md.append("")

    # ── 6. 验收标准 ────────────────────────────────────────────────
    md.append("## 6. 重构验收标准（DoD）")
    md.append("")
    md.append("1. **数量**：图标定义 = 180（分组数见 §3.1）；渲染母版 = 185（Tab 五枚含 filled 双态）；插画 = 7；provenance 合计 192。")
    md.append("2. **来源分布**：与 provenance.json 一致；Fluent 缺失时按优先级回退，不允许跳级。")
    md.append("3. **可复现**：`generate_assets.py` 幂等重跑，产物字节级不变（改源后全量同步）。")
    md.append("4. **视觉**：gallery.html 与重构前对比无可见偏差（白字形、渐变层次、描边一致性）。")
    md.append("5. **栅格纪律**：24 栅格描边 1.5；48 栅格描边换算 3；Lucide/Tabler/MDI 必须带描边包装组。")
    md.append("6. **母版一致**：`design/icons/src/<group>/*.svg` 与 `Resources/` PNG、`VLIcon.swift` 常量一一对应，无孤儿文件。")
    md.append("7. **禁手改**：任何产物不得手工编辑；需求变更一律改 `icon_library.py` / `fluent_map.py` / vendor 目录后重跑。")
    md.append("")

    OUT.write_text("\n".join(md), encoding="utf-8")
    print(f"[ok] {OUT.relative_to(ROOT)}  icon total={total} groups={len(groups)}")


if __name__ == "__main__":
    main()
