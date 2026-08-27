# 青囊书图标库 · 生成规格与重构需求（Icon Generation Spec）

> 版本：V1.0 · 2026-08-27
> 用途：作为**自动重构全部 SVG 图标**的需求文件；实现者应能仅凭本文 + 数据源复现全部产物。
> 数据可信度：本文档由 `design/tools/gen_icon_spec.py` **程序化生成**，逐图标读取 `icon_library.py` / `fluent_map.py` / `generate_assets.py` / `provenance.json`，与当前实现完全一致。口径：**180 枚图标定义**（Tab 五枚含 outline+filled 双态 → **185 枚渲染母版**），另 7 张插画，合计 provenance 192 项。

## 目录
- [1. 生成原则](#1-生成原则)
- [2. 展现方式（瓷砖解剖）](#2-展现方式瓷砖解剖)
- [3. 分类与配色](#3-分类与配色)
- [4. 逐图标规格](#4-逐图标规格)
- [5. 来源与许可](#5-来源与许可)
- [6. 重构验收标准（DoD）](#6-重构验收标准dod)

## 1. 生成原则

| # | 原则 | 说明 |
|---|---|---|
| P1 | 风格 | Fluent 彩色徽章瓷砖：**渐变瓷砖底 + 白色字形 + 光影层次**（技法借鉴 Icons8 Fluency/Pulsar、3dicons，素材原创） |
| P2 | 画布/栅格 | 字形画布 24×24（安全区 2..22，常规描边 1.5px 圆头圆角）；渲染画布 96×96 瓷砖 |
| P3 | 字形来源 | 按优先级 vendor：**Fluent → Health Icons → Lucide → Tabler → MDI → Font Awesome → Material Symbols → 自绘**（见 §5 许可） |
| P4 | 着色 | 分组默认色 + 语义色覆盖（OVERRIDES）+ 双色字形（COLORED）+ 局部色块（ACCENTS）四级，见 §3 |
| P5 | 命名 | kebab-case + 领域前缀：`ic-tab-*` 五模块 Tab、`ic-sym-*` 症状宫格、`ic-member-*` 成员头像、`ic-organ-*` 器官、`ic-*` 通用/医疗/安全/Pro |
| P6 | 双态 | Tab 五枚同时产出 outline + filled 双态（ADR-021 同一枚举） |
| P7 | 产出一致 | 禁手改 `Resources/` 与 `VLIcon.swift`；改源后必须重跑 `generate_assets.py`（幂等） |

**产物清单**（一键管线 `python3 design/tools/generate_assets.py`）：
- `design/icons/src/<group>/*.svg` —— 96×96 瓷砖母版（185 枚：180 定义 + 5 filled）
- `Resources/Assets.xcassets/Icons/<group>/*.imageset` —— PNG @1x 48 / @2x 96 / @3x 144（默认彩色渲染）
- `App/DesignSystem/VLIcon.swift` —— 自动生成 Swift 常量
- `design/gallery.html` —— 浏览器可视化索引
- `design/icons/provenance.json` —— 逐图标字形出处审计

## 2. 展现方式（瓷砖解剖）

### 2.1 瓷砖结构（96×96 画布）

| 图层 | 规格 |
|---|---|
| 瓷砖 | 88×88、圆角 24（≈27% squircle 观感），位于 (4,4) |
| 底渐变 | 三段色相偏移对角渐变：`c1 → mix(c1,c2,0.55) → darken(c2,0.76)`（c1/c2 见 §3） |
| 左上径向光晕 | `cx=.28 cy=.18 r=.95`，白 34%→0 |
| 斜向玻璃光带 | 白色 26%→0 渐变带，`rotate(-19°)` |
| 底部弧形内阴影 | 黑 10% 椭圆（底部厚、向上渐隐） |
| 内圈描边 | 白 16%、3px、圆角 22 |
| 字形投影 | 黑色 14%，偏移 `+1.3,+2.0` 栅格单位 |
| 字形 | 白色（`#FFF`），`fill` 或 `fill:none stroke:#FFF 1.5` |

### 2.2 字形栅格变换

```text
gscale = 2.92 * 24 / grid     # 24栅格→2.92；48栅格→1.46（渲染尺寸一致 ≈70px）
gpad   = (96 - grid * gscale) / 2   # 居中边距
字形层  = <g transform="translate(gpad gpad) scale(gscale)">
投影层  = <g transform="translate(gpad+1.3 gpad+2.0) scale(gscale)" opacity=.14>
```

### 2.3 各来源适配规则

| 来源 | 栅格 | 适配 |
|---|---|---|
| Fluent | 24 | regular/filled 双文件；`currentColor`→`#FFF` |
| Health Icons | 48 | `stroke-width="2"`→`"3"`（视觉对齐 Fluent 1.5） |
| Lucide / Tabler / MDI | 24 | 描边收敛 `1.5`；**必须**包 `<g fill="none" stroke="#FFF" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">`（Lucide 描边属性在根元素，不包则不可见） |
| Font Awesome | 512 | viewBox 320×512 非方形 → `<g transform="translate(96 0)">` 居中 |
| Material Symbols | 960 | viewBox y 偏移 -960 → `<g transform="translate(0 960)">` 归一化 |
| 自绘 | 24 | 单色黑绘制 → 运行时替换 `#000`→`#FFF`；filled 包 `<g fill="#FFF" stroke="none">` |

## 3. 分类与配色

### 3.1 九大分组与默认瓷砖色

| 分组 | 图标数 | 默认瓷砖色 c1→c2 | 语义 |
|---|---|---|---|
| Tab | 5 | `#3F8EE8→#1E5FC0` | 五模块导航（ADR-021） |
| Common | 74 | `#6C8FE8→#3F63C4` | 通用操作/交互 |
| Medical | 20 | `#38A3E8→#1773C6` | 医疗业务 |
| Symptoms | 8 | `#5B8DEF→#3A63D6` | 症状观察宫格 F8 |
| Members | 7 | `#5B8DEF→#3A63D6` | 成员默认头像 F3 |
| Security | 8 | `#6474E8→#3D4BC2` | 安全与审计 F1/F14 |
| Pro | 4 | `#9C6BFF→#6432CE` | Pro/订阅 |
| Equipment | 30 | `#38A3E8→#1773C6` | 医疗设备/器械 |
| Organs | 24 | `#38A3E8→#1773C6` | 人体器官 |
| **合计** | **180 定义**（Tab 五枚双态 → 185 渲染母版） | | |

### 3.2 语义色覆盖（OVERRIDES，优先于分组默认）

Tab 五色：`ic-tab-home` 品牌蓝、`ic-tab-records` 玫红、`ic-tab-reminders` 琥珀、`ic-tab-assistant` 紫、`ic-tab-me` 绿。

通用操作语义色：新增/确认/同步/拍照/标签/赞/加人 = 绿；删除/错误 = 玫红；提醒角标 = 红；其余见 `generate_assets.py` 的 `OVERRIDES`（器官按器官语义配色：肺粉、肝褐、肾橙红、脊柱靛蓝等）。

### 3.3 双色字形（COLORED）与局部色块（ACCENTS）

| 类型 | 图标 | 语义色 |
|---|---|---|
| COLORED | `ic-blood-drop`, `ic-sym-urine`, `ic-allergy`, `ic-prescription` | 血滴红 / 尿液琥珀 / 过敏粉 / 处方胶囊琥珀 |
| ACCENTS | `ic-tab-reminders`, `ic-medicine-box`, `ic-hospital`, `ic-ward-bed` | 提醒角标红、药箱红十字、医院红十字、病床红点 |

> 注：`ic-emergency-card` 因警示红瓷砖上红十字对比度不足，不做红色叠加（保留白十字）。

## 4. 逐图标规格

列说明：**瓷砖色** = 实际渲染渐变（分组默认或语义覆盖）；**字形来源** = provenance 实际命中源；**上游名** = vendor 包内名称；**双态** = Tab outline+filled；**彩色** = COLORED；**色块** = ACCENTS。

### 4.1 Tab（5 枚）

| 图标名 | 用途/语义 | 瓷砖色 | 字形来源 | 双态 | 彩色 | 色块 |
|---|---|---|---|---|---|---|
| `ic-tab-home` | 首页 Today（F2）· 今日任务/快速拍摄 | `#3F8EE8→#1E5FC0` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `home` | ✅ outline+filled |  |  |
| `ic-tab-records` | 健康档案 Records（F4-F8/F11）· 时间轴 | `#FF6578→#DE3350` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `board_heart` | ✅ outline+filled |  |  |
| `ic-tab-reminders` | 提醒 Reminders（F9/F10）· 用药/复诊 | `#FFAE3D→#EF7A0E` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `alert_badge` | ✅ outline+filled |  | ✅ |
| `ic-tab-assistant` | AI 助手 Assistant（F12） | `#9C6BFF→#6432CE` | 项目自绘（icon_library.py） | ✅ outline+filled |  |  |
| `ic-tab-me` | 我的 Profile（F14/F21/F22） | `#35C08C→#11895F` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `person_circle` | ✅ outline+filled |  |  |

### 4.2 Common（74 枚）

| 图标名 | 用途/语义 | 瓷砖色 | 字形来源 | 双态 | 彩色 | 色块 |
|---|---|---|---|---|---|---|
| `ic-add` | — | `#35C08C→#11895F` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `add_circle` |  |  |  |
| `ic-search` | — | `#6C8FE8→#3F63C4` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `search` |  |  |  |
| `ic-edit` | — | `#5B8DEF→#3A63D6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `edit` |  |  |  |
| `ic-delete` | — | `#FF6578→#DE3350` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `delete` |  |  |  |
| `ic-close` | — | `#7D89A4→#57637D` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `dismiss` |  |  |  |
| `ic-chevron-left` | — | `#7D89A4→#57637D` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `chevron_left` |  |  |  |
| `ic-chevron-right` | — | `#7D89A4→#57637D` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `chevron_right` |  |  |  |
| `ic-chevron-down` | — | `#7D89A4→#57637D` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `chevron_down` |  |  |  |
| `ic-more` | — | `#7D89A4→#57637D` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `more_horizontal` |  |  |  |
| `ic-filter` | — | `#7D89A4→#57637D` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `filter` |  |  |  |
| `ic-check-circle` | — | `#35C08C→#11895F` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `checkmark_circle` |  |  |  |
| `ic-calendar` | — | `#5B8DEF→#3A63D6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `calendar_ltr` |  |  |  |
| `ic-clock` | — | `#7D89A4→#57637D` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `clock` |  |  |  |
| `ic-camera` | — | `#56627D→#37425A` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `camera` |  |  |  |
| `ic-photo` | — | `#35C08C→#11895F` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `image_multiple` |  |  |  |
| `ic-scan-document` | — | `#5B8DEF→#3A63D6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `scan_text` |  |  |  |
| `ic-observe-frame` | — | `#5B8DEF→#3A63D6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `scan_camera` |  |  |  |
| `ic-share` | — | `#5B8DEF→#3A63D6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `share_ios` |  |  |  |
| `ic-export` | — | `#5B8DEF→#3A63D6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `arrow_export_ltr` |  |  |  |
| `ic-import` | — | `#5B8DEF→#3A63D6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `arrow_import` |  |  |  |
| `ic-sync` | — | `#35C08C→#11895F` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `arrow_sync` |  |  |  |
| `ic-cloud-off` | — | `#98A1B3→#6B7488` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `cloud_off` |  |  |  |
| `ic-settings` | — | `#7D89A4→#57637D` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `settings` |  |  |  |
| `ic-info` | — | `#5B8DEF→#3A63D6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `info` |  |  |  |
| `ic-warning` | — | `#FFAE3D→#EF7A0E` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `warning` |  |  |  |
| `ic-error` | — | `#FF6578→#DE3350` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `error_circle` |  |  |  |
| `ic-help` | — | `#5B8DEF→#3A63D6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `question_circle` |  |  |  |
| `ic-mic` | — | `#FF6578→#DE3350` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `mic` |  |  |  |
| `ic-waveform` | — | `#9C6BFF→#6432CE` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `sound_wave_circle` |  |  |  |
| `ic-keypad-delete` | — | `#7D89A4→#57637D` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `backspace` |  |  |  |
| `ic-star` | — | `#FFC53D→#EFA415` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `star` |  |  |  |
| `ic-archive` | — | `#7D89A4→#57637D` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `archive` |  |  |  |
| `ic-tag` | — | `#35C08C→#11895F` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `tag` |  |  |  |
| `ic-folder` | — | `#5B8DEF→#3A63D6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `folder` |  |  |  |
| `ic-bookmark` | — | `#FF6578→#DE3350` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `bookmark` |  |  |  |
| `ic-thumbs-up` | — | `#35C08C→#11895F` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `thumb_like` |  |  |  |
| `ic-thumbs-down` | — | `#7D89A4→#57637D` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `thumb_dislike` |  |  |  |
| `ic-stop-octagon` | — | `#FF6578→#DE3350` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `alert_urgent` |  |  |  |
| `ic-headset` | — | `#9C6BFF→#6432CE` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `headset` |  |  |  |
| `ic-person-add` | — | `#35C08C→#11895F` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `person_add` |  |  |  |
| `ic-check` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `check` |  |  |  |
| `ic-bell` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `bell` |  |  |  |
| `ic-phone` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `phone` |  |  |  |
| `ic-undo` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `undo-2` |  |  |  |
| `ic-retry` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `refresh-cw` |  |  |  |
| `ic-minus` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `minus` |  |  |  |
| `ic-pin` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `pin` |  |  |  |
| `ic-send` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `send` |  |  |  |
| `ic-message` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `message-square` |  |  |  |
| `ic-ignore` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `circle-x` |  |  |  |
| `ic-sun` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `sun` |  |  |  |
| `ic-moon` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `moon` |  |  |  |
| `ic-headphone` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `headphones` |  |  |  |
| `ic-volume` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `volume-2` |  |  |  |
| `ic-volume-off` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `volume-x` |  |  |  |
| `ic-ban` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `octagon-x` |  |  |  |
| `ic-replay` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `rotate-ccw` |  |  |  |
| `ic-pause` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `pause` |  |  |  |
| `ic-play` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `play` |  |  |  |
| `ic-language` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `globe` |  |  |  |
| `ic-skip` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `skip-forward` |  |  |  |
| `ic-flash` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `zap` |  |  |  |
| `ic-brush` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `brush` |  |  |  |
| `ic-attach` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `link` |  |  |  |
| `ic-copy` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `copy` |  |  |  |
| `ic-external-link` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `external-link` |  |  |  |
| `ic-exclamation` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `circle-alert` |  |  |  |
| `ic-bluetooth` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `bluetooth` |  |  |  |
| `ic-unlink` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `unlink` |  |  |  |
| `ic-backup` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `cloud-upload` |  |  |  |
| `ic-snooze` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `alarm-clock` |  |  |  |
| `ic-swap` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `arrow-left-right` |  |  |  |
| `ic-unlock` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `lock-open` |  |  |  |
| `ic-crown` | — | `#6C8FE8→#3F63C4` | Lucide（ISC，24 栅格描边） `crown` |  |  |  |

### 4.3 Medical（20 枚）

| 图标名 | 用途/语义 | 瓷砖色 | 字形来源 | 双态 | 彩色 | 色块 |
|---|---|---|---|---|---|---|
| `ic-stethoscope` | — | `#38A3E8→#1773C6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `stethoscope` |  |  |  |
| `ic-prescription` | — | `#5B8DEF→#3A63D6` | Health Icons（CC0，48 栅格描边） `prescription-document` |  | ✅ |  |
| `ic-lab-clipboard` | — | `#38A3E8→#1773C6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `clipboard_pulse` |  |  |  |
| `ic-imaging-ecg` | — | `#FF6578→#DE3350` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `heart_pulse` |  |  |  |
| `ic-vaccine` | — | `#2FBDB3→#0E8A81` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `syringe` |  |  |  |
| `ic-allergy` | — | `#FF8AB3→#E8518A` | 项目自绘·语义色填充（COLORED） |  | ✅ |  |
| `ic-vitals-chart` | — | `#35C08C→#11895F` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `arrow_trending_lines` |  |  |  |
| `ic-hospital` | — | `#38A3E8→#1773C6` | Health Icons（CC0，48 栅格描边） `hospital` |  |  | ✅ |
| `ic-doctor` | — | `#5B8DEF→#3A63D6` | 项目自绘（icon_library.py） |  |  |  |
| `ic-appointment` | — | `#35C08C→#11895F` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `calendar_checkmark` |  |  |  |
| `ic-medicine-box` | — | `#FF6578→#DE3350` | Lucide（ISC，24 栅格描边） `pill-bottle` |  |  | ✅ |
| `ic-pill` | — | `#FFAE3D→#EF7A0E` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `pill` |  |  |  |
| `ic-refill` | — | `#35C08C→#11895F` | Lucide（ISC，24 栅格描边） `package-plus` |  |  |  |
| `ic-emergency-card` | — | `#FF5A6E→#D62841` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `contact_card` |  |  |  |
| `ic-blood-drop` | — | `#FF5A6E→#D62841` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `drop` |  | ✅ |  |
| `ic-timeline` | — | `#5B8DEF→#3A63D6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `timeline` |  |  |  |
| `ic-thermometer` | — | `#FF8A65→#E85B3D` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `temperature` |  |  |  |
| `ic-weight` | — | `#38A3E8→#1773C6` | Lucide（ISC，24 栅格描边） `scale` |  |  |  |
| `ic-pulse` | — | `#38A3E8→#1773C6` | Lucide（ISC，24 栅格描边） `activity` |  |  |  |
| `ic-chart` | — | `#38A3E8→#1773C6` | Lucide（ISC，24 栅格描边） `chart-column` |  |  |  |

### 4.4 Symptoms（8 枚）

| 图标名 | 用途/语义 | 瓷砖色 | 字形来源 | 双态 | 彩色 | 色块 |
|---|---|---|---|---|---|---|
| `ic-sym-stool` | 症状宫格·大便 | `#A5764F→#7C5230` | 项目自绘（icon_library.py） |  |  |  |
| `ic-sym-urine` | 症状宫格·小便 | `#FFC53D→#EFA415` | 项目自绘·语义色填充（COLORED） |  | ✅ |  |
| `ic-sym-skin` | 症状宫格·皮肤 | `#FF9AA8→#E86A7E` | 项目自绘（icon_library.py） |  |  |  |
| `ic-sym-eye` | — | `#5B8DEF→#3A63D6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `eye` |  |  |  |
| `ic-sym-secretion` | — | `#9C6BFF→#6432CE` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `eyedropper` |  |  |  |
| `ic-sym-swelling` | — | `#FF8A65→#E85B3D` | 项目自绘（icon_library.py） |  |  |  |
| `ic-sym-generic` | — | `#FF6578→#DE3350` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `temperature` |  |  |  |
| `ic-sym-custom` | 症状宫格·其他/自定义 | `#7D89A4→#57637D` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `add_square` |  |  |  |

### 4.5 Members（7 枚）

| 图标名 | 用途/语义 | 瓷砖色 | 字形来源 | 双态 | 彩色 | 色块 |
|---|---|---|---|---|---|---|
| `ic-member-self` | — | `#3F8EE8→#1E5FC0` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `person` |  |  |  |
| `ic-member-partner` | — | `#FF6578→#DE3350` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `person_heart` |  |  |  |
| `ic-member-father` | 成员默认头像·父（Material man） | `#38A3E8→#1773C6` | Material Symbols（Apache-2.0，960 栅格实心） `man` |  |  |  |
| `ic-member-mother` | 成员默认头像·母（Material woman） | `#E869A9→#C43E85` | Material Symbols（Apache-2.0，960 栅格实心） `woman` |  |  |  |
| `ic-member-son` | 成员默认头像·子（FA child） | `#35C08C→#11895F` | Font Awesome Free（CC BY 4.0，512 栅格实心） `child` |  |  |  |
| `ic-member-daughter` | 成员默认头像·女（FA child-dress） | `#FFAE3D→#EF7A0E` | Font Awesome Free（CC BY 4.0，512 栅格实心） `child-dress` |  |  |  |
| `ic-member-family` | — | `#5B8DEF→#3A63D6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `people_team` |  |  |  |

### 4.6 Security（8 枚）

| 图标名 | 用途/语义 | 瓷砖色 | 字形来源 | 双态 | 彩色 | 色块 |
|---|---|---|---|---|---|---|
| `ic-lock` | — | `#6474E8→#3D4BC2` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `lock_closed` |  |  |  |
| `ic-shield` | — | `#38A3E8→#1773C6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `shield` |  |  |  |
| `ic-faceid` | — | `#6474E8→#3D4BC2` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `scan_person` |  |  |  |
| `ic-eye` | — | `#56627D→#37425A` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `eye` |  |  |  |
| `ic-eye-off` | — | `#56627D→#37425A` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `eye_off` |  |  |  |
| `ic-sos` | — | `#FF5A6E→#D62841` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `call` |  |  |  |
| `ic-audit-shield` | — | `#38A3E8→#1773C6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `shield_keyhole` |  |  |  |
| `ic-device` | — | `#7D89A4→#57637D` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `phone` |  |  |  |

### 4.7 Pro（4 枚）

| 图标名 | 用途/语义 | 瓷砖色 | 字形来源 | 双态 | 彩色 | 色块 |
|---|---|---|---|---|---|---|
| `ic-pro-diamond` | — | `#9C6BFF→#6432CE` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `premium` |  |  |  |
| `ic-cloud-subscription` | — | `#38A3E8→#1773C6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `cloud_sync` |  |  |  |
| `ic-family-share` | — | `#35C08C→#11895F` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `people_sync` |  |  |  |
| `ic-restore-purchase` | — | `#7D89A4→#57637D` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `arrow_rotate_counterclockwise` |  |  |  |

### 4.8 Equipment（30 枚）

| 图标名 | 用途/语义 | 瓷砖色 | 字形来源 | 双态 | 彩色 | 色块 |
|---|---|---|---|---|---|---|
| `ic-ward-bed` | — | `#5B8DEF→#3A63D6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `bed` |  |  | ✅ |
| `ic-ct` | — | `#5B8DEF→#3A63D6` | 项目自绘（icon_library.py） |  |  |  |
| `ic-mri` | — | `#6474E8→#3D4BC2` | 项目自绘（icon_library.py） |  |  |  |
| `ic-ultrasound` | — | `#38A3E8→#1773C6` | Health Icons（CC0，48 栅格描边） `ultrasound-scanner` |  |  |  |
| `ic-blood-pressure` | — | `#FF6578→#DE3350` | Health Icons（CC0，48 栅格描边） `blood-pressure-monitor` |  |  |  |
| `ic-blood-sugar` | — | `#FFAE3D→#EF7A0E` | Health Icons（CC0，48 栅格描边） `diabetes-measure` |  |  |  |
| `ic-surgery` | — | `#7D89A4→#57637D` | 项目自绘（icon_library.py） |  |  |  |
| `ic-ointment` | — | `#38A3E8→#1773C6` | 项目自绘（icon_library.py） |  |  |  |
| `ic-herbal` | — | `#35C08C→#11895F` | Health Icons（CC0，48 栅格描边） `medicine-mortar` |  |  |  |
| `ic-xray` | — | `#56627D→#37425A` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `xray` |  |  |  |
| `ic-wheelchair` | — | `#5B8DEF→#3A63D6` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `wheelchair_access` |  |  |  |
| `ic-inhaler` | — | `#2FBDB3→#0E8A81` | 项目自绘（icon_library.py） |  |  |  |
| `ic-thermometer-digital` | — | `#38A3E8→#1773C6` | Health Icons（CC0，48 栅格描边） `thermometer-digital` |  |  |  |
| `ic-medicines` | — | `#35C08C→#11895F` | Health Icons（CC0，48 栅格描边） `medicines` |  |  |  |
| `ic-medicine-bottle` | — | `#38A3E8→#1773C6` | Health Icons（CC0，48 栅格描边） `medicine-bottle` |  |  |  |
| `ic-syringe-vaccine` | — | `#2FBDB3→#0E8A81` | Health Icons（CC0，48 栅格描边） `syringe-vaccine` |  |  |  |
| `ic-hearing-aid` | — | `#7D89A4→#57637D` | Health Icons（CC0，48 栅格描边） `hearing-aid` |  |  |  |
| `ic-intravenous-drip` | — | `#38A3E8→#1773C6` | Health Icons（CC0，48 栅格描边） `intravenous-drip` |  |  |  |
| `ic-ventilator` | — | `#6474E8→#3D4BC2` | Health Icons（CC0，48 栅格描边） `ventilator` |  |  |  |
| `ic-oxygen-tank` | — | `#2FBDB3→#0E8A81` | Health Icons（CC0，48 栅格描边） `oxygen-tank` |  |  |  |
| `ic-ambulance` | — | `#FF6578→#DE3350` | Health Icons（CC0，48 栅格描边） `ambulance` |  |  |  |
| `ic-crutches` | — | `#7D89A4→#57637D` | Health Icons（CC0，48 栅格描边） `crutches` |  |  |  |
| `ic-pulse-oximeter` | — | `#6474E8→#3D4BC2` | Health Icons（CC0，48 栅格描边） `pulse-oximeter` |  |  |  |
| `ic-test-tubes` | — | `#38A3E8→#1773C6` | Health Icons（CC0，48 栅格描边） `test-tubes` |  |  |  |
| `ic-microscope` | — | `#6474E8→#3D4BC2` | Health Icons（CC0，48 栅格描边） `microscope` |  |  |  |
| `ic-bandage-adhesive` | — | `#FFD8A8→#F0A415` | Health Icons（CC0，48 栅格描边） `bandage-adhesive` |  |  |  |
| `ic-ppe-mask` | — | `#2FBDB3→#0E8A81` | Health Icons（CC0，48 栅格描边） `ppe-mask` |  |  |  |
| `ic-ppe-gloves` | — | `#2FBDB3→#0E8A81` | Health Icons（CC0，48 栅格描边） `ppe-gloves` |  |  |  |
| `ic-vision-test` | — | `#38A3E8→#1773C6` | 项目自绘（icon_library.py） |  |  |  |
| `ic-urine-sample` | — | `#FFAE3D→#EF7A0E` | Health Icons（CC0，48 栅格描边） `urine-sample` |  |  |  |

### 4.9 Organs（24 枚）

| 图标名 | 用途/语义 | 瓷砖色 | 字形来源 | 双态 | 彩色 | 色块 |
|---|---|---|---|---|---|---|
| `ic-organ-heart` | — | `#E0475C→#B02338` | Health Icons（CC0，48 栅格描边） `heart-organ` |  |  |  |
| `ic-organ-brain` | — | `#9C6BFF→#6432CE` | Fluent UI System Icons（MIT，24 栅格，regular/filled 双态） `brain` |  |  |  |
| `ic-organ-lungs` | — | `#FF8AB3→#E8518A` | Health Icons（CC0，48 栅格描边） `lungs` |  |  |  |
| `ic-organ-liver` | — | `#A5764F→#7C5230` | Health Icons（CC0，48 栅格描边） `liver` |  |  |  |
| `ic-organ-stomach` | — | `#FFAE3D→#EF7A0E` | Health Icons（CC0，48 栅格描边） `stomach` |  |  |  |
| `ic-organ-kidney` | — | `#DE7A68→#B84E3E` | Health Icons（CC0，48 栅格描边） `kidneys` |  |  |  |
| `ic-organ-intestine` | — | `#FF9AA8→#E86A7E` | Health Icons（CC0，48 栅格描边） `intestine` |  |  |  |
| `ic-organ-bone` | — | `#7D89A4→#57637D` | Lucide（ISC，24 栅格描边） `bone` |  |  |  |
| `ic-organ-tooth` | — | `#2FBDB3→#0E8A81` | Health Icons（CC0，48 栅格描边） `tooth` |  |  |  |
| `ic-organ-ear` | — | `#7D89A4→#57637D` | Health Icons（CC0，48 栅格描边） `ear-outline` |  |  |  |
| `ic-organ-mouth` | — | `#FF6578→#DE3350` | Health Icons（CC0，48 栅格描边） `mouth` |  |  |  |
| `ic-organ-nose` | — | `#38A3E8→#1773C6` | Health Icons（CC0，48 栅格描边） `nose` |  |  |  |
| `ic-organ-eye` | — | `#5B8DEF→#3A63D6` | 项目自绘（icon_library.py） |  |  |  |
| `ic-organ-hand` | — | `#38A3E8→#1773C6` | Lucide（ISC，24 栅格描边） `hand` |  |  |  |
| `ic-organ-foot` | — | `#7D89A4→#57637D` | Health Icons（CC0，48 栅格描边） `foot` |  |  |  |
| `ic-organ-joints` | — | `#7D89A4→#57637D` | Health Icons（CC0，48 栅格描边） `joints` |  |  |  |
| `ic-organ-spine` | — | `#6474E8→#3D4BC2` | Health Icons（CC0，48 栅格描边） `spine` |  |  |  |
| `ic-organ-skull` | — | `#7D89A4→#57637D` | Health Icons（CC0，48 栅格描边） `skull` |  |  |  |
| `ic-organ-blood-cells` | — | `#FF5A6E→#D62841` | Health Icons（CC0，48 栅格描边） `blood-cells` |  |  |  |
| `ic-organ-thyroid` | — | `#38A3E8→#1773C6` | Health Icons（CC0，48 栅格描边） `thyroid` |  |  |  |
| `ic-organ-throat` | — | `#FF6578→#DE3350` | Health Icons（CC0，48 栅格描边） `ear-nose-throat` |  |  |  |
| `ic-organ-prostate` | — | `#6474E8→#3D4BC2` | Health Icons（CC0，48 栅格描边） `prostate` |  |  |  |
| `ic-organ-bladder` | — | `#FFAE3D→#EF7A0E` | Health Icons（CC0，48 栅格描边） `bladder` |  |  |  |
| `ic-organ-donation` | — | `#FF6578→#DE3350` | Lucide（ISC，24 栅格描边） `heart-handshake` |  |  |  |

## 5. 来源与许可

| 来源 | 许可 | 栅格 | 说明 |
|---|---|---|---|
| Fluent UI System Icons | MIT © Microsoft | 24 | regular/filled 双态，主源 |
| Health Icons | CC0 | 48 | 医学专用描边 |
| Lucide | ISC | 24 | 交互/点缀增量主源 |
| Tabler | MIT | 24 | 暂空（0 枚） |
| MDI | Apache-2.0 | 24 | 暂空（0 枚） |
| Material Symbols | Apache-2.0 | 960 | 成员父母头像（man/woman） |
| Font Awesome Free | CC BY 4.0 | 512 | 成员子女头像（child / child-dress），需署名 |
| 项目自绘 | — | 24 | `icon_library.py` 内 `#000` 单色定义 |

> 汇总声明见 `design/icons/NOTICE.md`；逐图标出处见 `design/icons/provenance.json`（本次生成时来源分布：
> {"lucide": 42, "materialsymbols": 2, "own": 20, "own-color": 2, "healthicons": 42, "fluent": 82, "fontawesome": 2}）。

## 6. 重构验收标准（DoD）

1. **数量**：图标定义 = 180（分组数见 §3.1）；渲染母版 = 185（Tab 五枚含 filled 双态）；插画 = 7；provenance 合计 192。
2. **来源分布**：与 provenance.json 一致；Fluent 缺失时按优先级回退，不允许跳级。
3. **可复现**：`generate_assets.py` 幂等重跑，产物字节级不变（改源后全量同步）。
4. **视觉**：gallery.html 与重构前对比无可见偏差（白字形、渐变层次、描边一致性）。
5. **栅格纪律**：24 栅格描边 1.5；48 栅格描边换算 3；Lucide/Tabler/MDI 必须带描边包装组。
6. **母版一致**：`design/icons/src/<group>/*.svg` 与 `Resources/` PNG、`VLIcon.swift` 常量一一对应，无孤儿文件。
7. **禁手改**：任何产物不得手工编辑；需求变更一律改 `icon_library.py` / `fluent_map.py` / vendor 目录后重跑。
