# 青囊书设计资产规范（Design Assets）

> 版本：V1.0
> 上游依据：`refactor/ui-ux-spec.md` §2.1 / §3.1 / §3.3 / §3.4、`refactor/tech-spec.md` §1.2、`refactor/comercial-spec.md` §1–§2
> 本目录是**设计资产唯一母版来源**；`Resources/Assets.xcassets` 为其编译期产物（均入库，保证无设计工具链也能构建）。

---

## 1. 目录结构（对齐 tech-spec §1.2 的 `Resources/` 约定）

```
design/                          # 设计源文件（不参与编译）
├── README.md                    # 本规范
├── gallery.html                 # 浏览器可视化索引（深浅色切换，无构建步骤）
├── icons/src/<group>/*.svg      # Fluent 风图标母版（24×24 栅格）
├── illustrations/src/*.svg      # 空态插画母版（240×180，单色线条风）
├── brand/app-icon.svg           # App 图标母版（1024）
├── previews/                    # 走查拼图 / 渲染预览
└── tools/
    ├── icon_library.py          # 图标定义（唯一手写源）
    ├── illustration_library.py  # 插画与 App 图标定义
    └── generate_assets.py       # 一键管线（见 §5）

Resources/                       # tech-spec §1.2 顶层 Resources/
└── Assets.xcassets/             # 【生成】Xcode 资产目录，project.yml 已挂载
    ├── AppIcon.appiconset/      # 1024 单尺寸
    ├── AccentColor.colorset/    # = brand-primary
    ├── Colors/*.colorset/       # §3.1 token 色板（含 dark 外观）
    ├── Icons/<Group>/*.imageset # @1x/@2x/@3x，template 渲染
    └── Illustrations/*.imageset # @1x/@2x/@3x，template 渲染
```

## 2. Fluent 风格规范

| 参数 | 值 |
|---|---|
| 画布 | 24×24，安全区 2..22（与 Fluent UI System Icons 同栅格） |
| 常规体 | 描边 1.5px，圆头（round cap）+ 圆角连接（round join） |
| Tab 激活态 | filled 实面变体（`-filled` 后缀），仅五枚 Tab 提供 |
| 着色 | 母版纯黑绘制 → imageset 标记 `template` 渲染，运行时由 `foregroundColor` tint |
| 插画 | 240×180、描边 4px 单色线条（ui-ux-spec §3.4「单色线条风」），同样 template |
| App 图标 | 青囊药袋提环 × 摊开医书 × 医疗十字；brand 蓝渐变底、success 绿十字 |

## 3. 命名规范（kebab-case + 领域前缀）

| 前缀 | 含义 | 例 |
|---|---|---|
| `ic-tab-*` | 五模块 Tab（ADR-021 同一枚举双端渲染） | `ic-tab-home` / `ic-tab-home-filled` |
| `ic-*` | 通用操作/医疗业务/安全/Pro | `ic-add`、`ic-stethoscope`、`ic-lock` |
| `ic-sym-*` | 症状观察宫格（F8 步骤1 选类型） | `ic-sym-stool`…`ic-sym-custom` |
| `ic-member-*` | 成员默认头像字形（配关系色 tint） | `ic-member-mother` |
| `ill-*` | 空态插画（§3.4 六类复用 + onboarding） | `ill-empty-records` |
| 色板 | 与 §3.1 token 同名（`/`→`-`） | `semantic-danger`、`grade-e` |

Swift 侧经生成文件 `App/DesignSystem/VLIcon.swift` 单出口引用（对齐 `Localization/L10n.swift` 纪律）：

```swift
Label("首页", image: VLIcon.tabHome)             // outline 态
Image(VLIcon.tabRemindersFilled)                  // Tab 激活态（filled）
Image(VLIcon.illEmptyRecords)                     // 空态插画
```

## 4. 与需求文档的映射（抽查锚点）

- **Tab 五枚**：ui-ux-spec §2.1（house/heart.text.square/bell.badge/sparkles/person.crop.circle 的 Fluent 等价实现）。
- **业务概念映射**：§3.4 表——就诊 `ic-stethoscope`、处方 `ic-prescription`、检验 `ic-lab-clipboard`、影像 `ic-imaging-ecg`、观察 `ic-observe-frame`、敏感锁定 `ic-eye-off`、AI `ic-tab-assistant`。
- **快速拍摄四宫格**：病历 `ic-folder`、报告 `ic-lab-clipboard`、处方 `ic-prescription`、症状 `ic-thermometer`。
- **商业化红线**（comercial-spec §2.1）：`ic-lock`/`ic-pro-diamond` 仅用于门禁与付费墙上下文；**提醒/敏感保护/离线/搜索/适老/紧急卡等免费能力永不配锁图标**。
- **空态插画六类**（§3.4）：空档案 / 空提醒 / 无搜索结果 / AI 无资料·无授权 / 空药箱批次 / 空审计（P1 备用）。
- **成员关系色**：`member-*` 七色为**提案值**（ui-ux-spec §4.4 仅约定「关系色」未定稿），SP 定稿后只需改 `generate_assets.py` 的 `COLORS` 表重跑。

## 5. 管线与维护

```bash
# 依赖（本仓库 CI/本地均可用）：pip install cairosvg pillow
python3 design/tools/generate_assets.py     # 全量再生成（幂等）
```

- **新增图标**：只在 `icon_library.py` 加条目 → 跑管线；禁止手改 `Resources/` 内产物。
- **改色/加色**：改 `generate_assets.py` 的 `COLORS`（light/dark 各一）→ 跑管线。
- 母版 SVG 可直接导入 Figma/Illustrator 二次加工，改完回填定义文件保持单源。
- 走查：浏览器开 `design/gallery.html`，或看 `design/previews/contact-sheet-*.png`。

## 6. 变更记录

| 版本 | 日期 | 说明 |
|---|---|---|
| V1.0 | 2026-08-26 | 初版：94 枚图标（含 Tab 五枚双态）、7 张空态插画、App 图标、24 个 token 色板；管线与 gallery 就位 |
