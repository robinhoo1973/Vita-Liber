# 青囊书 · 图标缺口清单（Icon Gap List）

> 版本：V1.0 · 2026-08-27
> 来源：基于 `refactor/function-spec.md` 与 `refactor/ui-ux-spec.md` 逐节分析（组件库 §4、页面详设 §5、状态 §6、关怀 §7、通知 §8、动效 §10）
> 现状：现有 148 枚图标 + 7 插画（见 `design/icons/provenance.json`）；本清单列出实现交互与点缀所缺的图标
> 实现方式：Lucide（ISC）vendor → `design/icons/lucide/` → `icon_library.py` 登记 → `fluent_map.py` 映射 → `generate_assets.py` 全量重跑

## 一、批次与优先级

### 批次 1 · P0 交互必需 + 主题（12 枚）

| 新图标 | 用途（spec 出处） | 上游（Lucide） | 状态 |
|---|---|---|---|
| `ic-check` | 行内小对勾：确认字段行、完成态、日程"已服" | `check` | ☑ |
| `ic-bell` | 首页右上角通知铃铛 + 未读角标（§5.2） | `bell` | ☑ |
| `ic-phone` | SOS 拨打、RefusalCard 急救、改拨电话（§4.8/7.1/4.24） | `phone` | ☑ |
| `ic-undo` | TaskCard/DoseSlot 5 秒撤销、授权撤回（§4.5/4.21） | `undo-2` | ☑ |
| `ic-retry` | 错误态行内重试（§6） | `refresh-cw` | ☑ |
| `ic-minus` | 数值调整、步进器减号（spec − ×2） | `minus` | ☑ |
| `ic-pin` | 待确认 OCR >72h 置顶、翻页步进器（§5.2） | `pin` | ☑ |
| `ic-send` | F24 消息发送（§4.24） | `send` | ☑ |
| `ic-message` | F24 消息回执卡（§4.24） | `message-square` | ☑ |
| `ic-ignore` | 智能推荐资料"忽略"（§5.4） | `circle-x` | ☑ |
| `ic-sun` | 浅色主题（§5.12.1） | `sun` | ☑ |
| `ic-moon` | 深色主题（§5.12.1） | `moon` | ☑ |

### 批次 2 · P0.5 语音 / 关怀（9 枚）

| 新图标 | 用途（spec 出处） | 上游（Lucide） | 状态 |
|---|---|---|---|
| `ic-headphone` | 🎧 耳机已连接，语音回读态（§4.26/4.27） | `headphones` | ☑ |
| `ic-volume` | 🔊 无耳机"朗读"按钮（§4.27） | `volume-2` | ☑ |
| `ic-volume-off` | 🔇 屏幕确认态提示（§4.27） | `volume-x` | ☑ |
| `ic-ban` | 🛑 语音修改拒绝卡（§4.26/FR17.11） | `octagon-x` | ☑ |
| `ic-replay` | "重说/重听"（§4.13/4.14/4.18） | `rotate-ccw` | ☑ |
| `ic-pause` | 语音会话层暂停（§4.18） | `pause` | ☑ |
| `ic-play` | 语音会话层播放/重听（§4.18） | `play` | ☑ |
| `ic-language` | 🌐 语音语言入口（§5.12.3） | `globe` | ☑ |
| `ic-skip` | 语音卡"跳过"（§4.27） | `skip-forward` | ☑ |

### 批次 3 · P1 指标 / 设备 / Pro / 点缀（16 枚）

| 新图标 | 用途（spec 出处） | 上游（Lucide） | 状态 |
|---|---|---|---|
| `ic-weight` | 体重指标宫格（§5.13） | `scale` | ☑ |
| `ic-pulse` | 心率指标宫格（§5.13） | `activity` | ☑ |
| `ic-chart` | 依从率 / 消耗月报图表 | `chart-column` | ☑ |
| `ic-flash` | 扫描相机闪光灯（§5.5） | `zap` | ☑ |
| `ic-brush` | 扫描后期"添加遮挡"笔（§5.5） | `brush` | ☑ |
| `ic-attach` | 推荐挂接 / 挂接到就诊（§5.4/5.6） | `link` | ☑ |
| `ic-copy` | Toast"已复制"反馈（§4.9） | `copy` | ☑ |
| `ic-external-link` | 信源"打开原文链接"（§5.15） | `external-link` | ☑ |
| `ic-exclamation` | 色觉冗余"!"符号（§7） | `circle-alert` | ☑ |
| `ic-bluetooth` | 设备连接（§5.48） | `bluetooth` | ☑ |
| `ic-unlink` | 设备"断开" | `unlink` | ☑ |
| `ic-backup` | 立即备份 / 恢复（§5.46） | `cloud-upload` | ☑ |
| `ic-snooze` | InAppBanner"稍后"（§4.22） | `alarm-clock` | ☑ |
| `ic-swap` | 导入冲突"替换"（§5.39） | `arrow-left-right` | ☑ |
| `ic-unlock` | 敏感媒体解锁（§5.63） | `lock-open` | ☑ |
| `ic-crown` | Pro 订阅管理入口 | `crown` | ☑ |

### 暂缓 / 不纳入

| 图标 | 原因 |
|---|---|
| `ic-record` | Lucide 无 `record`；录音状态由波形动画呈现（§4.13/4.18），无需独立图标；如需可自绘红点 |
| 空态插画 | spec §3.4 P0 六类已被现有 7 张 `ill-*` 覆盖 |

## 二、实施记录

- 2026-08-27：清单建档（V1.0）。
- 2026-08-27：**三批全部落地（V2.6）**——vendor 37 枚 Lucide（ISC）至 `design/icons/lucide/`，`icon_library.py` 登记（Common 34 + Medical 3），`fluent_map.py` LUCIDE 映射扩展；图标总数 148→185，VLIcon 155→192，provenance lucide=42；`ic-record`/空态插画按「暂缓」处理。

## 三、维护说明

- 新图标一律按 `fluent_map.py` 优先级找官方字形（Fluent → Health Icons → Lucide → Tabler → MDI → Material Symbols → Font Awesome → 自绘）；本清单增量以 **Lucide** 为主源（ISC，管线已支持）。
- 禁止手改 `Resources/` 与 `VLIcon.swift`；改源后重跑 `python3 design/tools/generate_assets.py`。
- 每实现一枚在状态列打 ☑，并同步 `provenance.json`（管线自动）、`design/README.md`（版本与变更记录）。
