# 青囊书图标库 · 生成规格与重构需求（Icon Generation Spec · 精选体系）

> 版本：V2.1 · 2026-09-04 · 对应 best_selection.json `best-selection-v1`
> 用途：作为**自动重构全部 SVG 图标**的需求文件；实现者应能仅凭本文 + 数据源复现全部产物。
> 数据可信度：本文档由 `design/tools/gen_icon_spec.py` **程序化生成**，数据源 = `best_selection.json` + `provenance.json` + `design/icons/src` 母版。
> 口径：**211 枚精选母版**（213 逻辑候选去重）+ 7 张插画 = 218 项资产。

> **口径注记 V2.1（随 ui-ux-spec V3.35）**：`tab` 组（10 枚，含 filled 双态）自 V3.35 起不再渲染于 Tab 栏 / iPad 侧边栏——底部 Tab 与侧边栏已改用系统 SF Symbols 线条字形（`house`/`folder`/`bell`/`sparkles`/`person`，随选中态自动着色；带背景 pad 瓷砖会挤压文字标签致截断，TestFlight 实测）。本组瓷砖**保留不删**，供未来模块内大尺寸场景（首页/空态等）复用；当前无代码消费，勿按「无引用」清理（best_selection.json 已以 note 字段留痕）。

## 1. 生成原则

| # | 原则 | 说明 |
|---|---|---|
| P1 | 风格 | Fluent 彩色徽章瓷砖：渐变瓷砖底 + 白色字形 + 光影层次 |
| P2 | 母版模型 | **`design/icons/src/<group>/*.svg`（96×96）是唯一事实来源**——瓷砖底与字形在精选流程中已固化进母版；同步管线只做栅格化，不重新排版 |
| P3 | 字形来源 | 开源字形库（Fluent MIT / Lucide ISC / Tabler MIT / Material Apache-2.0 / FA CC BY 4.0）+ 项目自绘 + 历轮精选代次（curated-v2/v4/src），逐枚见 §4 |
| P4 | 配色 | 六组统一底色 palette（见 §3）：commonBlue / equipmentBlue / medicalBlue / orange / purple / red |
| P5 | 命名 | kebab-case + 领域前缀：`ic-tab-*`（含 `-filled` 双态）、`ic-sym-*`、`ic-member-*`、`ic-organ-*`、`ic-*` |
| P6 | 单管线 | **唯一同步入口 = `sync_best_selection.py`**；旧 `generate_assets.py`（185 体系）已退役并内置互斥锁，默认拒绝运行 |
| P7 | 产出一致 | 禁手改 `Resources/` 与 `VLIcon.swift`；改源（母版或清单）后重跑同步管线（幂等） |

## 2. 展现方式

### 2.1 母版解剖（96×96 画布）

| 图层 | 规格 |
|---|---|
| 瓷砖 | 88×88、圆角 24，位于 (4,4) |
| 底渐变 | 三段对角渐变（按组 palette 取色，§3） |
| 左上径向光晕 | 白 34%→0 |
| 斜向玻璃光带 | 白 26%→0，rotate(-19°) |
| 底部弧形内阴影 | 黑 10% |
| 内圈描边 | 白 16%、3px、圆角 22 |
| 字形 | 白色（`#FFF`）+ 微投影（黑 14%，偏移 +1.3,+2 栅格单位） |

### 2.2 同步管线（sync_best_selection.py）

```text
读 best_selection.json（211 条，校验 count/去重）
  → 校验 src/<group>/<name>.svg 存在
  → cairosvg 渲染 @1x(48) @2x(96) @3x(144) → Resources/Assets.xcassets/Icons/<Group>/<name>.imageset
  → 孤儿 imageset 清理（不在清单即删除）
  → 生成 VLIcon.swift（静态常量，保留字转义）
  → 生成 provenance.json（source/upstream/license/origin/palette/status）
```

## 3. 分类与配色

### 3.1 六组统一底色 palette

| palette | 渐变色 | 用途 |
|---|---|---|
| `commonBlue` | `#6C8FE8→#3F63C4` | 80 枚 |
| `equipmentBlue` | `#3F8EE8→#1E5FC0` | 47 枚 |
| `medicalBlue` | `#38A3E8→#1773C6` | 20 枚 |
| `orange` | `#FFAE3D→#EF7A0E` | 8 枚 |
| `purple` | `#9C6BFF→#6432CE` | 21 枚 |
| `red` | `#FF6578→#DE3350` | 35 枚 |

### 3.2 十组分布

| 分组 | 图标数 | 语义 |
|---|---|---|
| tab | 10 | 五模块导航（ADR-021，含 filled 双态）· V3.35 起 Tab/侧边栏改用 SF Symbols，本组保留供模块内大尺寸场景 |
| common | 80 | 通用操作/交互 |
| medical | 20 | 医疗业务 |
| symptoms | 8 | 症状观察宫格 F8 |
| members | 7 | 成员默认头像 F3 |
| security | 9 | 安全与审计 F1/F14 |
| pro | 4 | Pro/订阅 |
| equipment | 47 | 医疗设备/器械 |
| organs | 26 | 人体器官 |
| **合计** | **211** | |

### 3.3 处理状态（审核待办）

- ✅ 已就绪：132 枚
- ⚠️ 抢救中（待优化）：67 枚
- 🔴 需重绘：12 枚

> `rescue`/`redraw` 为精选流程标记的待优化项，重构时须逐枚处理至 `ready`。

## 4. 逐图标规格

列说明：**来源** = best_selection source（curated-v2/v4/src 为历轮精选代次）+ 开源上游名；**许可** = 开源字形许可（None=项目自持/精选代次，许可继承自其上游，见 §5）；**状态** = ready/rescue/redraw。

### 4.1 tab（10 枚）

| 图标名 | 用途/语义 | 来源 | 许可 | palette | 状态 |
|---|---|---|---|---|---|
| `ic-tab-assistant` | AI 助手 Assistant（F12）· bot 机器人字形 · V3.35 口径：Tab/侧边栏已改用 SF Symbols 线条字形（house/folder/bell/sparkles/person），本组瓷砖保留不删（ui-ux-spec V3.35「保留不删」），供未来模块内大尺寸场景复用；勿因当前无代码消费而自 best_selection.json 清理——sync_best_selection.py 会连带删除资源与 VLIcon 成员。 | fluent `bot-24-regular` | MIT | `purple` | ✅ 已就绪 |
| `ic-tab-assistant-filled` | — · V3.35 口径：Tab/侧边栏已改用 SF Symbols 线条字形（house/folder/bell/sparkles/person），本组瓷砖保留不删（ui-ux-spec V3.35「保留不删」），供未来模块内大尺寸场景复用；勿因当前无代码消费而自 best_selection.json 清理——sync_best_selection.py 会连带删除资源与 VLIcon 成员。 | fluent `bot-24-filled` | MIT | `purple` | ✅ 已就绪 |
| `ic-tab-home` | 首页 Today（F2） · V3.35 口径：Tab/侧边栏已改用 SF Symbols 线条字形（house/folder/bell/sparkles/person），本组瓷砖保留不删（ui-ux-spec V3.35「保留不删」），供未来模块内大尺寸场景复用；勿因当前无代码消费而自 best_selection.json 清理——sync_best_selection.py 会连带删除资源与 VLIcon 成员。 | curated-v4 | — | `purple` | ✅ 已就绪 |
| `ic-tab-home-filled` | — · V3.35 口径：Tab/侧边栏已改用 SF Symbols 线条字形（house/folder/bell/sparkles/person），本组瓷砖保留不删（ui-ux-spec V3.35「保留不删」），供未来模块内大尺寸场景复用；勿因当前无代码消费而自 best_selection.json 清理——sync_best_selection.py 会连带删除资源与 VLIcon 成员。 | curated-v4 | — | `purple` | ✅ 已就绪 |
| `ic-tab-me` | 我的 Profile（F14/F21/F22） · V3.35 口径：Tab/侧边栏已改用 SF Symbols 线条字形（house/folder/bell/sparkles/person），本组瓷砖保留不删（ui-ux-spec V3.35「保留不删」），供未来模块内大尺寸场景复用；勿因当前无代码消费而自 best_selection.json 清理——sync_best_selection.py 会连带删除资源与 VLIcon 成员。 | curated-v4 | — | `purple` | ✅ 已就绪 |
| `ic-tab-me-filled` | — · V3.35 口径：Tab/侧边栏已改用 SF Symbols 线条字形（house/folder/bell/sparkles/person），本组瓷砖保留不删（ui-ux-spec V3.35「保留不删」），供未来模块内大尺寸场景复用；勿因当前无代码消费而自 best_selection.json 清理——sync_best_selection.py 会连带删除资源与 VLIcon 成员。 | fluent `person_circle_24_filled` | MIT | `purple` | ✅ 已就绪 |
| `ic-tab-records` | 健康档案 Records（F4-F8/F11） · V3.35 口径：Tab/侧边栏已改用 SF Symbols 线条字形（house/folder/bell/sparkles/person），本组瓷砖保留不删（ui-ux-spec V3.35「保留不删」），供未来模块内大尺寸场景复用；勿因当前无代码消费而自 best_selection.json 清理——sync_best_selection.py 会连带删除资源与 VLIcon 成员。 | curated-v4 | — | `purple` | ✅ 已就绪 |
| `ic-tab-records-filled` | — · V3.35 口径：Tab/侧边栏已改用 SF Symbols 线条字形（house/folder/bell/sparkles/person），本组瓷砖保留不删（ui-ux-spec V3.35「保留不删」），供未来模块内大尺寸场景复用；勿因当前无代码消费而自 best_selection.json 清理——sync_best_selection.py 会连带删除资源与 VLIcon 成员。 | fluent `board_heart_24_filled` | MIT | `purple` | ✅ 已就绪 |
| `ic-tab-reminders` | 提醒 Reminders（F9/F10） · V3.35 口径：Tab/侧边栏已改用 SF Symbols 线条字形（house/folder/bell/sparkles/person），本组瓷砖保留不删（ui-ux-spec V3.35「保留不删」），供未来模块内大尺寸场景复用；勿因当前无代码消费而自 best_selection.json 清理——sync_best_selection.py 会连带删除资源与 VLIcon 成员。 | curated-v4 | — | `purple` | ✅ 已就绪 |
| `ic-tab-reminders-filled` | — · V3.35 口径：Tab/侧边栏已改用 SF Symbols 线条字形（house/folder/bell/sparkles/person），本组瓷砖保留不删（ui-ux-spec V3.35「保留不删」），供未来模块内大尺寸场景复用；勿因当前无代码消费而自 best_selection.json 清理——sync_best_selection.py 会连带删除资源与 VLIcon 成员。 | curated-v4 | — | `purple` | ✅ 已就绪 |

### 4.2 common（80 枚）

| 图标名 | 用途/语义 | 来源 | 许可 | palette | 状态 |
|---|---|---|---|---|---|
| `ic-add` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-archive` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-attach` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-backup` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-ban` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-bell` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-bluetooth` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-bookmark` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-brush` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-calendar` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-camera` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-check` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-check-circle` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-chevron-down` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-chevron-left` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-chevron-right` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-clock` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-close` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-cloud-off` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-copy` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-crown` | — | curated-v2 | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-delete` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-download` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-edit` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-error` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-exclamation` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-export` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-external-link` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-filter` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-flash` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-folder` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-headphone` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-headset` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-help` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-ignore` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-import` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-info` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-keypad-delete` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-language` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-message` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-mic` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-minus` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-moon` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-more` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-observe-frame` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-pause` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-person-add` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-phone` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-photo` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-pin` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-play` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-refresh` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-replay` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-retry` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-scan-document` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-search` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-send` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-settings` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-share` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-skip` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-snooze` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-sort` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-star` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-stop-octagon` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-sun` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-swap` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-sync` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-tag` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-thumbs-down` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-thumbs-up` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-undo` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-unlink` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-unlock` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-upload` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-visibility` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-visibility-off` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-volume` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-volume-off` | — | curated-src | — | `commonBlue` | ⚠️ 抢救中（待优化） |
| `ic-warning` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |
| `ic-waveform` | — | curated-v4 | — | `commonBlue` | ✅ 已就绪 |

### 4.3 medical（20 枚）

| 图标名 | 用途/语义 | 来源 | 许可 | palette | 状态 |
|---|---|---|---|---|---|
| `ic-allergy` | — | curated-v4 | — | `medicalBlue` | ✅ 已就绪 |
| `ic-appointment` | — | curated-v4 | — | `medicalBlue` | ✅ 已就绪 |
| `ic-blood-drop` | — | curated-v4 | — | `medicalBlue` | ✅ 已就绪 |
| `ic-chart` | — | curated-src | — | `medicalBlue` | ⚠️ 抢救中（待优化） |
| `ic-doctor` | — | curated-v4 | — | `medicalBlue` | ✅ 已就绪 |
| `ic-emergency-card` | — | curated-src | — | `medicalBlue` | ⚠️ 抢救中（待优化） |
| `ic-hospital` | — | curated-v4 | — | `medicalBlue` | ✅ 已就绪 |
| `ic-imaging-ecg` | — | curated-v4 | — | `medicalBlue` | ✅ 已就绪 |
| `ic-lab-clipboard` | — | curated-src | — | `medicalBlue` | ⚠️ 抢救中（待优化） |
| `ic-medicine-box` | — | curated-v4 | — | `medicalBlue` | ✅ 已就绪 |
| `ic-pill` | — | curated-src | — | `medicalBlue` | ⚠️ 抢救中（待优化） |
| `ic-prescription` | — | curated-v4 | — | `medicalBlue` | ✅ 已就绪 |
| `ic-pulse` | — | curated-src | — | `medicalBlue` | ⚠️ 抢救中（待优化） |
| `ic-refill` | — | curated-src | — | `medicalBlue` | ⚠️ 抢救中（待优化） |
| `ic-stethoscope` | — | curated-v4 | — | `medicalBlue` | ✅ 已就绪 |
| `ic-thermometer` | — | curated-src | — | `medicalBlue` | ⚠️ 抢救中（待优化） |
| `ic-timeline` | — | curated-v2 | — | `medicalBlue` | ⚠️ 抢救中（待优化） |
| `ic-vaccine` | — | curated-src | — | `medicalBlue` | ⚠️ 抢救中（待优化） |
| `ic-vitals-chart` | — | curated-v4 | — | `medicalBlue` | ✅ 已就绪 |
| `ic-weight` | — | curated-v4 | — | `medicalBlue` | ✅ 已就绪 |

### 4.4 symptoms（8 枚）

| 图标名 | 用途/语义 | 来源 | 许可 | palette | 状态 |
|---|---|---|---|---|---|
| `ic-sym-custom` | 症状宫格·其他/自定义 | curated-v2 | — | `orange` | ⚠️ 抢救中（待优化） |
| `ic-sym-eye` | — | curated-v4 | — | `orange` | ✅ 已就绪 |
| `ic-sym-generic` | — | curated-v4 | — | `orange` | ✅ 已就绪 |
| `ic-sym-secretion` | — | curated-src | — | `orange` | ⚠️ 抢救中（待优化） |
| `ic-sym-skin` | 症状宫格·皮肤 | tabler `bandage` | MIT (Tabler Icons) | `orange` | ✅ 已就绪 |
| `ic-sym-stool` | 症状宫格·大便 | curated-v4 | — | `orange` | ✅ 已就绪 |
| `ic-sym-swelling` | — | curated-v4 | — | `orange` | 🔴 需重绘 |
| `ic-sym-urine` | 症状宫格·小便 | curated-v4 | — | `orange` | ✅ 已就绪 |

### 4.5 members（7 枚）

| 图标名 | 用途/语义 | 来源 | 许可 | palette | 状态 |
|---|---|---|---|---|---|
| `ic-member-daughter` | 成员默认头像·女（FA child-dress） | curated-v4 | — | `purple` | ✅ 已就绪 |
| `ic-member-family` | — | curated-v4 | — | `purple` | ✅ 已就绪 |
| `ic-member-father` | 成员默认头像·父（Material man） | curated-v4 | — | `purple` | ✅ 已就绪 |
| `ic-member-mother` | 成员默认头像·母（Material woman） | curated-v4 | — | `purple` | ✅ 已就绪 |
| `ic-member-partner` | — | curated-v4 | — | `purple` | ✅ 已就绪 |
| `ic-member-self` | — | curated-v4 | — | `purple` | ✅ 已就绪 |
| `ic-member-son` | 成员默认头像·子（FA child） | curated-v4 | — | `purple` | ✅ 已就绪 |

### 4.6 security（9 枚）

| 图标名 | 用途/语义 | 来源 | 许可 | palette | 状态 |
|---|---|---|---|---|---|
| `ic-audit-shield` | — | curated-src | — | `red` | ⚠️ 抢救中（待优化） |
| `ic-device` | — | curated-src | — | `red` | ⚠️ 抢救中（待优化） |
| `ic-eye` | — | curated-src | — | `red` | ⚠️ 抢救中（待优化） |
| `ic-eye-off` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-faceid` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-fingerprint` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-lock` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-shield` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-sos` | — | curated-src | — | `red` | ⚠️ 抢救中（待优化） |

### 4.7 pro（4 枚）

| 图标名 | 用途/语义 | 来源 | 许可 | palette | 状态 |
|---|---|---|---|---|---|
| `ic-cloud-subscription` | — | curated-v4 | — | `purple` | ✅ 已就绪 |
| `ic-family-share` | — | curated-v4 | — | `purple` | ✅ 已就绪 |
| `ic-pro-diamond` | — | curated-v4 | — | `purple` | ✅ 已就绪 |
| `ic-restore-purchase` | — | curated-v4 | — | `purple` | ✅ 已就绪 |

### 4.8 equipment（47 枚）

| 图标名 | 用途/语义 | 来源 | 许可 | palette | 状态 |
|---|---|---|---|---|---|
| `ic-ambulance` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-anesthesia-machine` | — | curated-v4 | — | `equipmentBlue` | ✅ 已就绪 |
| `ic-bandage-adhesive` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-blood-pressure` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-blood-sugar` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-crutches` | — | curated-v4 | — | `equipmentBlue` | ✅ 已就绪 |
| `ic-ct` | — | curated-v4 | — | `equipmentBlue` | ✅ 已就绪 |
| `ic-defibrillator` | — | tabler `heartbeat` | MIT (Tabler Icons) | `equipmentBlue` | 🔴 需重绘 |
| `ic-dental-chair` | — | tabler `dental` | MIT (Tabler Icons) | `equipmentBlue` | ✅ 已就绪 |
| `ic-ecg` | — | tabler `heart-rate-monitor` | MIT (Tabler Icons) | `equipmentBlue` | 🔴 需重绘 |
| `ic-endoscope` | — | own | — | `equipmentBlue` | 🔴 需重绘 |
| `ic-glucometer` | — | lucide `droplet` | ISC | `equipmentBlue` | ✅ 已就绪 |
| `ic-hearing-aid` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-herbal` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-infusion-pump` | — | curated-v4 | — | `equipmentBlue` | ✅ 已就绪 |
| `ic-inhaler` | — | curated-v4 | — | `equipmentBlue` | ✅ 已就绪 |
| `ic-intravenous-drip` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-medicine-bottle` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-medicines` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-microscope` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-monitor` | — | lucide `monitor + heartbeat` | ISC | `equipmentBlue` | 🔴 需重绘 |
| `ic-mri` | — | curated-v4 | — | `equipmentBlue` | ✅ 已就绪 |
| `ic-nebulizer` | — | tabler `spray` | MIT (Tabler Icons) | `equipmentBlue` | 🔴 需重绘 |
| `ic-ointment` | — | own | — | `equipmentBlue` | ✅ 已就绪 |
| `ic-ophthalmoscope` | — | lucide `eye` | ISC | `equipmentBlue` | 🔴 需重绘 |
| `ic-otoscope` | — | lucide `ear` | ISC | `equipmentBlue` | 🔴 需重绘 |
| `ic-oxygen-concentrator` | — | curated-v4 | — | `equipmentBlue` | ✅ 已就绪 |
| `ic-oxygen-tank` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-ppe-gloves` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-ppe-mask` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-pulse-oximeter` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-scale` | — | lucide `weight` | ISC | `equipmentBlue` | ✅ 已就绪 |
| `ic-stethoscope-equipment` | — | curated-v4 | — | `equipmentBlue` | ✅ 已就绪 |
| `ic-surgery` | — | lucide `scissors` | ISC | `equipmentBlue` | ✅ 已就绪 |
| `ic-syringe-pump` | — | curated-v4 | — | `equipmentBlue` | ✅ 已就绪 |
| `ic-syringe-vaccine` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-test-tubes` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-therapeutic-bed` | — | lucide `bed` | ISC | `equipmentBlue` | 🔴 需重绘 |
| `ic-thermometer-digital` | — | curated-v4 | — | `equipmentBlue` | ✅ 已就绪 |
| `ic-ultrasound` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-urine-sample` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-ventilator` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-vision-test` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-walker` | — | own | — | `equipmentBlue` | ✅ 已就绪 |
| `ic-ward-bed` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-wheelchair` | — | curated-src | — | `equipmentBlue` | ⚠️ 抢救中（待优化） |
| `ic-xray` | — | curated-v4 | — | `equipmentBlue` | ✅ 已就绪 |

### 4.9 organs（26 枚）

| 图标名 | 用途/语义 | 来源 | 许可 | palette | 状态 |
|---|---|---|---|---|---|
| `ic-organ-bladder` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-organ-blood-cells` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-organ-bone` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-organ-brain` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-organ-donation` | — | curated-src | — | `red` | ⚠️ 抢救中（待优化） |
| `ic-organ-ear` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-organ-eye` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-organ-foot` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-organ-hand` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-organ-heart` | — | curated-src | — | `red` | ⚠️ 抢救中（待优化） |
| `ic-organ-intestine` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-organ-joints` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-organ-kidney` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-organ-liver` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-organ-lungs` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-organ-mouth` | — | curated-src | — | `red` | ⚠️ 抢救中（待优化） |
| `ic-organ-nose` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-organ-pancreas` | — | own | — | `red` | 🔴 需重绘 |
| `ic-organ-prostate` | — | curated-v4 | — | `red` | 🔴 需重绘 |
| `ic-organ-skull` | — | curated-src | — | `red` | ⚠️ 抢救中（待优化） |
| `ic-organ-spine` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-organ-spleen` | — | own | — | `red` | 🔴 需重绘 |
| `ic-organ-stomach` | — | curated-v4 | — | `red` | ✅ 已就绪 |
| `ic-organ-throat` | — | curated-src | — | `red` | ⚠️ 抢救中（待优化） |
| `ic-organ-thyroid` | — | curated-src | — | `red` | ⚠️ 抢救中（待优化） |
| `ic-organ-tooth` | — | curated-v4 | — | `red` | ✅ 已就绪 |

## 5. 来源与许可

| 来源 | 许可 | 说明 |
|---|---|---|
| Fluent UI System Icons（含 bot 24 regular/filled） | MIT © Microsoft | Tab assistant 等 4 枚 |
| Lucide | ISC | 7 枚（监护仪/手术剪/治疗床/检眼镜/耳镜/血糖仪/体重秤） |
| Tabler Icons | MIT | 5 枚（除颤/心电/牙科椅/雾化等路径借用） |
| Material Symbols | Apache-2.0 | 成员父母头像 |
| Font Awesome Free | CC BY 4.0 | 成员子女头像 |
| curated-v2/v4/src | 继承自历轮开源上游（见 NOTICE.md §7） | 123+3+64 枚精选代次 |
| 项目自绘 | — | 5 枚（内窥镜/助行器/胰腺/脾/软膏） |

> 汇总声明见 `design/icons/NOTICE.md`；逐枚出处见 `design/icons/provenance.json`（source/upstream/license 字段）。

## 6. 重构验收标准（DoD）

1. **数量**：精选母版 = 211（含 Tab filled 双态）；插画 = 7；provenance assets = 218。
2. **单管线**：`sync_best_selection.py` 幂等重跑产物字节级不变；`generate_assets.py` 默认拒绝运行（互斥锁）。
3. **清单一致性**：best_selection.json 的 count == len(icons)；group/name 去重；每条 src 母版存在（sync 内置断言）。
4. **许可完整**：每枚 provenance 有 source/license；外部借用逐条登记 NOTICE.md。
5. **状态清零**：rescue 与 redraw 逐枚处理至 ready 后方可验收上架。
6. **禁手改**：`Resources/`、`VLIcon.swift`、`provenance.json` 一律由管线生成；母版与清单是唯一允许手改的入口。
