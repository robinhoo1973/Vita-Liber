#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成「图标生成规格与重构需求」Markdown 文档（精选体系 · best-selection-v1）。

数据源（与当前实现一致）：
  - design/icons/best_selection.json  ：211 枚精选清单（名称/分组/来源/许可/色板/状态）
  - design/icons/provenance.json      ：逐图标落地出处
  - design/icons/src/<group>/*.svg    ：96×96 精选母版（唯一事实来源）
  - design/tools/sync_best_selection.py：当前唯一同步管线

产物：design/icon-spec.md —— 可作为「自动重构全部 SVG 图标」的需求文件。
用法：python3 design/tools/gen_icon_spec.py
"""

import json
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SELECTION = ROOT / "design/icons/best_selection.json"
PROVENANCE = ROOT / "design/icons/provenance.json"
OUT = ROOT / "design/icon-spec.md"

# 用途语义提示（前缀规则之外的已知语义）
USAGE = {
    "ic-tab-home": "首页 Today（F2）", "ic-tab-records": "健康档案 Records（F4-F8/F11）",
    "ic-tab-reminders": "提醒 Reminders（F9/F10）", "ic-tab-assistant": "AI 助手 Assistant（F12）· bot 机器人字形",
    "ic-tab-me": "我的 Profile（F14/F21/F22）",
    "ic-sym-pain": "症状宫格·疼痛", "ic-sym-fever": "症状宫格·发热", "ic-sym-stool": "症状宫格·大便",
    "ic-sym-urine": "症状宫格·小便", "ic-sym-bleeding": "症状宫格·出血", "ic-sym-skin": "症状宫格·皮肤",
    "ic-sym-custom": "症状宫格·其他/自定义",
    "ic-member-father": "成员默认头像·父（Material man）", "ic-member-mother": "成员默认头像·母（Material woman）",
    "ic-member-son": "成员默认头像·子（FA child）", "ic-member-daughter": "成员默认头像·女（FA child-dress）",
    "ic-member-grandfather": "成员默认头像·祖父", "ic-member-grandmother": "成员默认头像·祖母",
}

PALETTE_HEX = {
    "commonBlue": "#6C8FE8→#3F63C4",
    "equipmentBlue": "#3F8EE8→#1E5FC0",
    "medicalBlue": "#38A3E8→#1773C6",
    "orange": "#FFAE3D→#EF7A0E",
    "purple": "#9C6BFF→#6432CE",
    "red": "#FF6578→#DE3350",
}

GROUP_CN = {
    "tab": "五模块导航（ADR-021，含 filled 双态）· V3.35 起 Tab/侧边栏改用 SF Symbols，本组保留供模块内大尺寸场景", "common": "通用操作/交互",
    "medical": "医疗业务", "symptoms": "症状观察宫格 F8", "members": "成员默认头像 F3",
    "security": "安全与审计 F1/F14", "pro": "Pro/订阅", "equipment": "医疗设备/器械",
    "organs": "人体器官",
}

STATUS_CN = {"ready": "✅ 已就绪", "rescue": "⚠️ 抢救中（待优化）", "redraw": "🔴 需重绘"}


def main() -> None:
    sel = json.loads(SELECTION.read_text(encoding="utf-8"))
    icons = sel["icons"]

    by_group: dict[str, list[dict]] = {}
    for e in icons:
        by_group.setdefault(e["group"], []).append(e)
    group_order = ["tab", "common", "medical", "symptoms", "members",
                   "security", "pro", "equipment", "organs"]

    md = []
    md.append("# 青囊书图标库 · 生成规格与重构需求（Icon Generation Spec · 精选体系）")
    md.append("")
    md.append(f"> 版本：V2.1 · {date.today().isoformat()} · 对应 best_selection.json `{sel['version']}`")
    md.append("> 用途：作为**自动重构全部 SVG 图标**的需求文件；实现者应能仅凭本文 + 数据源复现全部产物。")
    md.append("> 数据可信度：本文档由 `design/tools/gen_icon_spec.py` **程序化生成**，数据源 = `best_selection.json` + `provenance.json` + `design/icons/src` 母版。")
    md.append("> 口径：**211 枚精选母版**（213 逻辑候选去重）+ 7 张插画 = 218 项资产。")
    md.append("")
    md.append("> **口径注记 V2.1（随 ui-ux-spec V3.35）**：`tab` 组（10 枚，含 filled 双态）自 V3.35 起不再渲染于 Tab 栏 / iPad 侧边栏——底部 Tab 与侧边栏已改用系统 SF Symbols 线条字形（`house`/`folder`/`bell`/`sparkles`/`person`，随选中态自动着色；带背景 pad 瓷砖会挤压文字标签致截断，TestFlight 实测）。本组瓷砖**保留不删**，供未来模块内大尺寸场景（首页/空态等）复用；当前无代码消费，勿按「无引用」清理（best_selection.json 已以 note 字段留痕）。")
    md.append("")

    # ── 1 生成原则 ──
    md.append("## 1. 生成原则")
    md.append("")
    md.append("| # | 原则 | 说明 |")
    md.append("|---|---|---|")
    md.append("| P1 | 风格 | Fluent 彩色徽章瓷砖：渐变瓷砖底 + 白色字形 + 光影层次 |")
    md.append("| P2 | 母版模型 | **`design/icons/src/<group>/*.svg`（96×96）是唯一事实来源**——瓷砖底与字形在精选流程中已固化进母版；同步管线只做栅格化，不重新排版 |")
    md.append("| P3 | 字形来源 | 开源字形库（Fluent MIT / Lucide ISC / Tabler MIT / Material Apache-2.0 / FA CC BY 4.0）+ 项目自绘 + 历轮精选代次（curated-v2/v4/src），逐枚见 §4 |")
    md.append("| P4 | 配色 | 六组统一底色 palette（见 §3）：commonBlue / equipmentBlue / medicalBlue / orange / purple / red |")
    md.append("| P5 | 命名 | kebab-case + 领域前缀：`ic-tab-*`（含 `-filled` 双态）、`ic-sym-*`、`ic-member-*`、`ic-organ-*`、`ic-*` |")
    md.append("| P6 | 单管线 | **唯一同步入口 = `sync_best_selection.py`**；旧 `generate_assets.py`（185 体系）已退役并内置互斥锁，默认拒绝运行 |")
    md.append("| P7 | 产出一致 | 禁手改 `Resources/` 与 `VLIcon.swift`；改源（母版或清单）后重跑同步管线（幂等） |")
    md.append("")

    # ── 2 展现方式 ──
    md.append("## 2. 展现方式")
    md.append("")
    md.append("### 2.1 母版解剖（96×96 画布）")
    md.append("")
    md.append("| 图层 | 规格 |")
    md.append("|---|---|")
    md.append("| 瓷砖 | 88×88、圆角 24，位于 (4,4) |")
    md.append("| 底渐变 | 三段对角渐变（按组 palette 取色，§3） |")
    md.append("| 左上径向光晕 | 白 34%→0 |")
    md.append("| 斜向玻璃光带 | 白 26%→0，rotate(-19°) |")
    md.append("| 底部弧形内阴影 | 黑 10% |")
    md.append("| 内圈描边 | 白 16%、3px、圆角 22 |")
    md.append("| 字形 | 白色（`#FFF`）+ 微投影（黑 14%，偏移 +1.3,+2 栅格单位） |")
    md.append("")
    md.append("### 2.2 同步管线（sync_best_selection.py）")
    md.append("")
    md.append("```text")
    md.append("读 best_selection.json（211 条，校验 count/去重）")
    md.append("  → 校验 src/<group>/<name>.svg 存在")
    md.append("  → cairosvg 渲染 @1x(48) @2x(96) @3x(144) → Resources/Assets.xcassets/Icons/<Group>/<name>.imageset")
    md.append("  → 孤儿 imageset 清理（不在清单即删除）")
    md.append("  → 生成 VLIcon.swift（静态常量，保留字转义）")
    md.append("  → 生成 provenance.json（source/upstream/license/origin/palette/status）")
    md.append("```")
    md.append("")

    # ── 3 分类与配色 ──
    md.append("## 3. 分类与配色")
    md.append("")
    md.append("### 3.1 六组统一底色 palette")
    md.append("")
    md.append("| palette | 渐变色 | 用途 |")
    md.append("|---|---|---|")
    for p, hexv in PALETTE_HEX.items():
        n = sum(1 for e in icons if e.get("palette") == p)
        md.append(f"| `{p}` | `{hexv}` | {n} 枚 |")
    md.append("")
    md.append("### 3.2 十组分布")
    md.append("")
    md.append("| 分组 | 图标数 | 语义 |")
    md.append("|---|---|---|")
    for g in group_order:
        n = len(by_group.get(g, []))
        md.append(f"| {g} | {n} | {GROUP_CN.get(g, '')} |")
    md.append(f"| **合计** | **{len(icons)}** | |")
    md.append("")
    md.append("### 3.3 处理状态（审核待办）")
    md.append("")
    for s, label in STATUS_CN.items():
        n = sum(1 for e in icons if e.get("status") == s)
        md.append(f"- {label}：{n} 枚")
    md.append("")
    md.append("> `rescue`/`redraw` 为精选流程标记的待优化项，重构时须逐枚处理至 `ready`。")
    md.append("")

    # ── 4 逐图标规格 ──
    md.append("## 4. 逐图标规格")
    md.append("")
    md.append("列说明：**来源** = best_selection source（curated-v2/v4/src 为历轮精选代次）+ 开源上游名；**许可** = 开源字形许可（None=项目自持/精选代次，许可继承自其上游，见 §5）；**状态** = ready/rescue/redraw。")
    md.append("")
    for i, g in enumerate(group_order, 1):
        entries = sorted(by_group.get(g, []), key=lambda e: e["name"])
        md.append(f"### 4.{i} {g}（{len(entries)} 枚）")
        md.append("")
        md.append("| 图标名 | 用途/语义 | 来源 | 许可 | palette | 状态 |")
        md.append("|---|---|---|---|---|---|")
        for e in entries:
            name = f"`{e['name']}`"
            usage = USAGE.get(e["name"], "—")
            if e.get("note"):
                usage += f" · {e['note']}"
            src = e.get("source") or "—"
            if e.get("upstream"):
                src += f" `{e['upstream']}`"
            lic = e.get("license") or "—"
            pal = f"`{e.get('palette', '—')}`"
            st = STATUS_CN.get(e.get("status"), e.get("status", "—"))
            md.append(f"| {name} | {usage} | {src} | {lic} | {pal} | {st} |")
        md.append("")

    # ── 5 来源与许可 ──
    md.append("## 5. 来源与许可")
    md.append("")
    md.append("| 来源 | 许可 | 说明 |")
    md.append("|---|---|---|")
    md.append("| Fluent UI System Icons（含 bot 24 regular/filled） | MIT © Microsoft | Tab assistant 等 4 枚 |")
    md.append("| Lucide | ISC | 7 枚（监护仪/手术剪/治疗床/检眼镜/耳镜/血糖仪/体重秤） |")
    md.append("| Tabler Icons | MIT | 5 枚（除颤/心电/牙科椅/雾化等路径借用） |")
    md.append("| Material Symbols | Apache-2.0 | 成员父母头像 |")
    md.append("| Font Awesome Free | CC BY 4.0 | 成员子女头像 |")
    md.append("| curated-v2/v4/src | 继承自历轮开源上游（见 NOTICE.md §7） | 123+3+64 枚精选代次 |")
    md.append("| 项目自绘 | — | 5 枚（内窥镜/助行器/胰腺/脾/软膏） |")
    md.append("")
    md.append("> 汇总声明见 `design/icons/NOTICE.md`；逐枚出处见 `design/icons/provenance.json`（source/upstream/license 字段）。")
    md.append("")

    # ── 6 验收标准 ──
    md.append("## 6. 重构验收标准（DoD）")
    md.append("")
    md.append("1. **数量**：精选母版 = 211（含 Tab filled 双态）；插画 = 7；provenance assets = 218。")
    md.append("2. **单管线**：`sync_best_selection.py` 幂等重跑产物字节级不变；`generate_assets.py` 默认拒绝运行（互斥锁）。")
    md.append("3. **清单一致性**：best_selection.json 的 count == len(icons)；group/name 去重；每条 src 母版存在（sync 内置断言）。")
    md.append("4. **许可完整**：每枚 provenance 有 source/license；外部借用逐条登记 NOTICE.md。")
    md.append("5. **状态清零**：rescue 与 redraw 逐枚处理至 ready 后方可验收上架。")
    md.append("6. **禁手改**：`Resources/`、`VLIcon.swift`、`provenance.json` 一律由管线生成；母版与清单是唯一允许手改的入口。")
    md.append("")

    OUT.write_text("\n".join(md), encoding="utf-8")
    print(f"[ok] {OUT.relative_to(ROOT)} icons={len(icons)} groups={len(group_order)}")


if __name__ == "__main__":
    main()
