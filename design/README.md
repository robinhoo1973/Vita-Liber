# 青囊书设计资产规范（Design Assets）

> 版本：V2.10
> 上游依据：`refactor/ui-ux-spec.md` §2.1 / §3.1 / §3.3 / §3.4、`refactor/tech-spec.md` §1.2、`refactor/comercial-spec.md` §1–§2
> 本目录是**设计资产唯一母版来源**；`Resources/Assets.xcassets` 为其编译期产物（均入库，保证无设计工具链也能构建）。

---

## 1. 目录结构（对齐 tech-spec §1.2 的 `Resources/` 约定）

```
design/                          # 设计源文件（不参与编译）
├── README.md                    # 本规范
├── gallery.html                 # 浏览器可视化索引（深色底瓷砖预览）
├── icons/
│   ├── fluent/                  # Fluent UI System Icons 字形（MIT，24 栅格）
│   ├── healthicons/             # Health Icons 字形（CC0，48 栅格）
│   ├── lucide/                  # Lucide 字形（ISC，24 栅格）
│   ├── materialsymbols/         # Material Symbols 字形（Apache-2.0，960 栅格）
│   ├── fontawesome/             # Font Awesome Free 字形（CC BY 4.0，512 栅格，V2.5 起）
│   ├── tabler/                  # Tabler Icons 字形（MIT，24 栅格，暂空）
│   ├── mdi/                     # Material Design Icons 字形（Apache 2.0，24 栅格）
│   ├── NOTICE.md                # 三方许可声明（上架并入开源许可页）
│   ├── src/<group>/*.svg        # 瓷砖图标母版（96×96 画布）
│   ├── provenance.json          # 每枚图标的字形出处（fluent/healthicons/lucide/tabler/own）
│   └── tools/                   # 管线脚本
├── illustrations/src/*.svg      # 彩色扁平空态插画母版（240×180）
├── brand/app-icon.svg           # App 图标 SVG 母版（1024，管线回退源）
├── brand/app-icon.png           # App 图标位图母版（1024，V2.7 起优先）
├── previews/                    # 走查拼图 / 渲染预览
└── tools/                       # 管线入口
    ├── icon_library.py          # 自绘字形定义（仅 Fluent 缺失的 12 枚）
    ├── fluent_map.py            # 概念 → 官方 Fluent/Lucide 字形映射表
    ├── vendor_fluent.py         # 官方字形固化脚本
    ├── vendor_lucide.py         # Lucide 字形固化脚本（ISC，V2.3 起）
    ├── illustration_library.py  # 插画与 App 图标定义
    ├── render_before_after.py   # 变更 Before/After 对比页（V2.3 起）
    └── generate_assets.py       # 一键管线（见 §5）

Resources/                       # tech-spec §1.2 顶层 Resources/
└── Assets.xcassets/             # 【生成】Xcode 资产目录，project.yml 已挂载
    ├── AppIcon.appiconset/      # 1024 单尺寸
    ├── AccentColor.colorset/    # = brand-primary
    ├── Colors/*.colorset/       # §3.1 token 色板（含 dark 外观）
    ├── Icons/<Group>/*.imageset # @1x(48)/@2x(96)/@3x(144)，默认渲染（彩色）
    └── Illustrations/*.imageset # @1x/@2x/@3x，默认渲染（彩色）
```

## 2. 风格规范（Fluent 彩色徽章瓷砖，V1.3）

| 参数 | 值 |
|---|---|
| 风格基准 | Fluent icon pack 视觉语言：**渐变徽章瓷砖底 + 白色字形 + 光影层次** |
| 画布 | 96×96；瓷砖 88×88、圆角 24（≈27% squircle 观感）；字形区 24 栅格 ×2.92 |
| 图层顺序 | 三段色相偏移对角渐变（c1→混合→c2 加深 24%）→ 左上径向光晕（白 34%→0，光源 28%,18%）→ 斜向玻璃光带（-19° 圆角带，白 26% 渐隐）→ 底部弧形内阴影（椭圆黑 10%）→ 内圈描边（白 16%、3px）→ 字形投影（黑 14%，偏移 +1.3,+2 栅格单位）→ 白色字形 |
| 字形来源 | **多源直接引用开源库**：Fluent UI System Icons（MIT）+ Health Icons（CC0 医学专用）+ Lucide（ISC）+ Tabler（MIT）+ Material Symbols（Apache-2.0）+ Font Awesome Free（CC BY 4.0）；仅无库可引时自绘。逐枚出处见 `provenance.json`，许可汇总见 `icons/NOTICE.md` |
| Tab 双态 | outline（常规瓷砖）+ filled（白色实面字形），仅五枚 Tab；命名 `-filled` 后缀 |
| 着色 | 彩色资产为**默认渲染**（非 template）；语义色由瓷砖渐变承载（见 §4） |
| 瓷砖基准尺寸 | 48pt；更大用途（快速拍摄 56pt 按钮等）用 `.resizable().frame()` |
| 插画 | 240×180 彩色扁平：渐变面 + 白色元素 + 琥珀点缀，与瓷砖同色彩语言 |
| App 图标 | 位图母版 `brand/app-icon.png`（V2.7 起 AI 生成，管线优先使用）；`app-icon.svg` 保留为回退源 |

### 2.1 灵感源与技法借鉴（借鉴不复制）

调研站点：Icons8 **Fluency**（微软规范彩色风）、Icons8 **Pulsar Gradient**（Win11 渐变）、**3dicons.co**（CC0 三维渐变徽章）、Flaticon 渐变概念包，及用户提供的 Fluent icon pack 参考图。仅借鉴以下**通用视觉技法**，全部图层代码为本项目原创 SVG 生成，未下载/复制/描摹任何站点素材：

1. 左上单光源 + 径向光晕（3dicons 徽章的受光模式）；
2. 渐变带色相偏移与三段过渡（Fluency/Pulsar 的深度感）；
3. 斜向玻璃光带（参考图 glossy 观感）；
4. 底部弧形接触阴影 + 内圈亮边（徽章立体感）；
5. 字形微投影（Fluency 的字形浮起感）；
6. 双色字形（Fluency 多色拼装技法的克制版）：仅 7 枚高语义图标使用语义色填充/叠加，其余保持纯白，确保全库统一性。

## 3. 命名规范（kebab-case + 领域前缀）

| 前缀 | 含义 | 例 |
|---|---|---|
| `ic-tab-*` | 五模块 Tab（ADR-021 同一枚举双端渲染） | `ic-tab-home` / `ic-tab-home-filled` |
| `ic-*` | 通用操作/医疗业务/安全/Pro | `ic-add`、`ic-stethoscope`、`ic-lock` |
| `ic-sym-*` | 症状观察宫格（F8 步骤1 选类型） | `ic-sym-stool`…`ic-sym-custom` |
| `ic-member-*` | 成员默认头像字形（瓷砖色=关系色） | `ic-member-mother` |
| `ill-*` | 空态插画（§3.4 六类复用 + onboarding） | `ill-empty-records` |
| 色板 | 与 §3.1 token 同名（`/`→`-`） | `semantic-danger`、`grade-e` |

Swift 侧经生成文件 `App/DesignSystem/VLIcon.swift` 单出口引用（对齐 `Localization/L10n.swift` 纪律）：

```swift
Image(VLIcon.tabHome)                 // 常规态（彩色瓷砖）
Image(VLIcon.tabRemindersFilled)      // Tab 激活态（filled 字形）
Image(VLIcon.illEmptyRecords)         // 空态插画
```

## 4. 语义色板（瓷砖渐变，top→bottom）

| 语义 | 渐变 | 应用 |
|---|---|---|
| 品牌蓝 | #3F8EE8→#1E5FC0 | tab-home、member-self |
| 玫红 | #FF6578→#DE3350 | tab-records、delete/error/mic/bookmark、medicine-box、imaging-ecg、member-partner |
| 琥珀 | #FFAE3D→#EF7A0E | tab-reminders、warning/pill、member-daughter |
| 青绿 | #35C08C→#11895F | tab-me、add/check/sync、appointment、member-son |
| 紫罗兰 | #9C6BFF→#6432CE | tab-assistant、waveform/headset、sym-secretion |
| 天蓝 | #38A3E8→#1773C6 | 医疗默认、shield、vaccine（青） |
| 石板灰 | #7D89A4→#57637D | 中性操作（close/more/filter/settings…） |
| 警示红 | #FF5A6E→#D62841 | emergency-card、blood-drop、sos（BR-012 场景） |
| 其余 | 见 `generate_assets.py` OVERRIDES | 症状宫格（棕/黄/粉/橙…）、Pro 紫等 |

## 5. 管线与维护

```bash
# 依赖：pip install cairosvg pillow
python3 design/tools/generate_assets.py     # 全量再生成（幂等）

# 官方 Fluent 字形升级/换用时（需 node）：
npm install @fluentui/svg-icons
python3 design/tools/vendor_fluent.py <node_modules>/@fluentui/svg-icons/icons

# Lucide 字形升级/换用（ISC，V2.3 起）：
npm install lucide-static
python3 design/tools/vendor_lucide.py <node_modules>/lucide-static/icons
```

- **新增图标**：按 `fluent_map.py`（Fluent MIT）→ `HEALTH_MAP`（Health Icons CC0）→ `LUCIDE`（Lucide ISC）→ `TABLER_MAP`（Tabler MIT）顺序找官方字形；确无再在 `icon_library.py` 自绘 → 跑管线。禁止手改 `Resources/` 内产物。
- **vendor 命令**：`python3 design/tools/vendor_fluent.py <@fluentui/svg-icons/icons>`；`python3 design/tools/vendor_lucide.py <lucide-static/icons>`；`python3 design/tools/vendor_iconify.py <node_modules>`（需 `npm i @iconify-json/healthicons @iconify-json/tabler`）。
- **改色/加色**：改 `generate_assets.py` 的 `OVERRIDES`/`COLORS` → 跑管线。
- **换官方字形**：改 `fluent_map.py` 映射 → 重跑 vendor + 管线。
- 走查：浏览器开 `design/gallery.html`（深色底瓷砖效果），或 `design/previews/contact-sheet-*.png`；变更对比用 `design/previews/icon-replace-before-after.html`（`render_before_after.py` 生成）。

## 6. 版权与出处（重要）

- **字形**：直接引用 Microsoft Fluent UI System Icons（MIT）、Health Icons（CC0）、Lucide（ISC）、Tabler（MIT）、Material Symbols（Apache-2.0）、Font Awesome Free（CC BY 4.0）；vendor 副本与许可全文见 `design/icons/NOTICE.md`，逐枚出处见 `design/icons/provenance.json`（上架前将 NOTICE 并入 App 的开源许可页，SP-48 已预留该行）。
- **自绘补位（10 枚）**：`ic-prescription`、`ic-allergy`、`ic-hospital`、`ic-sym-stool`、`ic-sym-skin`、`ic-sym-swelling`、`ic-member-father/mother/son/daughter`，以及全部插画与 App 图标——本项目自有产物。
- 瓷砖底/渐变/高光封装层为本项目自有设计；未引用任何第三方位图或带版权的图标包（参考图仅为风格基准，未复制其素材）。
- **第三方商业包评估记录（2026-08-26）**：Iconshock「Fluent Mega Pack」经许可核查**不予采用**——其免费档仅提供 ≤72px PNG、限个人使用且强制署名，商业使用需付费授权（单包 $19 起），与本项目商业分发及 vendor 入库方式冲突；且该包为微软 Fluent 规范的第三方仿制渐变包，视觉上已被本管线等价实现。**若未来购买其商业授权**：将下载的 SVG 置于独立目录后仿照 `vendor_fluent.py` 增加来源分支即可接入，但在出示授权凭证前禁止入库。

## 7. 与需求文档的映射（抽查锚点）

- **Tab 五枚**：ui-ux-spec §2.1 → `home` / `board_heart` / `alert_badge`（自带未读角标点）/ 自有双半脑 AI 徽章 / `person_circle`。
- **业务概念映射**：§3.4 → 就诊 `ic-stethoscope`、处方 `ic-prescription`、检验 `ic-lab-clipboard`、影像 `ic-imaging-ecg`、观察 `ic-observe-frame`、敏感锁定 `ic-eye-off`、AI `ic-tab-assistant`。
- **快速拍摄四宫格**：病历 `ic-folder`、报告 `ic-lab-clipboard`、处方 `ic-prescription`、症状 `ic-thermometer`。
- **商业化红线**（comercial-spec §2.1）：`ic-lock`/`ic-pro-diamond` 仅用于门禁与付费墙上下文；免费能力永不配锁图标。
- **空态插画六类**（§3.4）+ onboarding 主视觉，全部彩色扁平风。
- **成员瓷砖色**即 MemberConfirmBar「关系色」的提案实现，SP 定稿后只需改 `OVERRIDES` 重跑。

## 8. 变更记录

| 版本 | 日期 | 说明 |
|---|---|---|
| V2.10 | 2026-08-27 | App 图标改用 `~/Downloads/Designer (8).png`，仅尺寸调整（1254²→1024²，LANCZOS） |
| V2.9 | 2026-08-27 | App 图标改用 `~/Downloads/Designer (7).png`，仅尺寸调整（1254²→1024²，LANCZOS）；回退源 `app-icon.svg` 保留 |
| V2.8 | 2026-08-27 | App 图标背景 Fluent 化：白底改为三段色相偏移对角渐变（亮蓝→主蓝→紫）+ 左上光晕 + 斜向玻璃光带 + 底部暗角 + 内容投影；边缘洪泛填充仅替换外围背景、内容原样保留；新增 `appicon_fluent_bg.py` |
| V2.7 | 2026-08-27 | App 图标改用 AI 生成位图母版 `brand/app-icon.png`（1024，源自 `~/Downloads/Designer.png`）；管线 `generate_assets.py` 改为位图母版优先、SVG 回退，AppIcon1024.png/预览同步更新 |
| V2.6 | 2026-08-27 | 按 `icon-gap-list.md` 缺口清单落地 37 枚交互/点缀图标（全部 Lucide ISC，批次1 P0+主题 12、批次2 语音/关怀 9、批次3 指标/设备/Pro/点缀 16）；图标总数 148→185，VLIcon 155→192；`ic-record` 由波形动画替代暂缓 |
| V2.5 | 2026-08-27 | 子女头像改用 Font Awesome Free（CC BY 4.0）：`ic-member-son`(child) / `ic-member-daughter`(child-dress)，512 栅格实心（320 宽 viewBox x 居中归一化），优先级置于 Material Symbols 之前；父母保持 Material（Apache-2.0） |
| V2.4 | 2026-08-27 | 家庭成员头像改用经典 Material Symbols（Apache-2.0）：`ic-member-father`(man) / `ic-member-mother`(woman) / `ic-member-son`(boy) / `ic-member-daughter`(girl)，960 栅格实心剪影归一化接入管线；`ill-empty-ai` 双半脑高度缩 1/5（scaleY 2.426→1.941）并垂直居中（y 28–152，中心 90） |
| V2.3 | 2026-08-27 | 图标替换落地：5 枚字形改直接引用 Lucide（ISC）——`ic-organ-bone`(bone) / `ic-medicine-box`(pill-bottle) / `ic-organ-hand`(hand) / `ic-organ-donation`(heart-handshake) / `ic-refill`(package-plus)，Tabler 源清零；管线新增 lucide 源（24 栅格描边收敛 1.5）与 `vendor_lucide.py`；`ic-tab-assistant` 黄点→白圈对齐 `ill-empty-ai` 插画机器人；`ill-empty-ai` 双半脑迭代（顶部裁切修复→居中→两次纵向拉长，最终 `translate(115 171) scale(1.3 2.426)`，高约 154 单位贯穿画布）、AI 徽章精确居中于画布 (120,90)；provenance/NOTICE/README 同步；新增变更对比页 `render_before_after.py` |
| V2.2 | 2026-08-27 | 修复 vision-test：E 视标增加中心平移并置于独立内层方框；AI Tab 移除旧扫描眼，改为放大的双半脑+中央 AI 徽章（蓝色电路/粉色有机褶皱/绿色 AI 标牌）；重新生成实际 PNG、gallery 与 Swift 资产常量并完成核验 |
| V1.7 | 2026-08-26 | 器官组二次走查：心（桃心+血管断端+动脉沟，深红瓷砖）、胃（+皱褶线）、肠（改结肠框+内褶）、耳（连续外耳廓）、骨（Lucide ISC 犬骨轮廓改绘）重绘；新增口/鼻/眼/手/足五枚（手足几何改绘自 Lucide ISC）；organ-heart 移出 fluent 映射 |
| V1.8 | 2026-08-26 | 器官/器械全量扩展 +22（总数 143（V1.9 后 144））：器官 +5（肺/肝/肾/口/鼻/牙改 CC0 Health Icons 直接引用，另增关节/脊柱/颅骨/血细胞/器官捐献）；器械 +17（血压监测仪/B超仪/处方笺/研钵/医院/电子体温计/药板/药瓶/疫苗注射器/助听器/输液/呼吸机/氧气瓶/救护车/拐杖/血氧仪/试管/显微镜/创可贴/N95口罩/医用手套/尿样杯，全部 CC0 直接引用）；骨改 Tabler(MIT)；管线升级多源 vendor（vendor_iconify.py）与 48 栅格自适应变换；NOTICE 合并为三源声明 |
| V1.7 | 2026-08-26 | 扩展 22 枚医疗图标（检查设备 12：CT/MRI/X光/B超/血压/血糖/手术/软膏/中药/雾化/病床/轮椅；器官 10：心肺肝肾胃肠脑骨牙耳）；成员四头像重绘为正面发型剪影（平顶/包脸/蓬松/丸子），doctor 改 V 领+侧垂听诊管；修复 vendor 残留导致的 doctor/urine 未生效根因（vendor 增加清理逻辑）；医院十字与门留隙；参考图仅借鉴造型（Freepik 付费不可复制、gstatic 来源不明、svgsilh 被 CF 拦截） |
| V1.5 | 2026-08-26 | 走查修正五项：ic-hospital 重绘（宽体门诊楼，去教堂感）、ic-doctor 改自有字形（人形+听诊器，弃 Fluent 版）、sym-stool 三层漩涡重绘、sym-urine 液滴+水流+水洼、member 父母子女实发剪影重绘；App 图标重构为「青囊」束口药袋+探出书页+白十字 |
| V1.4 | 2026-08-26 | 双色字形实验定稿（1:1 对比 Icons8 Fluency/Pulsar 后决策）：新增 COLORED 整字形语义色填充（blood-drop 红/sym-urine 琥珀/allergy 粉/prescription 胶囊琥珀）与 ACCENTS 局部叠加（提醒角标红、药箱/医院红十字）；emergency-card 经对比度评估撤除叠加；provenance 口径新增 own-color |
| V1.3 | 2026-08-26 | 瓷砖渲染体系升级（技法借鉴 Icons8 Fluency/Pulsar、3dicons CC0，素材全原创）：三段色相偏移渐变、左上径向光晕、斜向玻璃光带、弧形内阴影、内圈描边、字形投影；新增 §2.1 灵感源清单 |
| V1.2 | 2026-08-26 | 新增 §6 第三方商业包评估记录：Iconshock Fluent Mega Pack 许可不兼容，不予采用；明确购买后的接入路径 |
| V1.1 | 2026-08-26 | **风格彻底重构**：单色线条 → Fluent 彩色瓷砖（渐变底+白字形+高光/内阴影）；字形改为直接引用 Fluent UI System Icons（MIT，82 枚）+ 自绘补位 12 枚；插画转彩色扁平；App 图标立体化；新增 provenance.json 出处审计与 NOTICE |
| V1.0 | 2026-08-26 | 初版：94 枚图标、7 张空态插画、App 图标、24 个 token 色板；管线与 gallery 就位 |
