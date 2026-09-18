# 代码功能映射索引（Code-Function Mapping）

> 版本：V1.0 · 快照日期：2026-09-18 · 覆盖：App/ + CoreKit/Sources/ + Tests/ + UITests/ 全部 366 个 Swift 源文件
> 用途：调试定位索引——按「现象 → 模块 → 文件 → 类型/方法」反查实现位置。每个符号后的 `(file:line)` 即声明锚点。
> 注意：行号为本次全仓审查（8 代理并行，OOP 颗粒度/复用/简化/效率轮）编辑终态实测；后续重构须同步更新锚点，源码内注释才是行为权威。

## 使用方式
1. 按现象归属模块定位文件小节（顺序：Domain → Protocols → Infrastructure → AppShell → DesignSystem → Localization → Compat → Features → Tests）。
2. 在小节内 grep 符号名；`(file:line)` 即实现位置。
3. 中文一行摘要为索引用途；行为细节、审查注释以源码为准。

## 符号说明
- 机械表（L10n 键表 1,610 键、迁移 DDL、金样、词表、图标目录）按「结构 + 锚点 + 计数」记录，不逐项枚举。
- 私有助手一行一条；SwiftUI `body` 只记渲染职责；枚举 case 合并一行。
- 本索引不替代 grep：定位到文件后，用 `grep -n '符号名' 文件` 快速跳到实现。

## 分区
| 片段 | 覆盖 |
|---|---|
| d1/d2 | CoreKit/Sources/Domain（125 文件） |
| i1/i2 | CoreKit/Sources/Infrastructure（92 文件）+ Protocols 评审摘要 |
| a1 | App/AppShell + DesignSystem + Localization + Compat（47 文件） |
| f1 | Features A：Capture/Confirm/Documents/Members/Onboarding/Records/Voice |
| f2 | Features B：Settings/Reminders/Trends/Medications/Home/Observations/Emergency/Health/Appointments/Search/Notifications/Caregiving |
| t1 | Tests/ + UITests/（42 文件，SU/FR 编号索引） |


## CoreKit/Sources/Domain/AILocal.swift
- `AIQuery` (5) — F12 本地检索式 AI 的查询值对象（文本 + 可选成员上下文）
  - `var text: String` (6) — 问题文本
  - `var member: UUID?` (7) — 提问时锁定的成员
- `DataAccessScope` (11) — AI 检索的最小访问范围
  - `var patientIds: Set<UUID>` (12) — 允许读取的患者集合
- `EntityReference` (17) — 检索命中引用实体（唯一类型化出处）
  - `var kind: String` (18) — 资料类别键
  - `var refID: UUID` (19) — 资料行 id
  - `var title: String` (20) — 标题
  - `var snippet: String` (21) — 摘录
  - `var isSensitive: Bool` (24) — 敏感资料标记（BR-007/008 锁定态依据）
- `AIAnswer` (33) — 七段结构答案根值对象
  - `Body` (34) — 答案三形态：组装七段 / 拒识 / 急救卡
    - `case composed(SevenPart) / refused(Refusal) / emergencyCard` (35-37)
  - `SevenPart` (39) — 七段结构（类型化数据，App 层 L10n 渲染）
    - `TermExplanation` (49) — 术语解释对
    - `SourceLine` (59) — 来源说明行（kind + title）
    - `var citationCount: Int` (46) — 引用计数
    - `var terminologyPairs` (56) — 术语解释列表
    - `var citations` (66) — 引用实体（非空保证）
    - `var excerpts: [String]` (67) — 原文摘录
    - `var sources: [SourceLine]` (68) — 来源说明
    - `var gradeBadge: String` (69) — E 级 AI 徽章
  - `Refusal` (71) — 拒识答案
    - `Reason` (72) — insufficientData / highRiskTopic
    - `Action` (75) — addRecords / consultDoctor
  - `var body: Body` (88) — 答案主体
  - `var citations: [EntityReference]` (91) — 组装体的引用快读
- `extension AIAnswer` (99) — 红线答案工厂
  - `static var emergency` (101) — BR-012 急救卡固定答案
  - `static var insufficientData` (109) — BR-006 资料不足拒识（detail 不上屏）
  - `static var highRiskTopic` (117) — BR-006 高风险话题拒识
- `TerminologyStore` (127) — P0 内置医学术语词典（与 GuidelineSource 严格分离）
  - `static let shared` (128) — 共享默认词典
  - `func explain(_:)` (138) — 术语 → 通俗解释
  - `func terms(in:)` (139) — 文本中命中的词条（字符序排序保证确定性）
- `ScriptFolding` (153) — 安全词表匹配前的有界繁→简 + 小写折叠
  - `static let hantToHans` (155) — 有界繁体→简体字表（仅安全词表用字）
  - `func fold(_:)` (166) — 折叠主函数
- `EmergencyKeywordRules` (172) — BR-012 紧急关键词规则
  - `static let keywords` (184) — 简体紧急词表
  - `static let englishKeywords` (189) — 英文紧急词表
  - `func match(_:)` (196) — 折叠后匹配
- `HighRiskTopicRules` (208) — BR-006 高风险话题（调药/停药/剂量）规则
  - `static let keywords` (209) — 简体关键词表
  - `static let doseChangePatterns` (217) — 剂量更改句式正则（字符串形态，登记用）
  - `static let englishKeywords` (233) — 英文高风险词表
  - `static let doseChangeRegexes` (240) — 预编译正则缓存（热路径复用）
  - `func match(_:)` (244) — 折叠后匹配
- `FullTextSearch` (256) — FTS 检索端口协议
  - `func search(_:scope:limit:)` (257) — 检索返回引用
- `LocalRetrievalProvider` (261) — P0 本地检索式 AI 实现（无生成文本）
  - `func answer(_:scope:)` (270) — 紧急短路 → 高危拒识 → 检索 → 组装/降级
  - `func compose(_:question:)` (300) — 七段组装 + 负清单执法
- `AIProvider` (320) — AI 提供者协议
  - `func answer(_:scope:)` (321) — 统一作答入口
- `AuditedAIProvider` (325) — 审计装饰器（先委托后审计，记录访问事实）
  - `func answer(_:scope:)` (332) — 委托 + 按答案形态记审计
- `SafeAIProvider` (386) — 红线纵深防御装饰器（BR-012/BR-006 前置短路 + 引用非空）
  - `func answer(_:scope:)` (390) — 三条不变量执法

## CoreKit/Sources/Domain/AlertEngine.swift
- `AlertSeverity` (6) — 四级观察提示级别
  - `case L0 / L1 / L2 / L3` (7)
- `GuidelineEntry` (12) — 信源库条目（B 级阈值单一事实源）
  - 字段组 (13-28) — id/书目信息/指标键/单位
  - `var l1Low…l3High` (22-27) — L1-L3 上下限阈值
- `MetricReading` (44) — 待定级读数（含 A 级报告范围与设备来源三键）
  - `var reportRange: ReferenceRange?` (50) — A 级优先范围
  - `var sourceName/Version/Product/Identifier/sampleID` (53-57) — 设备来源元数据
- `DeviceMetricRow` (76) — 设备读数落库行（小时窗口聚合，min/max/count）
- `EvidencePath` (116) — 证据卡建议路径
  - `case retestNow / scheduleVisit / observe` (117-119)
- `AlertEvidenceCard` (122) — 五段证据卡（类型化事实/信源/路径 + legacy 兼容字段）
  - `var levelTag` (124) — L1/L2/L3 级别标签
  - `var legacyFacts…legacyDisclaimer` (146-149) — 旧 JSON 兼容直出
  - `init(from:)` (177) — 解码含旧字段 fallback
  - `func encode(to:)` (203) — 编码
- `WordingBlacklist` (231) — 措辞负清单（FR16.5 一票否决）
  - `static let patterns` (232) — 8 条否决句式
  - `static let compiledPatterns` (252) — 预编译正则缓存
  - `func violation(in:)` (256) — 命中返回「类别：句式」
- `AlertRuleEngine` (266) — 规则预警引擎（纯函数）
  - `static let consecutiveThreshold` (267) — 连续 3 次门槛
  - `func guidelineKey(for:)` (274) — 读数键 → 信源种子键归一
  - `func rank(_:)` (280) — 定级序单一比较口径（L0<L1<L2<L3）
  - `func unitAlias(_:)` (289) — 单位同义标签归一（非换算）
  - `func severity(for:guideline:)` (301) — 单次读数定级（A 级优先 / 单位守卫 / 阈值链）
  - `GradedReading` (354) — 定级读数（severity nil = 范围不可用）
  - `func sustainedViolations(_:sustainedWindow:)` (372) — 连续越限 run 门槛（≥3 次或 ≥10 分钟）
  - `func anchors(of:sustainedWindow:)` (401) — run → 锚定读数（最严重、同级取最晚）
  - `func escalate(recent:guideline:)` (417) — 最近窗口恰 3 次全越限 → 最严重级
  - `func evidenceCard(for:severity:guideline:)` (431) — 五段证据卡组装（无生成式解读）

## CoreKit/Sources/Domain/AllergyRules.swift
- `SevereReactionRules` (7) — FR23.3 严重反应判定
  - `static let canonicalSeverities` (11) — DDL CHECK 词汇（mild/moderate/severe）
  - `static let severeKeywords` (17) — F12 基础词表 + 过敏补充（单一事实源）
  - `func triggersEmergencyCard(severity:reactionTags:note:)` (23) — 重度或关键词 → 急救引导
  - `static let allergenKinds / severityValues / reactionTagOptions` (34-39) — 选项常量（视图禁内联中文）
  - `func canonicalSeverity(_:)` (45) — 展示词 → 落库规范值
  - `func severityLevel(of:)` (59) — 严重度等级 0/1/2（配色/排序单一事实源）
  - `func displaySeverity(_:)` (69) — 规范值 → 展示词（回显）

## CoreKit/Sources/Domain/AppRoute.swift
- `AppRoute` (9) — 类型安全路由目标（Codable，通知深链契约；~55 case 覆盖全 SP）
  - `case sosHelp` (11) — SP-33 唯一免门禁路径
  - `case memberList / memberDetail(UUID)` (14-15) — SP-06
  - `case encounterList / encounterDetail(UUID) / encounterForm(UUID?)` (18-20) — SP-08
  - `case documentList / documentDetail(UUID) / importSource / scanCapture(CaptureKind?)` (23-26) — SP-09/10/11
  - `case pendingOcrQueue / pendingCard(String)` (31-32) — SP-53 / 待办卡续确认
  - `case medicalCard(kind:id:patientId:)` (33) — 已确认卡详情（白名单验证）
  - `case prescriptionLine(patientId:lineId:)` (34) — v25 处方行详情
  - `case healthExamDetail(patientId:id:)` (35) — v27 体检主卡详情
  - `case trendChart(patientId:metric:) / metricOverview / metricQuickEntry` (38-40) — SP-13
  - `case observationCreate / observationDetail(UUID) / doctorShowcase(patientId:)` (43-45) — SP-14/§5.8
  - `case medicationPlan(UUID) / medicationPlanForm(UUID?) / stockLotDetail(UUID) / stockLotEdit(UUID?) / medicationCabinet / reminderToday` (48-53) — F9
  - `case appointmentList / appointmentDetail(UUID) / appointmentForm(UUID?) / visitPrepPackage` (56-59) — F10
  - `case globalSearch` (65) — SP-20（assistantChat/History 已退役删除）
  - `case exportWizard / backupRestore` (68-69) — F13
  - `case settingsRoot…voiceEngineLab` (72-80) — F14 设置族
  - `case emergencyCardConfig` (83) — SP-28
  - `case deviceConnection / healthImportedData(kind:patientId:) / alertHistory / alertEvidence(patientId:eventId:severity:) / guidelineSourceDetail(UUID)` (86-97) — F16
  - `case careModeConfig…voiceNotePanel` (100-104) — F18 关怀族
  - `case voiceSession` (107) — SP-34
  - `case helpCenter / feedbackReport` (110-111) — F22
  - `case allergyList / allergyCreate` (114-115) — F23
  - `case caregiverTasks / sentStatusHub` (118-119) — F24
  - `case healthProblemList…termsAndPrivacy` (122-126) — 评审批 H15 补登记
  - `case paywall` (129) — SP-61
- `MainModuleID` (133) — 路由所属 Tab
  - `case home / records / reminders / health / me` (134)
  - `func tab(of:)` (136) — 路由 → Tab 映射（通知点击切换 selection）

## CoreKit/Sources/Domain/AppSettings.swift
- `AppSettingKey` (6) — 设置键枚举（单一事实源；~50 case，每个必声明 defaultValue）
  - `var defaultValue: String` (61) — 键默认值 switch
- `SpeechRateTier` (108) — 默认语速三档
  - `var utteranceRate: Float` (113) — AVSpeechUtterance.rate 映射单一事实源
- `SettingsStoring` (124) — 设置读写端口协议
- `QuietHoursRules` (133) — 安静时段判定（BR 纯函数）
  - `func isActive(start:end:now:)` (136) — 跨午夜区间判定；非法窗口失败开放
  - `func minuteOf(_:)` (148) — "HH:mm" → 分钟
- `SettingsRules` (157) — 设置语义规则
  - `func rememberedUnitKey(for:)` (162) — 单位记忆键构造单点
  - `var lastSelectedMetricKey` (169) — 上次指标记忆键
  - `func voiceLocales(_:)` (173) — 语音语言列表解析（保序去重）
  - `func preferredVoiceLocale(_:)` (182) — 主语言 = 列表首位
  - `func resolved(_:key:)` (186) — 未设置 → 默认值
  - `static let gateGraceSecondsLegalValues` (194) — FR1.4 合法值域 0/15/60
  - `func dateFormatTag(of:) / dateFormatValue(of:)` (198/206) — 日期格式 tag ↔ 存储值映射
  - `func appliesToExisting(_:)` (220) — 追溯语义（默认类设置仅影响新建）

## CoreKit/Sources/Domain/ASRInstallLayout.swift
- `ASRInstallLayout` (16) — 模型安装目录布局与保留规则（三条正交语义）
  - `static let variantSeparator / shortHashLength` (17/19) — 目录名分隔符与 sha 前缀长度
  - `func directoryName(variant:version:sha256:uuid:)` (22) — 生成目录名（变体缺省退回历史布局）
  - `func parseDirectory(_:)` (37) — 从末尾定长解析（不按 `-` 切分）
  - `func keepingForPrune(candidates:newlyInstalled:activeName:)` (68) — 每变体保留最新 + 新装 + 激活
  - `func isDeletable(directoryName:activeName:)` (93) — 生效档不可删

## CoreKit/Sources/Domain/ASRModelCatalog.swift
- `ASRModelDescriptor` (4) — 随包权重能力目录条目
  - `func languageCode(for:)` (13) — locale → 模型语言码（方言判定优先）
  - `func decoderLanguage(for:mode:)` (26) — 解码语言提示（qwen3 官方名称/whisper ISO/其余空）
  - `var availableLocales: Set<String>` (35) — 可用 locale 集合
- `ASRModelCatalog` (44) — 模型目录（qwen3/zipformer/dolphin/whisper 四条目）
  - `static let dialectLocales` (45) — 方言 locale 集合
  - `static let models` (47) — 四条目能力表（机械表）
  - `func model(for:)` (66) — 按档位取条目
  - `func qwenHotwords(_:)` (71) — 热词串裁剪（24 词 / 512 字节窗）
  - `func qwenLanguageName(forCode:)` (84) — Qwen3 官方语言名称表（30 语种字典）
  - `func automaticChoice(locale:)` (97) — 按覆盖优先级选引擎（qwen3→zipformer→dolphin→whisper→classic）

## CoreKit/Sources/Domain/ASRModelRelease.swift
- `ASRModelReleaseIndex` (9) — 运行时下载索引（验签来源）
  - `static let supportedSchemaVersion` (21) — 客户端支持的结构版本 = 1
  - `var isSupported: Bool` (23) — 版本兼容判定
- `ASRModelRelease` (27) — 单模型发布条目
  - `var variant: String?` (46) — 变体档位（small/medium/large；nil = 单档家族）
  - `func variantWeight(_:)` (65) — 档位大小序权重（small=0…未知=3）
  - `var isPublished: Bool` (75) — 已发布判定（sha256 非空 + 字节数 + slug）
  - `func isCompatible(appVersion:)` (82) — minAppVersion 兼容判定
  - `func resolvedURL(baseURL:)` (93) — 下载地址解析（仅相对路径 + https 双保险）
  - `func isNewer(than:)` (109) — 版本比较
- `ASRVersion` (121) — 混合形态版本比较（语义版本 + 日期）
  - `func isNewer(_:than:)` (122) — 逐段比较，多段者新
  - `func compareSegment(_:_:)` (138) — 单段：纯数字整数比 / 数字前缀 / 自然序
  - `func leadingDigits(_:)` (150) — 段首数字前缀
  - `func segments(_:)` (156) — 按非字母数字切段
- `ASRVariantRecommendation` (165) — 设备 RAM 档位建议
  - `func variantIndex(ramBytes:variantCount:)` (166) — ≥6GB 最大档 / ≥4GB 中档 / 其余最小档

## CoreKit/Sources/Domain/CaptureQuality.swift
- `GrayscaleImage` (19) — 灰度位图（解码产物纯数据）
- `GrayscaleDecoding` (30) — 图像解码端口（实现在 Infrastructure）
  - `func decode(_:maxDimension:)` (33) — 解码降采样，失败必抛错
- `ImageDecodeError` (36) — corruptData
- `QualityTag` (42) — 质量标签键（rawValue = L10n 键名）
- `CaptureQuality` (52) — 单图质量评估结果（分项 + 综合分 + 标签）
  - `func meetsThreshold(_:)` (68) — 达标判定（默认 0.5）
- `DuplicateDetectionResult` (72) — 重复检测结果（精确/感知两级）
- `CaptureQualityAssessor` (100) — 质量评估器（拉普拉斯/亮度/遮挡启发式）
  - `func assess(_:)` (102) — 评估主函数
- `DuplicateDetectionService` (171) — 重复检测服务（SHA-256 注入 + pHash）
  - `func register(recordID:imageData:decoder:)` (187) — 注册既有图片
  - `func detect(_:decoder:)` (196) — 检测新图重复
  - `func perceptualHash(from:)` (224) — 32x32 → 低频 8x8 二值化 64 位指纹

## CoreKit/Sources/Domain/CardConfirmationRules.swift
- `CardConfirmationRules` (7) — 卡级确认与字段编辑业务规则（BR-003 D→C 单一事实源）
  - `static let confirmAllConfidenceFloor` (14) — 批量确认置信下限 0.6
  - `func confirmable(_:isRequired:)` (37) — 批量资格四条件谓词
  - `func confirmedFields(_:requiredKeys:)` (47) — 字段组批量升 C
  - `func confirmingAllFields(_:)` (58) — 全卡卡级确认
  - `func confirmingDraft(_:)` (76) — 主卡草稿确认（拒绝先移除）
  - `func requiredFieldsAwaitingConfirmation(_:row:)` (88) — 单面待确认必填
  - `func requiredFieldsAwaitingConfirmation(_:)` (105) — 全卡待确认必填（去重保序）
  - `ReviewItem` (118) — 复核队列项（severity 0-3 风险序）
  - `func anchorId(key:rowId:)` (132) — 字段锚点 id（视图跳转与清单共用）
  - `func reviewQueue(_:)` (146) — 按风险排序的待复核清单
  - `func revise(_:at:rowId:to:)` (205) — 字段编辑入口（关联/编码失效纪律）

## CoreKit/Sources/Domain/CardKindRegistry.swift
- `CardKindEntry` (9) — 卡类注册表条目（事实表 + 必填/可选键集）
  - `var sharedAllowed / rowAllowed` (24-25) — 放行面并集
  - `var headerTable` (27) — 表头表名
  - `func effectiveRowRequired(forEmptyRow:)` (34) — 空行豁免口径单一出处（本批新增，避同名属性遮蔽）
- `CardKindRegistry` (51) — 卡类单一事实源
  - `static let prescriptionRowOptional` (53) — 处方行级可选键表
  - `static let labHeaderOptional` (60) — 检验表头可选键表
  - `static let hospitalizationOptional` (65) — 住院可选键表
  - `static let entries` (73) — 15 个卡类条目（机械表：metric_sample/encounter/hospitalization/diagnosis/exam_report/prescription/claim_item/medication/immunization/health_exam/clinical_conclusion/surgery/treatment_record）
  - `func entry(for:)` (168) — 按 kind 查条目
  - `func optionalCatalog(kind:present:rowLevel:)` (174) — 「添加字段」目录（稳定排序）

## CoreKit/Sources/Domain/CardTemplateMatcher.swift
- `CardMatchThresholds` (10) — FR6.9 匹配双阈值
  - `static let allFields / requiredFields` (12/14) — 0.5 / 0.8
- `CardTemplate` (18) — 卡模板（理解层键 → 模板键映射 + 行触发/派生/文档类型限定）
- `MatchedCardRow` (43) — 匹配卡行（fields + 行级缺失必填）
- `MatchedCard` (53) — 匹配卡（共享 + 行 + 覆盖率 + 完整度徽章）
  - `var allFields` (82) — 共享 + 各行（统一读面）
  - `func reviseField(at:rowId:to:)` (87) — 编辑转发（CardConfirmationRules）
  - `func confirmingAllFields()` (95) — 卡级确认转发
  - `init(from:)` (103) — 解码（missingRequired 字符串回充规则）
  - `func encode(to:)` (118) — 编码
- `CardTemplateMatcher` (129) — 卡模板匹配引擎
  - `static let ocrTemplates` (131) — 14 个卡类模板目录（机械表）
  - `static let narrativeSharedKeys` (259) — 共享叙事键（多段换行并入）
  - `static let labCompanionKeys` (270) — 检验行同 rawText 伴随键
  - `static let rowCompanionKinds` (273) — 行级伴随归行的卡类
  - `func expandedFields(for:fields:)` (277) — 体检血压合体拆分
  - `func derivedValue(for:documentTypeKey:)` (289) — 文档类型派生共享键值
  - `func match(fields:pageIndex:documentTypeKey:templates:)` (299) — 单页匹配入口
  - `func matchOne(_:fields:pageIndex:documentTypeKey:)` (311) — 单模板匹配编排（行/共享/覆盖率/徽章）
  - `func buildRows(for:fields:requiredRules:consumed:)` (351) — 行装配（本批自 matchOne 提取）
  - `func buildShared(for:fields:consumed:documentTypeKey:ruleKeys:)` (409) — 共享装配 + 派生键（本批提取）
  - `func rowFields(for:draft:)` (464) — 行触发字段拆分（检验名称/数值/单位）
  - `func companionFields(for:draft:)` (498) — 伴随字段归行（参考范围拆低/高）
  - `func referenceBounds(_:)` (516) — 兼容转发（ExtractionPatterns）
  - `func encounterKind(for:)` (523) — 文档类型 → 就诊类型（DocumentTypeKey 同源）
## CoreKit/Sources/Domain/CareMode.swift
- `CareModeMetrics` (5) — 关怀模式交互参数（环境化呈现，非平行代码库）
  - `static let standard / care` (28-29) — 常规/关怀两套参数预设
- `TremorGuard` (36) — 震颤防抖判定
  - `func shouldAccept(lastActionAt:now:mode:)` (37) — 间隔 ≥0.3s 才计一次
- `HoldToConfirm` (46) — 长按确认判定
  - `func requiredSeconds(mode:) / accepted(holdSeconds:mode:)` (47/50) — 时长取用与接受判定
- `SOSRules` (56) — SOS 路径规则（BR-012）
  - `static let maxSteps` (57) — 两步可达
  - `func isGateExempt(_:)` (60) — 门禁唯一豁免
  - `func requiresHoldConfirm(_:mode:)` (65) — 长按误触防护
- `HospitalDeepLink` (71) — 挂号深链条目
  - `func url(bookingNo:)` (78) — 占位替换生成深链
- `HospitalDeepLinkRegistry` (83) — 本地深链映射表（FR10.6 无网可用）
  - `func link(for:in:)` (84) — 精确匹配
  - `static let defaults` (92) — 3 条默认映射（机械表）
  - `func fuzzyLink(for:in:)` (106) — 双向包含模糊降级

## CoreKit/Sources/Domain/ClinicalEpisodes.swift
- `FactSource` (15) — 事实来源 CHECK 枚举（ocr/manual）
- `FactPlaceholder` (20) — 父键/时间戳占位常量
  - `static let unassignedId / unassignedDate` (22-23) — store 落库时填写
- `Hospitalization` (27) — 住院期 DDL 镜像（§C.2；~33 列原文/文本列）
- `Diagnosis` (86) — 诊断逐条投影（§C.3）
  - `static let diagnosisTypes` (88) — CHECK 枚举 9 值
- `ExamReport` (123) — 检查/影像/病理报告（§C.4）
  - `static let reportTypes` (125) — CHECK 枚举 9 值
  - `var reportSource / healthExamId` (149-150) — v27 报告来源与体检枢纽回指
- `LabReport` (169) — 检验报告表头（§C.5；sourceCardId 幂等键）
- `LabResult` (216) — 非数值/半定量检验项（原文保存、不进趋势）

## CoreKit/Sources/Domain/ClinicalFieldLabels.swift
- `ClinicalFieldLabels` (9) — 临床文书打印标签别名单一事实源
  - `static let prefixAliases` (11) — 理解层键 → 标签前缀别名表（~40 键，机械表）
  - `static let conclusionTypeLabels` (114) — 结论类型标签表（7 类）
  - `static let headerNarrativeConclusionTypes` (125) — 归首页叙事块的结论类型
  - `static let treatmentTypeVocabulary` (128) — 治疗类型词表（5 类）
  - `static let generalExamKeys` (137) — 体检一般检查数值键
  - `func splitBloodPressure(_:)` (140) — 「128/82」→ 收缩/舒张
  - `func splitNumberUnit(_:)` (148) — 「65.5 kg」→ 值/单位
  - `static let bloodPressurePattern / numberUnitPattern` (156/158) — 预编译正则
  - `static let diagnosisTypeLabels` (162) — 诊断类型标签表（8 类）
  - `static let plainDiagnosisLabels` (174) — 无类型语义诊断标签
  - `static let reportTypeVocabulary` (177) — 报告类型词表（9 类）
  - `static let reportTitleMarkers` (191) — 标题证据词
  - `static let qualitativeResultPattern` (194) — 定性结果词表/比较符文法
  - `static let narrativeLabels` (199) — 叙事键剥标签用全部标签并集
  - `func conclusionLabel(prefixOf:)` (203) — 行首结论标签 → 类型
  - `func conclusionType(forLabel:)` (211) — 打印标签 → canonical
  - `func treatmentType(forValue:)` (219) — 治疗词 → canonical
  - `func diagnosisLabel(prefixOf:)` (227) — 行首诊断标签 → 类型
  - `func diagnosisType(forLabel:)` (236) — 打印标签 → canonical
  - `func reportType(forValue:)` (244) — 类型词 → canonical
  - `func reportType(inTitle:)` (252) — 报告标题行 → 类型
  - `func splitQualitativeReading(_:)` (260) — 「项目 定性结果」拆名/结果
  - `func contains(_:token:)` (273) — ASCII 整词 / 其余子串匹配

## CoreKit/Sources/Domain/CodeResolver.swift
- `CodingSystem` (13) — 编码体系（SQL CHECK 词汇）
- `CodeKind` (21) — 码表类别
- `MatchRoute` (29) — FR25.1 命中路由（override/curated/fold/manual）
- `CodeResolution` (33) — 术语解析结果（概念 + canonical + 展示名 + 置信）
- `ResolvedReading` (61) — 读数解析结果（原值三件保真 + 换算建议）
- `AliasHit` (82) — 别名命中行
- `UcumUnit` (94) — UCUM 单位行（factor+offset 仿射换算）
- `UcumMolarBridge` (115) — 摩尔质量桥接行（FR25.3 按编码取值）
- `CodeIndex` (135) — 码表存储端口协议（Domain 自声明）
  - `func overrideHit / resolveAlias / concept / unitSpecificConcept` (136-142)
- `UnitIndex` (145) — 单位存储端口协议
- `CodeResolver` (152) — F25 标准化引擎 BR 纯函数
  - `func routeWeight(_:)` (154) — 路由权重（链序）
  - `func confidence(_:)` (164) — 路由 → 置信度
  - `func resolve(_:locale:index:)` (174) — 术语解析链（override > curated > fold；绝不猜码）
  - `func resolveReading(raw:value:unit:locale:index:units:)` (202) — 名称+数值+单位联合解析
- `UcumRules` (243) — 单位换算规则
  - `func convert(_:from:to:units:conceptId:)` (249) — 族内仿射换算 + 摩尔桥接（除零守卫）
- `StandardizationNoGoScene` (281) — FR25.12 不引码场景负清单（4 case）

## CoreKit/Sources/Domain/CodeSetSeeds.swift
- `CodeSetSeeds` (18) — P0.5 内置码表种子（编译期常量）
  - `static let bundleVersion` (20) — 种子包版本
  - `SeedConcept` (22) — 概念行（LOINC 等）
  - `SeedAlias` (39) — 别名行（locale/route/priority）
  - `SeedUnitSpecific` (54) — 单位特异编码桥
  - `SeedOverride` (63) — 人工覆盖行
  - `SeedUcumUnit` (72) — UCUM 单位行
  - `SeedBridge` (86) — 摩尔桥接行
  - `static let concepts` (99) — 6 条概念（机械表）
  - `static let aliases` (120) — 15 条别名（机械表）
  - `static let unitSpecific` (138) — 4 条（机械表）
  - `static let overrides` (145) — 1 条（机械表）
  - `static let ucumUnits` (150) — 6 条（机械表）
  - `static let bridges` (164) — 6 条（机械表）

## CoreKit/Sources/Domain/CompletenessEvaluator.swift
- `CompletenessLevel` (10) — 四级完整度
- `CompletenessFieldRule` (18) — 单字段规则（key/isRequired/weight）
- `CompletenessAssessment` (31) — 评估结果（等级/得分/缺失/低置信/覆盖率）
- `CompletenessEvaluator` (55) — 完整度评估（§17 单一事实源）
  - `static let contextSatisfiedKeys` (57) — 上下文字段（patient_id）
  - `func rules(for:)` (68) — §17.2 各类卡片规则矩阵（~20 卡类 switch）
  - `func assess(fields:cardKind:)` (275) — 加权评分 + 四级判定
  - `static let prescriptionDatePattern` (327) — 预编译日期正则（本批新增）
  - `func prescriptionFieldDrafts(fields:labels:)` (335) — 处方 OCR 路径键归一

## CoreKit/Sources/Domain/CSVWriter.swift
- `CSVWriter` (4) — RFC 4180 CSV 编码
  - `func escape(_:)` (6) — 引号/逗号/换行转义
  - `func row(_:)` (13) — 行拼装
  - `func document(headers:rows:)` (18) — 表头 + 行（\r\n）
  - `var bom: Data` (25) — UTF-8 BOM（Excel 兼容）
  - `func encode(headers:rows:)` (27) — BOM + 文档
  - `SplitPart` (34) — 分包单元
  - `func split(baseName:headers:rows:maxRows:)` (40) — 分包（maxRows≤0 回落单文件）

## CoreKit/Sources/Domain/DataSource.swift
- `DataSource` (3) — 数据来源枚举（manual/ocr/asr/hisImport/healthKit/wearable/unknown）

## CoreKit/Sources/Domain/DocumentNaming.swift
- `DocumentNaming` (11) — 识别内容 → 标准化命名建议
  - `func suggestTitle(fields:documentType:)` (12) — 「日期 · 机构 · 类型 · 科室」组装
  - `func displayName(forKind:)` (35) — 卡类型 → 中文名
  - `func displayName(forDocType:)` (47) — 文档类型键 → 中文名
  - `func dictionary(_:)` (60) — 字段 → 首个非空值字典

## CoreKit/Sources/Domain/DocumentTypeClassifierFallback.swift
- `DocumentTypeEvidence` (12) — 类型证据（键 + 证据词表）
- `DocumentTypeClassifierFallback` (22) — FR5.5/FR6.2 兜底轨分类器
  - `static let evidenceTable` (24) — 16 类稳定类型键证据词表（机械表）
  - `func classify(lines:)` (82) — 按命中行数计分，主类 + 次候选 + 置信度
  - `static let specializations` (120) — 上位类型 → 亚型覆盖表
  - `static let fieldPatterns` (128) — 角色正则（预编译 9 条）
  - `static let freeTextRoles` (166) — 贪婪捕获需截断的角色
  - `static let narrativeFieldKeys` (177) — 叙事多行并入键集
  - `func mergeNarrativeLines(lines:from:isBoundary:)` (186) — 叙事续行并入纯函数
  - `func guessFields(line:)` (207) — 单行启发式语义字段抽取
  - `func isClinicalType(_:)` (267) — 病历类判定（懒创建触发）
- `extension DocumentTypeClassifierFallback` (273) — 页级抽取
  - `static let drugLabelPrefixes / directionsPrefixes / namedFormTokens / doctorTokens` (277-280) — 行内直配词表（本批常量化）
  - `static let directLabelAliases` (283) — 标签直配 12 键别名表（本批常量化）
  - `static let drugStrengthPattern / amountPattern / amountNumberPattern / narrativeBoundaryPattern` (299-307) — 预编译正则（本批新增）
  - `func pageFields(lines:understood:confidence:)` (311) — 页级字段抽取编排（主循环）
  - `func mergeGuessedFields(line:index:into:)` (387) — 启发式轨并入（本批提取）
  - `func appendIfAbsent(_:value:rawLine:index:confidence:to:)` (410) — 落槽去重单出口（本批提取）
  - `func appendDrugAndLabelFields(text:suffix:line:index:confidence:prescriptionPage:to:)` (419) — 药品/医嘱/印刷标签直配（本批提取）
  - `func appendInvoiceFields(text:line:index:confidence:to:)` (475) — 票据信号（金额/币种/类型）（本批提取）
  - `func absorbNarrativeLines(lines:understood:fields:from:)` (503) — 叙事多行并入（本批提取）
  - `func hasVisitEvidence(in:)` (522) — 就诊证据判定

## CoreKit/Sources/Domain/DocumentTypeKey.swift
- `DocumentTypeKey` (7) — 文档类型稳定键（27 case 分类学）
  - `var attachmentOnly: Bool` (17) — 仅附件五类（不出抽取）
  - `var targetCardKinds: [String]` (23) — 结构化目标卡列表
  - `var encounterKindHint: EncounterKind?` (50) — 就诊场景提示
  - `static let legacyLabelKeys` (62) — 旧 15 标签键 → 稳定键
  - `init?(legacyLabelKey:)` (70) — 旧键/稳定键归一入口

## CoreKit/Sources/Domain/DoseSlot.swift
- `DoseUserAction` (7) — 剂量用户动作（taken/snoozed/skipped/missed/discomfort）
  - `var isResolved: Bool` (14) — snoozed 非终态单一事实源
- `DoseRecord` (18) — 剂量记录投影（调度剂量 + 动作 + 药品定义）
  - `var id: String` (20) — 调度剂量通知 id
  - `var isUnresolved: Bool` (27) — 待处理谓词单一出口
  - `var displayLabel: String` (34) — 药名 规格 · 剂量标签（Int(exactly:) 防 trap）
- `DoseSlot` (60) — 服药时段（锚 + 餐时 + 记录集）
  - `var allTaken / anyPending` (68/71) — 时段状态投影
- `DoseSlotGrouping` (74) — FR9.17 时段聚合
  - `static let tolerance` (75) — ±30min
  - `func mealMinutes(for:)` (83) — 餐时默认时刻（引擎派生单一事实源）
  - `func group(_:calendar:)` (94) — 聚合主函数（餐时锚定 / fixed 传递聚类）
  - `func mealAnchor(for:relation:calendar:)` (129) — 日历构造锚（DST 安全）
  - `func slotId(for:calendar:)` (142) — 单剂量时段 id
  - `func slotIds(_:calendar:)` (152) — 全量映射（合并时段反查）
- `DualTrackInventory` (169) — FR9.8 双轨库存（计划/确认两线）
- `InventoryRules` (189) — 双轨扣减矩阵 BR 规则
  - `func deductPlan / deductConfirmed(_:units:)` (191/198) — 两线扣减
  - `func applyResolution(_:units:action:)` (211) — 按动作两线扣减
  - `func deduction(for:units:)` (225) — 扣减矩阵唯一编码
  - `func transitionDeduction(from:to:units:)` (243) — 补录转场闭式扣减
  - `func refillAlertNeeded(_:dailyPlanUnits:at:)` (252) — 续药告警判定
  - `RefillTier` (258) — 续药三级档（t7/t3/t0 + 阈值）
  - `static let daysThresholdTolerance` (276) — ADR-009 偏早浮点容差
  - `func hitsThreshold(_:tier:)` (279) — 阈值命中（含容差）
  - `func refillTier(_:dailyPlanUnits:at:)` (290) — 最紧急命中档（不读 status）
  - `func refillTiersFired(initialUnits:dailyPlanUnits:from:to:calendar:)` (326) — 零确认逐日推进触达档位
  - `func fefoOrder(_:)` (352) — FEFO 批次排序
  - `func allocateConfirmed(lots:units:)` (363) — FEFO 分配实扣
  - `func isEqualToBook(physical:confirmed:tolerance:)` (389) — 盘点容差判等
  - `func preferredExactMatches(_:name:query:)` (398) — 精确名优先匹配

## CoreKit/Sources/Domain/EmergencyCard.swift
- `EmergencyCardItem` (6) — 紧急卡条目（四类 + 结构化字段）
  - `var contactPhone: String?` (32) — 拨号号码（结构化优先，展示串回退）
- `EmergencyCard` (41) — 紧急卡聚合（四列表）
- `EmergencyCardService` (58) — 聚合服务
  - `func assemble(patientId:allergies:medications:healthProblems:contacts:)` (60) — BR-003 未确认不入卡
  - `func medicalIDGuideNeeded(card:)` (75) — Medical ID 引导判定
- `InventoryMonthlyReport` (85) — 差异月报（纯事实数值）
- `InventoryReportRules` (94) — 月报负清单
  - `static let forbiddenPatterns` (96) — 评分/推断/建议句式 6 条
  - `func violation(in:)` (99) — 命中即返词
  - `func report(periodStart:periodEnd:planned:confirmed:skipped:missed:)` (104) — 组装月报
- `InventoryReconciliation` (114) — 盘点归真值对象
  - `var difference / needsConfirmation` (128/131) — 差异与确认判定
- `DispenseListRules` (139) — FR13.8 配药清单导出
  - `Header` (141) — 六列表头
  - `Row` (145) — 行值对象
  - `func csv(rows:headers:)` (162) — CSV 组装（表头由调用方 L10n 传入）

## CoreKit/Sources/Domain/EncounterAssociation.swift
- `EncounterAssociation` (6) — 卡内归属关联（六态）
  - `var encounterID: UUID?` (17) — 就诊 id 投影
  - `var hubID: (hub: RecordHub, id: UUID)?` (26) — 主卡 (枢纽, id)
- `HubDraft` (37) — 主卡草稿（D 级，字段全确认方可转实体）
  - `var dateKey: String` (46) — 枢纽日期键
  - `var hasDate: Bool` (54) — 草稿带日期判定
  - `func isComplete(calendar:)` (59) — 可转实体判定
- `ParentCardDraftRules` (69) — 主卡草稿派生规则（§0.4 改判）
  - `static let encounterChildren / healthExamChildren / checkupRedirected / dateKeys` (71-77) — 归属表
  - `func hub(for:documentTypeKey:)` (80) — 子卡应挂枢纽
  - `func deriveHub(from:documentTypeKey:)` (87) — 子卡 → 主卡草稿（只搬原文）
  - `func encounterDraft(from:patientId:calendar:)` (123) — 草稿 → 就诊
  - `func healthExamDraft(from:patientId:calendar:)` (135) — 草稿 → 体检表头
  - `func association(for:documentTypeKey:patientId:candidates:calendar:)` (145) — 关联区默认裁决
- `EncounterResolver` (160) — 就诊归属解析器
  - `Candidate` (161) — 候选就诊
  - `static let evidenceKeys` (173) — 证据字段键
  - `func suggest(date:hospital:doctor:patientId:candidates:calendar:)` (177) — ±3 日同医院建议
  - `func evidenceKey(for:)` (194) — 卡证据签名
  - `func context(for:calendar:)` (199) — 卡上下文（日期/机构/医生）
  - `func normalize(_:) / hospitalScore(_:_:)` (210/214) — 归一化与相似度打分
## CoreKit/Sources/Domain/Encounter.swift
- `EncounterDraft` (5) — F4 就诊草稿（FR4.1 字段全集）
- `EncounterKind` (44) — 就诊类型枚举（7 case，L10n 键随 rawValue）

## CoreKit/Sources/Domain/EngineCapabilityProfile.swift
- `EngineCapabilityProfile` (5) — 统一能力画像（ADR-027）
  - `Tier` (6) — complete / bestEffort
  - `func dialectMatrix()` (39) — 六语种能力矩阵（T1 三语 + T2 三方言）
  - `var sixLanguages` (69) — 六语种清单（矩阵派生单一事实源）
  - `func inputLanguageOptions(choice:)` (81) — 输入语言选项 = 六语种 + 随包模型额外语种

## CoreKit/Sources/Domain/Entities2.swift
- `DocumentFile` (3) — 文档文件轻量实体
- `MedicationPlan` (12) — 用药计划轻量实体
  - `Status` (13) — active/paused/ended
- `MockFactory` (24) — Preview/单测统一数据工厂（禁连生产库）
  - `func patient / document / plan` (25/28/31) — 三工厂方法

## CoreKit/Sources/Domain/Entities.swift
- `PatientProfile` (3) — 成员档案实体（含软删时间戳）
- `FieldConfirmation` (36) — 字段确认状态机
  - `func confirm()` (38) — 状态迁移
  - `var isUsableInTimeline` (39) — BR-003 最小验证

## CoreKit/Sources/Domain/EntityCardProjection+ClinicalEpisodes.swift
- `extension EntityCardProjection` (6) — v26 clinical-episodes 持久化意图
  - `LabReportIntent` (11) — 检验表头意图
  - `LabResultIntent` (39) — 定性行意图
  - `LabProjection` (46) — 检验分流结果（samples/qualitative/header/remaining）
  - `HospitalizationIntent` (60) — 住院意图（episodeDate + encounterKind）
  - `DiagnosisIntent` (73) — 诊断行意图
  - `ExamReportIntent` (80) — 检查报告意图
  - `func diagnosisType(forDocumentType:)` (89) — 文档键 → 诊断类型默认
  - `func labHeaderIntent(from:calendar:)` (101) — 共享面 → 表头意图
  - `func labProjection(from:calendar:)` (116) — 检验分流主函数（严格十进制 + 单位才入 samples）
  - `func strictDecimal(_:)` (157) — 严格十进制校验
  - `func leadingComparator(_:)` (164) — 首部比较符抄录
  - `func hospitalizationIntent(from:calendar:)` (171) — 住院卡 → 意图
  - `func diagnosisIntents(from:calendar:)` (197) — 诊断卡 → 逐行意图
  - `func examReportIntent(from:calendar:)` (217) — 检查卡 → 意图

## CoreKit/Sources/Domain/EntityCardProjection+HealthExam.swift
- `extension EntityCardProjection` (10) — v27 体检/结论/手术/治疗意图
  - `HealthExamIntent` (14) — 体检首页意图（exam + generalSamples）
  - `ClinicalConclusionIntent` (22) — 结论行意图
  - `SurgeryIntent` (29) — 手术意图
  - `TreatmentRecordIntent` (36) — 治疗记录意图
  - `static let generalProjection` (45) — 一般检查投影白名单（4 项：键/指标/单位）
  - `func healthExamIntent(from:calendar:)` (55) — 体检卡 → 意图 + 一般检查投影
  - `func clinicalConclusionIntents(from:calendar:)` (84) — 结论卡 → 逐行意图
  - `func surgeryIntent(from:calendar:)` (103) — 手术卡 → 意图
  - `func treatmentRecordIntent(from:calendar:)` (124) — 治疗卡 → 意图

## CoreKit/Sources/Domain/EntityCardProjection.swift
- `EntityCardProjection` (6) — 已确认实体卡 → 持久化意图（纯 Domain 零 IO）
  - `HospitalProjection` (7) — 医院样本投影
  - `PrescriptionLineIntent` (17) — 处方行意图
  - `PrescriptionIntent` (24) — 处方意图（表头 + 行）
  - `ClaimLineIntent` (50) — 费用明细行意图
  - `ClaimIntent` (77) — 票据意图
  - `static let prescriptionTypes` (101) — 处方类型 CHECK 枚举
  - `static let numericKeys / integerKeys / optionalDateKeys` (105/112/116) — 值级键型三表（机械表）
  - `static let hospitalizationKinds` (128) — 住院派生类型许可集
  - `static let datePattern` (132) — 预编译日期正则（本批新增）
  - `func parseDate(_:calendar:)` (136) — OCR 日期解析（月/日域校验 + 回读一致性）
  - `func sharedDate(_:in:calendar:)` (156) — 共享面日期取值单出口（本批新增）
  - `func hospitalSamples(from:calendar:)` (162) — 检验卡 → 趋势点读面
  - `func encounterDraft(from:patientId:calendar:)` (170) — 就诊卡 → 就诊草稿
  - `func prescriptionIntent(from:)` (188) — 处方卡 → 表头 + 逐行意图
  - `func claimIntent(from:calendar:)` (224) — 票据卡 → 表头 + 行
  - `func candidateFields(from:labelFor:)` (258) — 卡 → 确认卡字段列表
  - `func invalidFields(in:row:calendar:)` (271) — 值级校验编排（required/放行/日期/键型/卡类）
  - `func applyTypedKeyChecks(card:shared:values:calendar:into:)` (294) — 键型三表校验（本批提取）
  - `func applyCardKindChecks(card:shared:values:calendar:into:)` (311) — 卡类专属规则（本批提取）
  - `func isDiscarded(_:in:)` (356) — 整行被拒判定
  - `func confirmedValues(_:)` (361) — 已确认值字典
  - `func confirmedUnit(_:key:)` (364) — 已确认字段单位
  - `func rawText(_:)` (371) — 行原文拼接
  - `func dictionary(_:)` (380) — 首个已确认非空值字典

## CoreKit/Sources/Domain/ExtractedCard.swift
- `ExtractionTrack` (8) — 产出轨（T1/T2/T3）
- `DegradedReason` (13) — 降级原因 10 case
- `TextAnchor` (18) — 原文锚点（页/行/块/行身份 + UTF-16 范围）
- `GroundedValue` (28) — 已锚定值（value/unit/normalized/锚/续行/置信）
- `ExtractionProvenance` (37) — 产出溯源（轨/版本/模型/耗时）
- `ExtractionDiagnostics` (44) — 抽取诊断（主轨/降级/丢弃/超时/重试/混轨）
- `TitleSource` (63) — 标题来源（detected/userEdited）
- `ExtractedCard` (66) — 一页一卡类抽取产物
- `RegionKind` (84) — 区域类型（header/table/paragraph）
- `ExtractionCell` (86) — 单元格
- `ExtractionRow` (93) — 行（text/lineIndices 计算属性）
- `ExtractionRegion` (100) — 区域（表头 + 行）
- `ExtractionRequest` (111) — 单页抽取请求（预算/授权门）
- `RegionExtraction` (122) — 单区域原始结果
  - `var isEmpty / valueCount` (125-126)
- `extension PageLayout` (129) — 版面 → 区域切分
  - `func extractionRegions(pageIndex:)` (132) — 表格/表头/段落几何聚行

## CoreKit/Sources/Domain/ExtractionGrounding.swift
- `ExtractionGrounding` (7) — 轨道无关的第二道防线（定位原文）
  - `func validate(_:spec:lines:)` (10) — 整卡校验（行锚未锚定整行不出）
  - `func validate(_:key:type:allowed:lines:extraLabels:)` (40) — 单值校验（分段/定位/复用 OCRGrounding）
  - `func locate(_:in:)` (75) — NFKC+空白折叠后字符映射回原文范围

## CoreKit/Sources/Domain/ExtractionPatterns.swift
- `ExtractionPatterns` (5) — 抽取层共享词表与文法单点
  - `static let deptWords` (13) — 科室词表（37 条并集）
  - `static let deptWordSet / deptWordsByLength` (22/26) — 集合 / 最长优先预排序
  - `static let labelBoundaries` (38) — 标签值域右界词表
  - `func isLabelPosition(_:at:labelEnd:)` (58) — 标签位判定（逗号族须紧跟冒号）
  - `func nextLabelBoundary(in:)` (83) — 值内下一个标签位起点
  - `func truncatingAtLabelBoundary(_:)` (101) — 贪婪捕获截断
  - `func valueSpan(afterLabel:in:)` (113) — 该标签自己的值段
  - `func institutionName(in:)` (143) — 「名称医院」后缀文法机构名
  - `func dateToken(in:)` (153) — 有界日期记号
  - `func referenceBounds(_:)` (164) — 参考范围「低-高」拆解
  - `static let institutionNamePattern / dateTokenPattern / referenceBoundsPattern` (175/177/179) — 预编译正则（本批新增）

## CoreKit/Sources/Domain/ExtractionPromptBuilder.swift
- `ExtractionPromptBuilder` (25) — 抽取提示词单一出口（T1+T2 同源）
  - `func systemPrompt(for:)` (28) — 系统指令（安全边界 + 逐字段目录）
  - `func numbered(lines:)` (54) — 零基编号行
  - `func catalogue(_:)` (61) — 逐字段目录
  - `func line(for:)` (65) — 单字段行（键/类型/必填/别名/提示）
  - `func describe(_:)` (80) — 类型描述（只述格式）

## CoreKit/Sources/Domain/ExtractionSpec.swift
- `FieldType` (9) — 字段类型（6 形态）
  - `func acceptsFormat(_:)` (16) — 格式校验（日期/有限数/整数/枚举 canonical）
- `GroundingRule` (33) — 定位规则 4 case
- `RuleFallback` (36) — 无标签启发式 3 case
- `FieldSpec` (38) — 单字段抽取规格
  - `Scope` (39) — shared/row
- `Exemplar` (49) — 金样（行 + JSON）
- `ExtractionSpec` (54) — 单卡抽取规格
  - `var requiredKeys / fields` (66-67) — 派生
  - `func field(for:)` (68) — 按键查
  - `var outputTokenBudget: Int` (71) — 输出预算（design §6.3 公式）
  - `func narrowed()` (80) — 缩范围重试（去可选字段、样本 ≤1）
- `ExtractionSpecRegistry` (90) — 卡类 → spec 单一事实源
  - `func f(_:type:_:req:aliases:hint:fallback:)` (91) — 字段工厂（grounding 按类型派生）
  - `func labels(_:extra:)` (105) — 标签别名并集去重
  - `static let hospitalAliases / deptAliases / doctorAliases / deptWords / hospitalFallback / deptFallback / negativeGuards` (111-119) — 共享词表资产
  - `func hospital / department / doctor` (123/126/129) — 共享字段助手
  - 13 个 spec 常量 (135-364) — prescription/metric_sample/encounter/claim/medication/immunization/hospitalization/diagnosis/exam_report/health_exam/clinical_conclusion/surgery/treatment_record（机械表）
  - `static let specs` (368) — 目录顺序 = CardKindRegistry 顺序
  - `func spec(for:)` (373) — 按 kind 查
  - `func candidates(documentTypeKeys:)` (376) — 文档键 → 候选 spec（保序去重）

## CoreKit/Sources/Domain/FieldDraftAdapter.swift
- `FieldDraftAdapter` (6) — GroundedValue → FieldDraft（三轨产物统一入口）
  - `func source(_:)` (8) — 轨 → UnderstandingSource
  - `func draft(key:_:lines:pageConfidence:track:)` (16) — 单草稿（恒 D 级、置信 min(页,0.6)）
  - `func drafts(_:spec:lines:pageConfidence:)` (24) — 整卡 → 共享/逐行草稿（spec 字段序 + 键名尾随）

## CoreKit/Sources/Domain/FieldDraft.swift
- `FieldDraft` (8) — 跨切面识别字段草稿模型（BR-003 待确认态）
  - `var key / value / unit` (9/14/17) — didSet 触发审查失效
  - `let originalValue / originalUnit` (12-13) — 机器原值
  - `var confidence / rawText / suggestedLabel / source / sourceLineIndex` (20-25) — 元数据
  - `var codeResolution` (26) — F25 惰性建议
  - `var grade / revisionHistory` (29-30) — 级别与修订史
  - `var candidates` (41) — 同键多候选
  - `var hasUnresolvedCandidates` (52) — 待定歧义
  - `Candidate` (54) — 候选（value/unit/置信/原文行）
  - `func chooseCandidate(_:)` (74) — 选定候选（写值 + 消歧标记）
  - `CodeApproval` (80) — 编码批准
  - `var id: String` (86) — key
  - `var isConfirmed: Bool` (102) — C 级判定（reviewed 快照一致）
  - `func confirm()` (107) — 显式确认
  - `func approveCode(unit:)` (114) — 编码批准守卫
  - `func reject / reenable / clearCodeResolution` (125-127) — 状态迁移
  - `func revise(to:by:at:)` (129) — 机器路径改值（改动即失效）
  - `func fillByUser(_:by:at:)` (146) — 手填（原值空 → 写即 C；业主 2026-09-17 裁定）
  - `func invalidateReview()` (155) — 审查失效复位
  - `init(from:)` (167) — 解码（candidates/candidateChosen 向后兼容）
  - `func encode(to:)` (192) — 编码（非空/已消歧才写出新键）

## CoreKit/Sources/Domain/FieldGroupRules.swift
- `FieldGroupRules` (7) — FR17.18 信息卡分组路由
  - `func category(ofKey:)` (8) — 字段键 → 类别键（rx/lab/visit/generic）
  - `static let categoryOrder` (17) — 卡序固定顺序

## CoreKit/Sources/Domain/GateUnlock.swift
- `GateUnlocking` (7) — 门禁解锁端口协议（FR1.1 系统设备所有者认证）
  - `var isAvailable: Bool` (9) — 预检可用性
  - `func authenticate(reason:)` (11) — 触发系统认证浮层

## CoreKit/Sources/Domain/GBNFGrammarGenerator.swift
- `GBNFGrammarGenerator` (9) — 子项目 F：spec → llama.cpp GBNF 文法
  - `func generate(for:)` (14) — 生成完整文法（root/value/ws/str/number/date 规则）
  - `func valueRuleName(for:)` (56) — 值规则命名
  - `func valueRuleDefinition(for:)` (60) — 按 FieldType 生成值规则
  - `func rowObject(spec:)` (76) — 行对象文法
  - `func generateAll()` (86) — 全注册 spec 批量生成

## CoreKit/Sources/Domain/Geometry.swift
- `Size` (9) — 尺寸
- `Point` (19) — 点
- `Rect` (29) — 矩形（两种构造器）

## CoreKit/Sources/Domain/HealthCardComposer.swift
- `HealthCardComposer` (7) — 健康读数后处理填卡
  - `func compose(row:kind:guideline:patientId:)` (12) — 附 B 级参考区间 + 引用式级别（BR-006 非诊断）

## CoreKit/Sources/Domain/HealthCharacteristicImport.swift
- `HealthCharacteristics` (13) — 健康特征型数据（血型/出生日期/性别）
  - `var isEmpty: Bool` (25) — 三项全空判定
- `HealthCharacteristicImport` (29) — 特征型导入候选裁决（纯规则）
  - `Field` (31) — bloodType/birthDate/gender
  - `Candidate` (35) — 候选（proposed/existing + 可采判定）
  - `func candidates(characteristics:profile:)` (52) — 候选清单（出生日期按年精度降级）
  - `func hasAdoptable(_:)` (71) — 有可采候选判定
  - `func normalized(_:) / matchesYearOnlyPrecision(_:) / year(of:)` (75/82/88) — 私有助手

## CoreKit/Sources/Domain/Cards/AppointmentRecord.swift
- `AppointmentRecord` (10) — P9 信封储备：预约信息卡（InformationCard 族）
- `AppointmentType` (35) — 预约类型（visit/healthExam/revisit）
- `AppointmentStatus` (41) — 预约状态 7 case

## CoreKit/Sources/Domain/Cards/ClinicalReport.swift
- `ClinicalReport` (10) — P9 信封储备：临床报告信息卡
- `ClinicalReportSource` (50) — 报告来源 3 case
- `ClinicalReportType` (56) — 报告类型 4 case
- `ClinicalReportItem` (63) — 报告条目
- `ClinicalReportConclusion` (88) — 报告结论

## CoreKit/Sources/Domain/Cards/EncounterRecord.swift
- `EncounterRecord` (10) — P9 信封储备：就诊记录信息卡

## CoreKit/Sources/Domain/Cards/HealthMetricCard.swift
- `HealthMetricCard` (18) — Apple 健康信息卡（读侧装配，不建第二存储）
  - `func make(from:kind:patientId:)` (83) — DeviceMetricRow → 卡

## CoreKit/Sources/Domain/Cards/MedicationGuide.swift
- `MedicationGuide` (10) — P9 信封储备：药品说明书信息卡

## CoreKit/Sources/Domain/Cards/MedicationScheduleCard.swift
- `MedicationScheduleCard` (10) — P9 信封储备：用药日程信息卡
- `ScheduleStatus` (34) — 日程状态 4 case
- `MedicationPlanDrug` (41) — 计划药品行

## CoreKit/Sources/Domain/Cards/PatientRecord.swift
- `PatientRecord` (10) — P9 信封储备：患者档案信息卡

## CoreKit/Sources/Domain/Cards/PrescriptionRecord.swift
- `PrescriptionRecord` (10) — P9 信封储备：处方信息卡
- `PrescriptionItem` (33) — 处方条目

## CoreKit/Sources/Domain/Cards/VisitType.swift
- `VisitType` (10) — 就诊类型（初诊/复诊/急诊）

## CoreKit/Sources/Domain/HealthExam.swift
- `HealthExam` (16) — v27 体检枢纽表 `health_exam` 的 DDL 镜像值类型（一般检查列为打印原文，BR-006/007）
  - `var id/patientId/documentFileId/orgName/…/updatedAt` (17-40) — DDL 同名同序字段（21 个，含 source/confirmed/createdAt/updatedAt）
  - `init(id:patientId:…)` (42) — 全字段 memberwise 构造
- `ClinicalConclusion` (63) — 统一结论表镜像（检验/检查/体检总检/异常发现/建议），severityText 只存打印文本（BR-004/012）
  - `static let conclusionTypes: [String]` (65) — conclusion_type CHECK 枚举七值
  - `var id/patientId/labReportId/examReportId/healthExamId/conclusionType/content/severityText/ordinal/sourcePage/sourceRowId/createdAt` (67-79) — DDL 镜像字段
  - `var hasExactlyOneParent: Bool` (91) — DDL CHECK「三外键恰一非空」的值侧镜像
  - `static func conclusionType(forContent:)` (98) — 结论行类型的 D 级默认派生（词表匹配，非医学解读）
- `Surgery` (108) — 手术记录镜像（编码/级别/植入物/出血量一律原文不拆行，BR-006/007）
  - `var id/patientId/…/updatedAt` (109-138) — DDL 镜像字段（26 个）
- `TreatmentRecord` (165) — 门诊治疗/输液/注射/理疗镜像；drugsText 原文不拆行、不进 prescription_line
  - `static let treatmentTypes: [String]` (167) — treatment_type CHECK 枚举五值
  - `var id/patientId/…/updatedAt` (169-190) — DDL 镜像字段（21 个）
- `ReportType` (208) — `v_clinical_report.report_type` 字面量（lab/exam/health_exam）
- `ReportSource` (213) — lab_report/exam_report.report_source CHECK 枚举（门诊/急诊/住院/体检）
- `ClinicalReportSummary` (219) — `v_clinical_report` 只读视图读模型（不入备份）
- `AppointmentPurpose` (243) — appointment.purpose CHECK 枚举（visit/followUp/exam/healthExam）
- `ReminderSource` (248) — reminder.source_table/source_id 多态引用（白名单 + 判定，无 FK）
  - `static let allowedTables: Set<String>` (250) — 允许回指的来源表白名单（拼 SQL 前校验）
  - `var table/id` (252-253) — 来源表名与实体 id
  - `init?(validating:table:id:)` (258) — 白名单校验构造，未登记表 → nil
  - `var isAllowed: Bool` (263) — 表名是否在白名单
  - `var hub: RecordHub?` (266) — 来源为主卡时的枢纽（预约不是枢纽 → nil）

## CoreKit/Sources/Domain/HealthFetchScope.swift
- `HealthFetchLane` (5) — 首次回填两道（recent = end ≥ cutoff / history = end < cutoff）
- `HealthFetchScope` (10) — 一道回填范围（lane + 固定 cutoff，不随 now 漂移）
  - `static let recentDays` (12) — 近一年 = 365 日历日
  - `var lane/cutoff` (13-14) — 道别与固定边界
  - `static func cutoff(connectedAt:calendar:)` (19) — 绑定时刻 − 365 日历日（DayArithmetic）
  - `static func scopes(connectedAt:calendar:)` (24) — 两道互补分割，recent 在前
  - `func matches(_ sample:)` (36) — 样本 end 相对 cutoff 的道归属判定（与 HealthKit 谓词同边界）

## CoreKit/Sources/Domain/HealthImportPresentation.swift
- `HealthTypeSummary` (9) — 单类健康数据的表现层读模型（kind + 行数 + 最新时刻）
  - `var kind/rowCount/latestAt` (10-12) — 摘要字段；`id` = kind
- `HealthImportDashboard` (17) — Apple 健康导入仪表盘读模型（绑定态 + 类型摘要 + 最近报告）

## CoreKit/Sources/Domain/HealthImport.swift
- `HealthDataKind` (4) — HealthKit 数据类别枚举（6 类）
  - `var primaryMetric: MetricType` (39) — 类别 → 趋势指标键（extension）
  - `var isAggregated: Bool` (50) — 聚合类（心率/步数/睡眠）每窗一行；离散类每读数一行
  - `static func forMetricKey(_:)` (55) — metric_key 反查数据类别（设备行路由数据列表页）
- `MetricAggregation` (8) — 聚合形态（sample/hourlyAverage/dailySum/sleepDuration）
- `HealthSampleReference` (12) — HealthKit 样本引用（幂等身份五元组）
  - `var isValid: Bool` (23) — sourceID 非空 ∧ 日期区间合法（复用 HealthImportWindow.validDates）
- `HealthChangeBatch` (28) — 同步轮变更批次（added/deleted/anchor/hasMore）
- `HealthImportWindow` (60) — 一个导入窗口（kind + 起止）；聚合行以窗口为身份
  - `var prefix/identityPrefix` (65-68) — 行身份前缀（聚合=含窗起点；离散=仅 kind）
  - `var isValid: Bool` (73) — 日期合法且 end > start
  - `fileprivate static func validDates(start:end:)` (75) — 日期区间合法性（有限/Int64 域/次序）
  - `func overlaps(_ sample:)` (83) — HealthKit 默认样本谓词（左闭右开镜像）
  - `static func sampleIdentity(kind:sampleID:ordinal:)` (88) — 离散读数稳定身份
  - `static func sampleID(fromIdentity:kind:)` (94) — sampleIdentity 反解；聚合/异格式 → nil
  - `func contains(sourceRef:measuredAt:)` (110) — 投影行是否属于本窗（聚合按前缀+窗起点，离散按身份+半开区间）
  - `static func covering(_ sample:calendar:)` (118) — 一个样本跨越的窗口序列（心率小时窗/睡眠 noon 锚/其余日窗）
- `HealthWindowSnapshot` (151) — 单窗物化快照（样本 + 行 + 读数 + 剔除/稀疏计数）
- `SyncReport` (170) — F16 同步轮报告（进度字段全 Optional 兼容旧 JSON）
  - `var elevated/noRangeCount/persistedRows/preservedRows/deferredWindows/receivedChanges/rejectedSamples/failedTypes/hasMore/notificationFailures/lastSyncAt/bindingId/patientId/sparseWindows/remainingWindows/backfillLane` (171-193) — 报告字段
  - `init(lastSyncAt:…)` (197) — 跨模块构造出口（合成 memberwise init 为 internal）

## CoreKit/Sources/Domain/HealthImportVisibility.swift
- `HealthImportPageState` (7) — Apple 健康页面可见性六态（优先级固定：关闭 > 不可用 > 缺档案 > 未连接 > 空 > 可见）
- `HealthImportVisibility` (22) — 可见性判定纯函数
  - `static func state(enabled:available:ownerPresent:connected:importedRows:)` (23) — 四可观察事实 → 六态
  - `static func showsImportedData(_:)` (33) — 展示区/详情页存在条件（visible ∪ connectedEmpty）
  - `static func allowsTrendLink(_:patientId:)` (38) — 趋势链接 = 有数据 ∧ 身份已知（BR-001 不回落 currentPatientId）

## CoreKit/Sources/Domain/HealthProblemDerivation.swift
- `HealthProblemDerivation` (9) — FR11.4 懒创建候选健康问题名派生（诊断字段优先截断 40 字，无诊断回落「类型+日期」）
  - `private static let dayFormatter: DateFormatter` (12) — yyyy-MM-dd 静态缓存
  - `static func candidateName(fields:docTypeLabel:now:)` (18) — 候选名派生（D 级建议，用户确认才落库）
- `HealthProblemCandidate` (30) — 诊断行 → D 级健康问题候选（名称/编码/日期均为原文，不猜码不猜日期）
  - `static func from(diagnoses:)` (45) — 每行一候选；同名去空白只留首见、空名跳过

## CoreKit/Sources/Domain/HealthWriteBack.swift
- `HealthSampleDraft` (13) — 写回 HealthKit 的样本载荷（metric/value/secondaryValue/unit/measuredAt）
- `HealthWriteBack` (32) — 写回资格规则（BR 纯函数——资格判定不进视图）
  - `static func canonicalUnit(for metric:)` (36) — 可写指标 → HealthKit 规范单位；不可写 → nil
  - `static func normalizedUnit(_:)` (49) — 单位归一（trim + 全角 ℃ 归半角，只服务逐字匹配不换算）
  - `static func isWritable(metric:unit:value:)` (55) — 可写 = 有规范单位 ∧ 单位逐字相符 ∧ 数值有限
  - `static func writeScale(for metric:)` (72) — 写回数值尺度（血氧 ×0.01 分数制；其余 1:1——有定义的映射不是猜测）

## CoreKit/Sources/Domain/HourWindowAggregator.swift
- `HourWindowSample` (10) — 小时窗输入样本（值 + 时刻）
- `HourWindow` (19) — 小时统计行（窗起点 + 均值/min/max/样本数）
- `HourWindowAggregate` (37) — 聚合结果（统计行 + 非有限剔除计数 + 稀疏窗计数，任何一类不静默）
- `HourWindowAggregator` (50) — FR16.1 心率小时窗口聚合纯函数
  - `static let minSamples = 3` (52) — 最小有效样本数（<3 不落行）
  - `static func aggregate(_ samples:calendar:)` (54) — 本地日历整点分桶聚合；非有限剔除计数、稀疏计数上送

## CoreKit/Sources/Domain/ImageCompress.swift
- `ThumbnailSpec` (6) — 缩略图规格（最大边长/模糊半径/质量）
- `SensitiveMediaPolicy` (20) — 敏感媒体策略（敏感标记/原图二次认证/缩略图强制模糊，BR-007/008）
- `CompressError` (38) — 压缩错误（encodeFailed/decodeFailed/authRequiredForOriginal）
- `ImageCompressing` (45) — 压缩/缩略图跨平台协议（generateThumbnail + authorizeOriginalAccess）

## CoreKit/Sources/Domain/ImageInputRules.swift
- `ImageInputRules.Recognition` (10) — 图片识别结果（文本行/置信度/版面；兼容出口 lines）
  - `var text: String` (21) — 行拼接；`isEmpty` (22) — trim 后判空
- `ImageInputRules` (8) — FR12.11 AI 图片/文档输入的 Domain 判据（识别结果恒 D 级，BR-003）
  - `static func draftFields(from:)` (27) — 识别文本 → 单条 D 级 CandidateField（key=image_text）
  - `static let noTextKey` (46) — 无文字降级提示的类型化键（L10n 渲染）
  - `static func requiresConfirmation(_:)` (51) — 有文字必须先经确认卡
  - `static let supportedImageExtensions` (58) — 图片扩展名白名单（全仓唯一出处）
  - `static func supports(pathExtension:)` (65) — 扩展名支持判定单一出口
  - `static func sniffMimeType(of:fallback:)` (72) — 按字节头嗅探真实 MIME（PNG/JPEG/GIF/WebP/HEIF 族）
  - `static func fileExtension(for mimeType:)` (101) — MIME → 落盘扩展名（BR-002 原件扩展名与内容一致）

## CoreKit/Sources/Domain/InformationCard.swift
- `InformationCard` (3) — 信息卡通用协议（cardType/schemaVersion/cardId/patientId/source/confidence/fieldConfidence/rawText/时间戳）
  - `extension` (16) — schemaVersion 默认 1；`id` = cardId

## CoreKit/Sources/Domain/LabItemRules.swift
- `LabItemKind` (6) — 检测/检查项分类（enzyme/exam/routine，业主 2026-09-17 定：象征图标分类源）
- `LabItemRules` (15) — 检验项名称分类纯规则（酶类 > 检查项 > 常规）
  - `static let examKeywords` (19) — 检查项关键词表（内镜族逐类列名，不用裸「镜」）
  - `static func classify(label:)` (26) — 名称分类

## CoreKit/Sources/Domain/LegacyV1.swift
- `LegacyAsset` (3) — 旧版资产（id/type/textBlocks）
- `LegacyBlock` (8) — 旧版文本块（text/confidence）
- `LegacyRecord` (12) — 旧版记录（id/title/recordType/assets）
- `GoldenClass` (21) — 金样类别（prescription/lab/ocrBlock/generic）
- `GoldenRules` (22) — 金样分类规则
  - `static func confidenceTier(_:)` (25) — 置信三档委托 ConfidenceTier.tier 单一事实源
  - `static func classify(recordType:assets:)` (28) — §5.2 路由序：doc_type 优先，类型缺失/other 时按含非空 OCR 块兜底 ocrBlock

## CoreKit/Sources/Domain/LoadGate.swift
- `LoadGate` (4) — R0-1 启动期一次性加载闸门（actor：首个调用者执行 load，并发挂起，幂等）
  - `State` (5) — idle/loading/ready
  - `func enter(_ load:)` (17) — 进入闸门；失败回到 idle 并 rethrow 给等待者（失败绝不置 ready）
  - `var currentState: State` (40) — 当前状态

## CoreKit/Sources/Domain/MediaUnlockPolicy.swift
- `MediaUnlockPolicy` (14) — 敏感媒体解锁/重锁策略（BR-007/008 · FR8.4，Domain 纯函数）
  - `static let idleTTL/showcaseTTL/activityCoalescingWindow` (16-26) — 30s 无操作重锁 / 医生展示 300s / 活跃信号 1s 合并窗
  - `static func shouldRelock(lastInteraction:now:)` (29) — 按最后一次交互计时判定重锁
  - `static func shouldRecordActivity(lastInteraction:now:)` (34) — 合并窗口内的重复活跃信号丢弃
  - `static func shouldRelockOnBackground()` (41) — 退后台立即重锁（敏感内容不跨生命周期存活）

## CoreKit/Sources/Domain/MedicalNumberFormat.swift
- `MedicalNumberFormat` (11) — 医学数值显示形态单一出口（可见文本与无障碍标签同源，防「3.7000000000000002」念出）
  - `static func oneDecimal(_:)` (13) — 保留 1 位小数（趋势/参考带口径）
  - `static func quantity(_:)` (23) — `%g` 形态（整数不带小数点；库存件数口径，量级不触发 %g 边界）

## CoreKit/Sources/Domain/MedicationHelpCard.swift
- `MedicationHelpCardRules.Input` (12) — 求助卡单批次输入（含 includeStoragePhoto 显式勾选）
- `MedicationHelpCardRules.HelpCardLabels` (36) — 卡文案标签注入（App 层 L10n；zhFallback 仅诊断/测试）
- `MedicationHelpCardRules` (10) — FR9.13a 药品求助卡规则（最小必要原则：药名/规格/余量/位置文字/效期，照片须勾选）
  - `static func cardText(_ items:labels:)` (58) — 组装单页文本；空选择 → nil；位置照片不入文本
  - `static func shouldAttachPhoto(_:)` (78) — 隐私裁决：照片仅显式勾选纳入
  - `static let forbiddenDiagnosisMarkers` (84) — 诊断类内容类型化排除（结构上无法混入诊断）
- `MessageStatus` (92) — FR24.2 发送状态（sent/ackPending/acked/timeout；本地不存消息原文）
- `SentMessage` (96) — 已发送消息记录（kind/recipient/status/sentAt）
- `MessageStatusRules` (109) — 状态迁移白名单（回退与旁路跳变一律拒绝）
  - `static func canTransition(from:to:)` (112) — 合法迁移判定
## CoreKit/Sources/Domain/MedicationSchedule.swift
- `MedicationSchedule` (6) — FR9.4/§5.4 schedule_json 统一编码（六类调度 → 计划期内 ScheduledDose 生成）
  - `case fixed/interval/meal/asNeeded/cycle/taper` (7-12) — 六类调度形态
  - `TaperStage` (14) — 减量阶段（phase/fromDay/toDay/doseUnits/times）
- `PlanStatus` (28) — 计划生命周期状态（active/paused/ended，ADR-020 闸门）
- `ScheduledDose` (32) — 计划内单剂（dueAt/doseUnits/mealRelation/notifyId 逻辑身份）
- `ScheduleGate` (47) — 计划状态闸门（BR-004 前置：仅 active 产剂量）
  - `static func dosesAllowed(_:)` (48) — 仅 active 放行
- `DoseScheduleEngine` (52) — 调度引擎纯函数（注入 calendar/now，Linux 可单测）
  - `static func doses(schedule:planId:startDate:fromDay:toDay:calendar:unitsPerDose:)` (57) — [fromDay,toDay] 闭区间全剂量生成 + 跳过计数；fromDay>toDay 返回空不 trap；interval 非法参数计 skip 不进死循环
  - `static func mealDefaultTime(_:)` (137) — 餐时关系 → 默认时刻（FR9.17 聚合容差锚点）
  - `MealAnchorRules.parse(_:)` (157) — 中文餐锚词表 → 引擎 token（单一事实源；未知词丢弃）
  - `DoseInputParser.parse(_:)` (190) — 单剂剂量解析单一出口（单位剥离/「半」/分数/中文数字；不可解析响亮拒绝）
  - `static func isValidTime(_:)` (223) — "HH:mm" 合法性单一事实源（委托 hourMinute）
  - `static func date(day:time:startDate:calendar:)` (228) — 日内时刻解析为具体 Date
  - `private static func hourMinute(_:)` (237) — "HH:mm" 解析（isValidTime 与 date 共用）

## CoreKit/Sources/Domain/MemberProfileCompleteness.swift
- `MemberProfileCompleteness` (7) — 档案完善进度规则（首页进度卡；Domain 纯函数可单测）
  - `static let voiceInterviewKeys` (10) — 语音访谈四段完成步骤键
  - `static func progress(profile:interviewCompleted:total:)` (15) — 血型/证件/医保/生日 4 字段（trim 后判空）+ 访谈四段计数；档案 nil/已删 → nil

## CoreKit/Sources/Domain/MemberRelation.swift
- `MemberRelation` (11) — FR3.1 成员关系（rawValue 与落库值逐字一致，不引入迁移）
  - `case selfMember/partner/child/parent/grandparent/father/mother/son/daughter/other` (14-24) — 关系词表（含遗留细粒度值）
  - `static let creatable` (27) — 新建成员可选集（粗粒度，保序）
  - `init(tolerant raw:)` (31) — 容错解析：未知归 .other；丈夫/妻子归配偶
  - `var coarse: MemberRelation` (43) — 粗粒度归并（父/母→父母，子/女→子女）
  - `var isSelf: Bool` (52) — 本人哨兵（身份判定本身走 selfPatientId）

## CoreKit/Sources/Domain/MetricSampleProjection.swift
- `HospitalSample` (8) — 确认后检验项目 → metric_sample 医院来源行（A 级参考范围随行、原始名保真、编码确认后回填）
  - `var metricKey/rawLabel/value/unit/measuredAt/refLow/refHigh/refSourceLabel/codeConceptId/abnormalFlag/healthExamId` (9-22) — 投影字段（abnormalFlag 打印原文不解释 BR-004/012）
  - `static func sourceRef(documentId:pageIndex:)` (33) — 文档页回链 `doc:<uuid>#p<index>`

## CoreKit/Sources/Domain/NotificationItemKey.swift
- `NotificationItemKey` (6) — FR14.8/FR2.1⑦ notification_state.item_key 唯一编码（首页与通知中心共用）
  - `static func key(kind:sourceId:)` (7) — kind → 前缀映射 + 源 id 拼键
  - `static func key(for item:)` (18) — 聚合项 → 基键
  - `static func snoozedUntilTomorrowKey(_:now:calendar:)` (21) — 稍后（次日键）= 基键 + 自然日后缀
  - `static func hideKeys(for:now:calendar:)` (27) — 读侧可隐藏键集（dose_slot/逾期 OCR/profile_progress 空 = 不可隐藏）
  - `static func writeKey(for:disposition:now:calendar:)` (40) — 写侧：归档=基键、稍后=次日键、其余不写

## CoreKit/Sources/Domain/ObservationService.swift
- `ObservationKind` (6) — FR8.1 八类观察类型规范枚举（rawValue 只在 SQL 边界）
- `ObservationGroup` (12) — F8 观察事件聚合（按 group_id；latest 构建时一次算出防重复最大值扫描）
  - `var latest: ObservationEvent?` (20) — 组内最新事件（存储属性）
  - `var selfMark: String?` (26) — 组内末次自我标记
- `ObservationEvent` (29) — 观察事件（FR8.2 全量投影；敏感媒体只渲染模糊缩略图 BR-007/008）
- `ObservationGroupService.groups(_:member:)` (74) — 按 group_id 归组 + 组内时间升序 + 成员隔离（BR-001）
- `DoctorShowcaseSession` (93) — 就诊展示模式会话（会话式解锁/超时重锁/scope 过滤）
  - `func isActive(at:)` (107) — 会话过期判定（下次进入重新解锁）
  - `func includes(_ event:)` (112) — scope 过滤（成员一致 ∧ 类别在 scope 内）
- `DoctorShowcaseRules.visibleEvents(_:session:now:)` (119) — 会话内可见事件（超时即空 = 自动重锁语义）

## CoreKit/Sources/Domain/OcrConfirmation.swift
- `SourceGrade` (5) — 来源徽章 D/C/rejected（BR-003：机器识别 = 草稿，确认锁 C）
- `CandidateField` (11) — OCR 候选字段（rawText 原文不可覆盖；修订留历史；F25 编码 D 级惰性）
  - `var value: String` (16) — 确认后取值（didSet：改值即清 codeResolution）
  - `private static let historyStampFormatter` (43) — 修订时间戳 ISO8601 静态缓存
  - `var isConfirmed: Bool` (45) — grade == .userConfirmed
  - `mutating func confirm()` (48) — D → C 升格（仅 .ocrUnconfirmed 可确认）
  - `mutating func revise(to:by:at:)` (56) — FR6.4 修订（确认态改值入历史「旧值 → 新值 · 人 · 时间」）
  - `mutating func reject()` (67) — 放弃（grade = .rejected）
  - `mutating func reenable()` (74) — 拒绝 → 回 D 级（误点放弃的逆向路径）
- `ConfidenceTier` (78) — 置信三档（高/中/低；≥0.8 / ≥0.5）
- `OcrConfirmationSet` (86) — 一份 OCR 结果的确认工作台（BR-003：全确认前不入时间轴）
  - `var allConfirmed/confirmedFields` (96-97) — 全确认判定与已确认子集
  - `var keyedValues: [String: String]` (103) — 已确认字段 key→value 单一出口（替代三处内联 Dictionary 构造）
  - `var isUsableInTimeline: Bool` (110) — 未确认不入时间轴的文档级验证
  - `var hasUnconfirmedLowConfidence/allConfirmAllowed` (122-127) — 低置信闸门（只统计 .ocrUnconfirmed）
  - `mutating func confirm(field:)` (112) — 按 id 确认单字段
  - `mutating func confirmAllRemaining()` (134) — 批量确认（调用方须先查 allConfirmAllowed）

## CoreKit/Sources/Domain/OCRExtraction.swift
- `OCRExtractedSpan` (4) — 模型定位的原文字段片段（key/value/unit/lineIndex）
- `OCRGrounding` (14) — 输出校验防线（独立于提示词：错行/编造/数字子串/否定删除不得进确认卡）
  - `static let allowedKeys/documentTypes/narrativeKeys/numericKeys/negationGuards` (16-79) — 键目录与守卫词表（spec 键集同源）
  - `static func fields(_:lines:allowedKeys:narrativeKeys:numericKeys:extraLabels:)` (84) — 候选 → FieldDraft（逐条 grounding：行内子串/数值独立 token/否定守卫/单位边界）
  - `static func hasBoundedNumericOccurrence(of:in:strictLeading:strictTrailing:)` (122) — 值在行内是否至少一处独立数字 token
  - `static func normalized(_ value:key:)` (137) — 词表归一（币种/票据类型/单位/处方类型/报告类型等 → canonical raw；severity 刻意不归一）
  - `static func labeledValue(_ line:extraLabels:)` (169) — 「已知标签：值」剥离；标签不在已知集则原行返回

## CoreKit/Sources/Domain/OwnerFlow.swift
- `LocalOwner` (5) — ADR-015 本机数据所有者（P0 离线内核根身份；与 UserAccount 严格分离）
- `OnboardingProgress` (21) — FR21.9 六步注册向导 M1a 切片（断点续填）
  - `Step` (22) — disclosureL1/localOwner/selfProfile
  - `mutating func complete(_:)` (33) — 完成步骤 + finished 判定
- `DisclosureCard` (40) — F20 L1 首启三卡（产品边界/本地存储/可跳过项）
- `SceneDisclosure` (51) — L2-L4 场景须知条目
- `ConsentRecord` (60) — 同意落库记录（key/level/version/acceptedAt）
- `DisclosureRegistry` (75) — 四层须知注册表（l1Cards/l2Disclosures/l3Disclosures/l4Disclosures 机械目录）
  - `static func isConfirmed(scene:consents:)` (147) — 场景是否已确认（版本无关）
  - `static func isConfirmed(scene:version:consents:)` (151) — 版本感知判定（注册表反查 key 精确匹配；未注册场景回落包含匹配）

## CoreKit/Sources/Domain/PageLayout.swift
- `LayoutRect` (9) — 版面矩形（归一化 0…1、原点左上；避让 Vision NormalizedRect 命名）
  - `var midY/maxY/midX/maxX` (14-17) — 派生几何量
  - `func union(_:)` (19) — 最小外接矩形
  - `func contains(x:y:)` (26) — 闭区间点包含判定
- `TextBlock` (32) — 识别文本行块（id = "b<lineIndex>"，与 Recognition.lines 下标对应）
- `TableCell` (45) — 表格单元格（iOS 26 表格出；lineIndices = 中心落在格内的行）
- `TableRow` (52) — 表格行
- `TableRegion` (58) — 表格区域（header 由 Domain 按列别名判定，识别层恒 nil）
- `Paragraph` (65) — 段落（text/bbox/lineIndices）
- `PageLayout` (73) — 单页版面（blocks 恒有；tables/paragraphs 仅 iOS 26）
  - `static func linesOnly(_:)` (79) — 兼容退化：每行一块、竖直等分
- `LayoutCell` (89) — 几何聚行产物一格
- `LayoutRow` (97) — 几何聚行产物一行（text = cells 拼接）
- `LayoutRowBuilder` (107) — 几何聚行（iOS < 26 行身份来源；确定性、与输入顺序无关）
  - `static func rows(from:overlapRatio:)` (110) — 按 (midY,x,lineIndex) 排序，锚定首块竖向重叠判定同行
  - `static func assignColumns(_:tolerance:)` (140) — 左边界一维聚类 → columnIndex

## CoreKit/Sources/Domain/Paywall.swift
- `ProductID` (12) — 商业化产品（现仅 proBase；云同步等死 case 已清除）
- `PaywallTrigger` (17) — 弹墙时机（仅价值触发点：第 5 成员/Pro 首击/AI 额度尽）
- `FreeRedLine` (24) — 免费红线能力清单（收费 = 产品缺陷）
- `FreeQuota` (36) — 免费额度（成员 4/高级 AI 20 次月/云备份 5GB）
- `PaywallRules` (50) — 弹墙调度规则（①触发且未解锁 ②24h 频控 ③红线绝不弹 ④到期不删产出）
  - `static func shouldShow(trigger:entitlementUnlocked:lastShownAt:now:)` (53) — 弹墙判定（24h 频控）
  - `static func isBlockable(_:)` (67) — 反向约束：免费能力不可禁用
  - `static func addingMemberWouldExceed(currentCount:quota:)` (74) — 加第 N 个是否越过配额（价值触发点语义）
  - `static func memberAdditionBlocked(currentCount:ownedProducts:quota:)` (82) — 成员添加闸门（与弹墙解耦：超额度 ∧ 未持 Pro）
- `EntitlementState` (93) — 权益状态领域模型（红线模块禁读 EntitlementStore）
  - `var hasPro: Bool` (106) — 是否持 Pro
  - `func quotaExceeded(_:)` (109) — 额度判定 → 触发点

## CoreKit/Sources/Domain/PDFDecode.swift
- `DecodedPage` (6) — 解码页面位图（PNG，已降采样）
- `DecodedImage` (23) — 单图解码结果
- `DecodeError` (39) — 解码错误（corruptData/unsupportedFormat/renderFailed/pageIndexOutOfBounds）
- `ImageDecoding` (47) — 解码协议（decodeImage/decodePDF/decodePDFPages 流式）
  - `extension` (61) — decodePDFPages 默认实现回落 decodePDF 逐页派发

## CoreKit/Sources/Domain/PendingCardPayload.swift
- `PendingCardPayload` (4) — FR6.9 版本化无损 D 级快照（v2 = MatchedCard，旧 = shared/rows 双键；永不作为临床事实导出）
  - `var card/legacyShared/legacyRows` (5-7) — 新/旧形态存储
  - `var shared/rows` (10-19) — 只读值投影（旧形态兼容）
  - `init(shared:rows:)` (21) — 旧形态构造；`init(card:)` (25) — v2 构造
  - `static func decode(_ json:cardKind:)` (31) — 反序列化 + 旧形态行提升 + 身份校验
  - `func matchedCard(kind:pageIndex:id:)` (59) — 快照 → MatchedCard 物化（旧形态按页/行确定性推导 rowID）
  - `var json: String` (89) — 排序键 JSON 序列化
  - `init(from decoder:)` (104) / `encode(to:)` (123) — schemaVersion 分派编解码 + validate 防线

## CoreKit/Sources/Domain/PendingOcrRules.swift
- `PendingOcrRules` (11) — FR2.3/FR6.8 待确认 OCR 队列窗口规则（日历日出口，DST 纪律）
  - `static func isOverdue(createdAt:now:)` (15) — 超过 72 小时未处理（严格大于）
  - `static func isWithinLastDays(_:createdAt:now:)` (20) — 最近 N 个日历天筛选窗

## CoreKit/Sources/Domain/PhoneNumberRules.swift
- `PhoneNumberRules` (8) — 电话号码拨号归一（BR-012 急救路径拨号失败修复；非法 → nil 响亮提示）
  - `static func dialable(_ raw:)` (9) — 保留数字（全角折 ASCII）与首位 +；分隔符丢弃；其它字符非法
  - `static let separators` (27) — 允许的分隔符集合

## CoreKit/Sources/Domain/PrescriptionLine.swift
- `PrescriptionLine` (7) — v25 处方行实体 DDL 镜像（剂量/数量/频次一律原文不解析，BR-006/007；单价/金额可 Double）
  - `static let unassignedId` (9) — 父键占位（store 落库时填写）
  - `var id/prescriptionId/patientId/ordinal/printedName/…/updatedAt` (11-43) — DDL 同名同序字段（29 个；confirmed 默认 false = D 级 BR-003）

## CoreKit/Sources/Domain/PrescriptionPlan.swift
- `PrescriptionSource` (9) — FR9.1 处方来源五通道（ocr/electronic/manual/encounter/history）
- `Prescription` (16) — FR9.2 处方字段全集（确认字段集 + 修订历史；BR-003 全确认才 confirmed）
- `PrescriptionConfirmation` (72) — BR-003 处方确认判定纯函数
  - `static let criticalFieldKeys` (74) — 关键字段 = 药名 + 剂量相关四键
  - `static func isFullyConfirmed(_:)` (79) — 关键字段全确认（未确认处方不得生成正式计划 FR9.3）
  - `static func initialConfirmedFields(source:)` (84) — 手录/电子默认全确认；OCR/复制从空集起步
- `PrescriptionFieldMapper` (105) — 处方 OCR 字段 → 落库三元组（标签身份判定，不用简体字面量）
  - `static func isPrescriptionDocType(_:prescriptionLabel:)` (107) — 处方文档类型判定
  - `static func buildAdviceText(confirmed:labels:)` (117) — 确认字段折叠进带标签文本（无结构化列也不丢内容）
  - `Labels` (128) — 标签文案注入
- `MedicationPlanDraft` (144) — 用药计划草稿（schedule/startDate/endDate/status/dosePerTake 安全线基线）
- `StockLotDraft` (163) — 初始库存批次草稿（FR9.10：效期/位置缺失进待办，不阻塞保存）
  - `var missingRequiredInfo: Bool` (177) — 待办判定（效期或位置缺失）
- `PlanLifecycleEvent` (183) — FR9.15 计划生命周期事件（started/edited/paused/resumed/ended）
- `PlanEndReason` (199) — FR9.15 结束原因（用户显式操作，系统不自动停药）

## CoreKit/Sources/Domain/ProfileSuggestion.swift
- `ProfileSuggestion` (9) — 子项目 D4-1：识别内容 → 个人资料 D 级建议（只从已确认卡原文逐项搬运）
  - `Kind` (10) — bloodType/chronicCondition/allergy/pastHistory
  - `Provenance` (15) — 来源留痕（卡类/实体表+id/字段键/文档页/回执行 id）
  - `var grade: SourceGrade` (44) — 恒 D（计算属性，不入 Codable）
  - `var dedupeKey: String` (47) — 稳定去重键（kind/来源实体/字段/归一值）
- `ProfileSuggestionExtractor` (59) — 抽取器（纯规则、零 IO、零医学推断）
  - `NarrativeField` (61) — 叙事字段输入；`ProfileSnapshot` (73) — 成员既有资料快照
  - `static let narrativeKinds/bloodTypeLabels/bloodTypeLabelExclusions/negationLiterals/negationPrefixes/clauseSeparators/trailingPunctuation/signTokens` (86-111, 229) — 词表（单一事实源）
  - `static func suggestions(narratives:diagnoses:labResults:existing:provenance:)` (121) — 叙事 → 诊断行 → 检验行顺序抽取；去重按落库目标分域
  - `static func isNegation(_:)` (163) — 整段否定判定（子句切开只为判定；任一子句非否定 → 交用户裁定）
  - `static func bloodTypeValue(itemName:resultText:)` (186) — 血型行判定 + 字形归一；不可辨 → 原文
  - `static func fold(_ value:kind:)` (255) — 去重折叠（小写去空白；血型另去型/括号）
  - `static func dedupeScope(_:)` (246) — 去重域 = 落库目标表
  - (私有) `stripTrailingPunctuation/foldLabel/isBloodTypeLabel/normalizedBloodType/foldBloodValue` (173-241) — 字符归一与判定私有助手

## CoreKit/Sources/Domain/RecordHierarchy.swift
- `RecordHub` (11) — v27 主卡枢纽三类（encounter/hospitalization/health_exam）
- `RecordChildKind` (16) — 子卡类（主从关系表；预约/提醒/原件走专用路由）
  - `var timelineKind: TimelineEntryKind` (21) — 时间轴条目类型映射（immunization → vaccination）
  - `var cardKind: String?` (26) — AppRoute.medicalCard 卡类字符串（= 事实表名）
- `TimelineHubRow` (44) — 主卡页一行（主卡或无枢纽叶子）
- `TimelineChildRow` (52) — 子卡行（hubId 多重归属）
- `TimelineHubEntry` (59) — 分组后时间轴项（主卡带已排序子卡与按类型计数）
  - `var isHub/id` (64-66) — 枢纽判定与展开记忆键
- `TimelineHubPage` (73) — 主卡分页结果（游标同 TimelinePage 纪律）
- `TimelineHierarchyRules` (80) — 分组/子卡序/筛选/展开集纯函数
  - `static let childKindOrder` (82) — 子卡类型序（13 类）
  - `static func group(rows:children:)` (89) — 子卡按 hubId 归入本页主卡（同主卡同子卡只现一次）
  - `static func childOrder(_:_:)` (103) — 日期倒序 → 类型序 → refID 倒序（稳定）
  - `static func visible(_:filter:)` (111) — 类型筛选：主卡命中整卡保留，否则只留命中子卡
  - `static func expanded(_:filter:remembered:)` (127) — 展开集：筛选态命中即展开；无筛选 = 记忆值 ?? 全折叠

## CoreKit/Sources/Domain/RegistrationPrefill.swift
- `RegistrationPrefill.Defaults` (11) — 注册表单预填默认值（性别/出生年月日/血型；isEmpty 判定）
- `RegistrationPrefill` (7) — 首启注册 Health 特征型预填（绝不阻断注册）
  - `static let standardBloodTypes` (9) — 标准血型八档（HealthKit 一一对应）
  - `static func defaults(from characteristics:)` (34) — 特征型 → 表单默认值（血型仅八档内预填；日期精度随来源）
- `EmergencyContactDraft` (53) — 首位紧急联系人草稿（phone 必填 DDL NOT NULL）
  - `var isValid: Bool` (64) — 三字段 trim 非空 ∧ 手机号基本形态
  - `static func validPhone(_:)` (70) — 号码形态校验（数字 5-20 位，允许 + - 空格括号）

## CoreKit/Sources/Domain/ReminderAggregationCenter.swift
- `AggregationWindow` (10) — 聚合时间窗（过去 7 日/未来 14 日；持久化键 actionFeedWindow 冻结）
- `AggregationKind` (20) — 聚合类别（9 类，pendingCard 为 FR6.9 增）
- `AggregatedReminderItem` (33) — 聚合投影项（source_kind+source_id 去重；BR-003 不携带未确认医疗值）
  - `SourceKey` (35) — 去重键
  - `var isPinned: Bool` (82) — 强制置顶（priority ≥ 2：SOS/高风险 OCR/L1+）
- `AggregationEmptyContext` (86) — 空态上下文（与全局无数据混淆区分）
- `ReminderAggregationCenter` (97) — 统一提醒聚合中心（Domain 纯函数投影层，视图零逻辑）
  - `static func compressKey(_:)` (100) — 周期计划 (planID, window) 压缩键
  - `static func aggregate(_:window:now:memberId:)` (111) — 去重 → 成员/窗口过滤（置顶豁免）→ 周期压缩 → 排序
  - `static func filtered(_:kind:)` (169) — 类别筛选（置顶恒保留）
  - `static func showsFirstDayGuide(items:isNewUser:progressKind:)` (180) — 首日引导优先级（除资料完善外无真实提醒才整页展示）
  - `static func pendingCardItem(cardId:cardKind:patientId:createdAt:status:)` (186) — 待办卡投影（非敏感摘要，dueDate = +24h）

## CoreKit/Sources/Domain/ReminderDisposition.swift
- `SwipeSide` (4) — 滑动侧别（leading/trailing，Domain 自有不引 SwiftUI）
- `ReminderDisposition` (8) — FR2.1⑦ 首页行处置动作（无 case 删除医疗事实；用药动作只写 dose_log BR-004）
  - `case markTaken/snoozeDose/skipDose/openCabinet/snoozeUntilTomorrow/archive/viewEvidence/view/resumePendingCard` (9-14) — 源动作表
  - `var side: SwipeSide` (16) — 动作所在侧
  - `var isMedicalAction: Bool` (23) — 医疗事实动作（不得全滑触发）
- `extension ReminderAggregationCenter` (26) — 按源动作表派发处置
  - `static func dispositions(for:)` (28) — 源 → 可用动作序列（按钮顺序）
  - `static func allowsFullSwipe(for:side:)` (40) — 全滑仅对纯信息行的稍后/归档开放

## CoreKit/Sources/Domain/ReminderReconcile.swift
- `ReconcileAction` (6) — §5.4 对账决策动作（schedule/markAwaitingUser/snooze/none）
- `DoseDeliveryFact` (13) — 剂量的三个事实（送达/用户动作/临期 + 药品投影 + 成员）
- `ReconcileEngine` (37) — 对账决策纯函数
  - `static func decide(_ f:now:)` (42) — 已服不动（BR-004）；未送达补排；过宽限期标待处理；稍后过宽限同样回收
  - `static func snooze(until:now:)` (60) — 稍后目标须晚于 now
  - `static let preScheduleWindowDays = 7` (65) — 滚动预排窗口（iOS 64 pending 上限）
  - `Priority` (71) — 裁撤优先级（用药 > 预约 > 随访；手工 `<` 按 rawValue——工具链对 raw-value 枚举不合成 Comparable，删则破坏 trim 排序）
  - `static func trim(_:budget:)` (74) — 超限裁撤（优先级 + 时间升序，截断到 budget）
- `AppointmentTier` (85) — FR10.3 预约分级提醒四级触发点（负 offsetDays 日历日）
  - `static let defaults` (95) — 7d/3d/1d/day(9:00)
- `AppointmentRules` (103) — 预约提醒规则
  - `static func tierFireDates(startsAt:tiers:now:calendar:)` (105) — 从 starts_at 反算四级触发时刻（fire > now ∧ ≤ startsAt）
  - `static func canMarkMissed(startsAt:now:)` (124) — 未开始不可标错过（视图/商店共享，不得内联）
  - `static func canMarkCompleted(startsAt:now:)` (132) — 未开始不可标完成（历史造假 BR-004）
- `ReminderChannelKind` (138) — FR9.18 通道（inApp/local/persistentRing/serverPush）
- `ChannelFallback` (142) — 降级矩阵（InApp → Local → Persistent 顺序回退）
  - `static func fallbackChain(from:)` (145) — 目标通道降级链
  - `static func resolve(preferred:availability:)` (155) — 选首个可用；全不可用 nil
- `ReminderChannelRules` (165) — 分通道偏好投递判定（notifyId 前缀 → 类别 → 偏好值）
  - `static func categoryKey(for notifyId:)` (168) — 前缀 → 六类偏好键；未识别 nil 回落全局缺省
  - `static func shouldDeliverSystem(_:preference:)` (189) — 是否投递系统通知（非法值不改变现状）
  - `static func hasInAppBannerCoverage(_:)` (207) — 应用内横幅承接族（仅 dose-/slot-）
  - `static func suppressSystemDelivery(_:bannerEnabled:preference:)` (219) — 排程抑制须 (a)(b)(c) 三者同立
  - `static func foregroundDelivery(for:bannerEnabled:medsPreference:)` (234) — 前台系统呈现策略（bannerAndSound/soundOnly/silent）
- `ForegroundDelivery` (252) — 前台呈现策略中性枚举（App 层再映射 UNNotificationPresentationOptions）

## CoreKit/Sources/Domain/ReminderRules.swift
- `BatchExpiryTier` (5) — FR9.11 批次到期三级（t30/t7/t0）
- `BatchExpiryRules` (12) — 效期分类与触发点（日历日 + 固定秒兜底，误差偏向更早告警 ADR-009）
  - `ExpiryStatus` (16) — expired/within7/within30/later
  - `static func status(expireAt:now:calendar:)` (28) — 三档分类
  - `static let daysBefore` (40) — 三级提前天数
  - `static func fireDates(expireAt:now:calendar:)` (50) — 触发点序列（已过不补发）
- `ObservationFollowUpRules` (61) — FR8.10 观察随访节奏（首访 3 天后、此后每周）
  - `static let firstFollowUpDays/repeatIntervalDays` (63-64) — 默认节奏
  - `static func followUpDate(from:occurrence:calendar:)` (69) — 随访日期（日历日推进；失败固定秒兜底）
- `BackupReminderRules` (86) — FR13.10 定期备份提醒（距上次 >30 天）
  - `static func needsReminder(lastBackupAt:now:intervalDays:calendar:)` (90) — 从未备份/到期提醒
- `VoiceReminderRules` (100) — FR17.10 语音提醒设定（模糊时间不落不产出）
  - `static func resolveDate(phrase:now:calendar:)` (105) — 相对短语 → 具体日期（明天/明早/后天/今天）
  - `static func resolveDate(from drafts:now:calendar:)` (118) — 草稿集 → 触发时刻（date 优先；hour 给时刻；已过/非法一律 nil 绝不猜时间）
- `DayArithmetic` (167) — 日历日偏移统一出口（DST 纪律；固定 86400 秒切换日偏差 ±1h）
  - `static func offset(days:from:calendar:)` (168) — 日历日偏移
  - `static func since(days:now:calendar:)` (175) — N 天前 Unix 时刻（检索窗口用）
- `VoiceRepeatRules` (183) — FR17.10 重复短语 → weekday 集合（与 VoiceGrammarDefaults.repeatPatterns 同一事实源）
  - `static func weekdays(for phrase:fireWeekday:)` (186) — 短语映射（空数组 = 每天；nil = 未知回落一次性）
- `VoiceGrammarDefaults` (210) — M1.5 文法子集唯一事实源（生产与测试共用；metricRules/reminderRules/profileRules 机械目录，各 7/2/6 条）
## CoreKit/Sources/Domain/RuleExtractor.swift
- `RuleExtractor` (15) — 子项目 E3 T3 规则轨（确定性、纯函数、零网络：版面区域 + 卡 spec → 带 TextAnchor 的 GroundedValue）
  - `static func extract(region:spec:lines:)` (16) — 入口：共享字段 + 行级字段
  - `static func anchor(_ line:row:page:)` (22) — 行锚构造
  - `static func split(label cell:aliases:)` (27) — 「标签[:：]值」剥离；标签独占 cell → ""；标签后跟字 → nil；值域截到下一标签位
  - `static func dateToken(in:)` (42) — 行内日期 token 提取
  - `static func sharedFields(region:spec:lines:)` (51) — 共享字段提取（标签命中 → 日期类取 token → 叙事续行并入 ≤6 行 → fallback）
  - `static func apply(_ fallback:region:lines:)` (93) — RuleFallback 兜底（首日期/含词 token/科室词尾短行）
  - `static func rowFields(region:spec:lines:)` (123) — 行级字段：①列头映射 ②行级标签剥离再分类 ③合体行正则拆分 ④无行锚并入上一药品行；rowMinFields 过滤
  - `static func columnMap(_:spec:)` (177) — 列头 token → 行字段键（≥2 列且含行锚）
  - `static func isPureHeader(_:spec:)` (189) — 首行全 token 为列头标签判定
  - `static func splitPrescriptionLine(_:)` (205) — 处方合体行拆分公开出口（供生成轨后处理，全部 D 级 BR-003）
  - `static func prescriptionNameNeedsSplit(_:)` (211) — 药名是否混排用法/规格短语（拆分判据）
  - `static func classify(_ text:kind:)` (221) — cell → (键, 原文子串) 列表（处方/检验/费用三类规则族）
  - `static func trailingFlag(_:)` (294) — 行尾异常标志（↑↓/H/L）只取原文不解释（BR-004/012）
  - `Patterns` (302) — 编译期静态文法（rx 一次性编译；drugWithSpec/drugName/labValue/labQualitative/referenceRange/unit/flag/labelText/amount/itemWithAmount/date/spec/dosage/frequency/route/days/quantity 17 条，锚点 302-326）
- `ContinuationRules` (331) — 续页建议（round2 O-N4）：多页表格续页只产 continuationHint（E5 低置信草稿，BR-003）
  - `static let carried` (332) — 可延续键（hospital/department/doctor）
  - `static func apply(_ cards:specs:)` (334) — 缺失必填/延续键从上页同卡借值入 hint

## CoreKit/Sources/Domain/ScanPreprocess.swift
- `PreprocessParams` (9) — §5.1 预处理参数（透视矫正/色彩模式/旋转/重置，确定性）
  - `ColorMode` (29) — color/grayscale/binary
- `PreprocessedImage` (37) — 预处理结果（处理后 Data + 原始帧引用不拷贝 + 参数回放 + 版本号）
- `PreprocessError` (59) — 预处理错误（noDocumentDetected/perspectiveCorrectionFailed/decodeFailed/encodeFailed）
- `NormalizedPoint` (69) — 归一化坐标点（不用 CGPoint：Domain import ⊆ {Foundation}）
- `QuadCorners` (76) — 四角选区（交互裁剪与透视矫正共用契约）
  - `static let fullImageInset` (92) — 5% 内缩整图四角（自动检测失败回落）
- `ImagePreprocessing` (100) — 预处理协议（preprocess/detectQuad/correctPerspective；原始帧不可变 BR-002）

## CoreKit/Sources/Domain/SearchService.swift
- `SearchQuery` (6) — F12 搜索查询（text/member/docKinds/dateRange/includeArchived）
- `SearchHit` (22) — 搜索命中（docID/snippet/field/date）
- `SearchRoute` (32) — 查询长度路由（trigram/bigram/like/invalid）
- `SearchRules` (39) — 搜索语义（Domain 持路由与校验，FTS 执行归 Infrastructure）
  - `static func cjkLength(_:)` (42) — 非空白字符数（CJK 与拉丁混排均可路由）
  - `static func route(_:)` (47) — V3.24 长度路由：≥3 trigram / 2 bigram / 1 LIKE / 空 invalid
  - `static func bigrams(_:)` (64) — 2-gram 切分（写入侧与查询侧同源；只产双字母/数字 gram）
  - `static func isSensitiveDoc(_:)` (83) — 敏感媒体 docKind 判定（敏感媒体只命中元数据规则）
  - `static let highlightOpen/highlightClose` (91-92) — 片段高亮标记单一事实源（防 `<b>` 字面渗出）
  - `SnippetSegment` (95) — 拆段结果（text/highlighted）
  - `static func highlight(_ text:query:)` (105) — contentless FTS 手动高亮（±12/24 字上下文 + 省略号）
  - `static func highlightSegments(_:)` (121) — 带标记片段拆段（未闭合/嵌套异常按纯文本，绝不吞字）
  - `static func stripHighlight(_:)` (142) — 去标记纯文本（AI 摘录/无障碍朗读/导出）

## CoreKit/Sources/Domain/SharedFieldPool.swift
- `SharedFieldPool.Carrier` (25) — 承载方：哪张卡的哪个面（shared/row/hubDraft）持键
- `SharedFieldPool.Row` (37) — 共用信息行（键值 + 待确认草稿 + 承载方集合 + 入池原因）
  - `var id: String` (50) — 稳定行身份 = 键 + 首个承载方（不含值，改值不漂移）
- `SharedFieldPool` (22) — 跨卡共用信息汇集与回填（业主 2026-09-17 定：确认两步——先共用信息再逐卡行级）
  - `static func rows(cards:floor:)` (59) — 汇集入口：collectSlots → 键/值+单位归并 → 三条析取入池
  - `private static func collectSlots(cards:)` (109) — 汇集阶段：三面摊平成槽位 + 共享面缺席必填键空值补位
  - `private struct Slot` (154) — 汇集槽位（key/value/unit/field/carrier/required）
  - `static func isSettled(_:)` (160) — 「处理完」= 每行已确认（未达只能稍后处理）
  - `static func awaitingCount(_:)` (164) — 未确认行数
  - `static func project(_ rows:into cards:)` (170) — 出池回填：确认值写回每个承载方（revise 留痕 + confirm；不覆盖承载方 originalValue/rawText）
  - `private static func apply(_ row:to fields:key:)` (197) — 单承载方回填（缺席补条/改值 revise/确认 confirm）

## CoreKit/Sources/Domain/SignedModelCatalog.swift
- `SignedModelEnvelope` (4) — ADR-030 签名覆盖 payload 原始字节的信封（keyId + signature）
- `ModelTrustRoot` (13) — 模型信任根（schemaVersion/role/app/assetKind/keys/rootKeyIDs/catalogKeyIDs/阈值/allowedHosts）
- `SignedModelCatalog` (33) — 签名模型目录（索引 + revokedHashes）
- `ModelResourcePolicy` (47) — 资源协议上限（元数据/包体/展开体/zip 条目/运行时版本/allowedHosts）
  - `static func isSHA256(_:)` (55) — 64 位十六进制校验
  - `static func isSlug(_:)` (58) — 资源 slug 校验（字母数字起始 + [-._]）
  - `static func allowedURL(_:)` (65) — https + 无 user/password + 主机白名单

## CoreKit/Sources/Domain/SleepMerge.swift
- `SleepStage` (11) — 睡眠阶段（inBed/awake/core/deep/rem/unspecified）
- `SleepSample` (20) — 睡眠样本（起止/阶段/来源三键）
- `SleepNightSummary` (40) — 一晚合并摘要（入睡并集总时长/各阶段/在床/起止/段数/优先来源/窗左边界）
- `SleepMerge` (70) — FR16.1 睡眠区间合并（双来源并集防双计；阶段优先 staged 覆盖 unspecified；noon 锚归夜）
  - `static let mergeGap/segmentGap` (72-74) — 相接 5min 合并 / 30min 分段阈值
  - `static func merge(_ samples:anchorDate:calendar:)` (78) — 合并入口（noon 锚窗口裁剪 → 阶段累计 → 并集总时长 → 分段计数）
  - `private static func clip(_:to:end:)` (100) — ①窗口裁剪（跨午夜样本按交集裁剪）
  - `private static func prioritySourceName(_:)` (115) — 最高优先来源名（优先链一次求值）
  - `private static func stageTotals(_:)` (125) — ④⑤边界分段按优先级归阶段 + 入睡段收集
  - `private static func segmentCount(of:)` (156) — ⑥分段计数（gap 按前段结束→后段开始计）
  - `static func union(_ intervals:)` (169) — 区间并集（缺口不计时长）
  - `static func sourceRank(_:)` (183) — 来源优先（watch>phone>other → version 高者优先）

## CoreKit/Sources/Domain/SleepTrend.swift
- `extension MetricType` (14) — 睡眠族映射
  - `var sleepStage: SleepStage?` (16) — 阶段键 → 阶段（sleep_total 无阶段）
  - `var isSleep: Bool` (29) — 睡眠族成员（宫格折叠/整合查询/空态判据共用）
  - `static let sleepGroupKeys` (33) — 睡眠族查询键单一事实源
- `extension SleepStage` (38) — 柱内堆叠顺序（分类编码，段色不表达好坏 BR-006）
  - `var trendStackOrder: Int` (42) — 深睡→核心→未分期→REM→清醒（与 Apple Health 图例同序）
  - `static var trendStack` (53) — 按顺序排序的全阶段
- `SleepTrendRow` (59) — 整合输入行（指标 + 点）
- `SleepStageSlice` (69) — 一晚某阶段时长段（pointIds = 排除/恢复动作对象）
- `SleepTrendNight` (82) — 一晚（noon 锚窗）堆叠柱：可见段 + 总时长投影 + 全部原始行 id
  - `var stackedHours/pointIds` (101-103) — 柱高 = 各段之和；排除动作作用集
- `SleepTrendSeries` (106) — 整合序列（可见夜 + 已排除夜 + 查询身份）
- `SleepTrendRules` (119) — FR7.11 睡眠整合规则（纯函数金样单测）
  - `static func series(_ rows:identity:calendar:)` (126) — 原始行按夜聚合（同 (夜,阶段) 取最大值保留全 id，跨行求和即双计）
  - `static func gridRows(_:metric:value:)` (188) — 宫格折叠：睡眠族六键只占一块瓦片（sleep_total 恒胜否则最大值）

## CoreKit/Sources/Domain/SpeechFallback.swift
- `SpeechOutcome` (8) — 发声结果（实际 locale + 是否回退）
- `SpeechFallback` (19) — FR17.16 发声语言回退链（纯函数，两端实现共用）
  - `static func resolve(requested:availableVoices:)` (29) — 请求命中直用 → 普通话回退（须真实可用）→ 字典序首中文 → 首可用；outcome 如实报告

## CoreKit/Sources/Domain/TextUnderstanding.swift
- `TextUnderstandingInput` (10) — FR17.18 统一输入（文本 + 来源上下文；OCR 保行结构、语音带置信度）
  - `Source` (11) — ocr(documentTypeHint:)/voice(intentHint:confidence:)
  - `var transcriptionConfidence: Double?` (39) — 语音来源置信度（OCR nil）
- `UnderstandingSource` (48) — 字段草稿产出轨（8 轨 + unknown）
- `TargetCandidate` (61) — 判定候选（key/confidence/source）
- `UnderstandingResult` (73) — 理解层输出（意图/类型候选 + D 级字段 + 已命中行下标 + 引擎不可用）
- `UnderstandingCodeResolution` (107) — F25 医疗槽位惰性接线（BR-003 惰性/绝不猜码/覆盖表恒胜）
  - `static let medicalSlotKeys` (110) — 医疗槽位键族
  - `static func resolve(_:locale:index:units:)` (116) — 逐字段解析；读数联合解析优先（单位参与定码）；失败不阻断主流程
  - `static func splitReading(_:)` (157) — 「名称 数值」合体载荷拆分（尾段可 Double 即数值）

## CoreKit/Sources/Domain/TimelineProjection.swift
- `TimelineDocumentEntry` (5) — F11 M1a 最小投影（文档；BR-003 未确认只存在于待确认队列）
  - `State` (6) — pending/confirmed
- `TimelineProjection` (43) — 投影规则纯函数
  - `static func entries(from:patientId:occurredAt:originalPaths:)` (44) — 确认集 → 投影（保字段序与历史新→旧）
  - `static func officialTimeline(from:)` (65) — 正式区查询（未确认绝不出现 BR-003）
  - `static func pendingQueue(from:)` (69) — 待确认队列

## CoreKit/Sources/Domain/TimelineService.swift
- `TimelineEntryKind` (5) — 时间轴条目类型（22 类；healthData 与 selfMeasured 分列；v27 主卡/子卡类）
- `TimelineEntry` (20) — 统一时间轴条目（kind/date/title/summary/refID/memberId/grade/metricKey）
  - `var id: String` (34) — kind-refID 稳定身份
- `TimelineFilter` (43) — 筛选（all/kinds）
- `TimelineCursor` (49) — 游标（date DESC, id DESC 跨页稳定）
- `TimelinePage` (55) — 分页结果
- `TimelineProjectionRules` (63) — §5.30 投影语义纯函数
  - `static func sort(_:)` (65) — date DESC → refID DESC 稳定排序
  - `static func after(_:cursor:)` (73) — 游标过滤
  - `static func page(_:limit:)` (81) — 页切取 + 下一页游标（limit ≤ 0 降级不分页不 trap）
  - `static func scoped(_:member:)` (95) — 成员隔离（BR-001）

## CoreKit/Sources/Domain/TodayStore.swift
- `TodaySnapshot` (5) — F2 首页今日聚合（八源合并单一快照，视图零逻辑；BR-001 成员隔离）
  - `static let empty` (29) — 空快照
- `TodoItem` (32) — 待办（kind/at/title/memberId；id = kind-title-时间戳）
- `ExpiryItem` (44) — 临期条目；`RefillItem` (54) — 续药条目（id 含 lotId 防同药多批次碰撞）；`AlertRef` (71) — L1+ 告警引用；`ObsRef` (81) — 观察引用
- `CaptureKind` (94) — 快速拍摄类别（record/report/prescription/symptom；今日快照 + AppRoute 共用单一事实源）
- `TodayAggregator.snapshot(member:todos:pendingOCRCount:expiring:refills:alerts:observations:)` (101) — 聚合入口（成员隔离 → 待办时间升序合并 → 七卡组装；L0 告警不入首页）

## CoreKit/Sources/Domain/TranscriptionSegmentation.swift
- `TranscriptionSegmentation.Window` (12) — 切窗（startSeconds/lengthSeconds）
- `TranscriptionSegmentation` (8) — 长音频分段策略（基线轨 60s 截断切窗续接；升级轨单窗）
  - `static let fallbackLocale` (10) — 方言无独立引擎时的回落 locale（识别与发声回退链共用）
  - `static func plan(durationSeconds:capability:overlapSeconds:)` (24) — 切窗规划（留 5s 安全余量防竞态；窗口间重叠防丢字）

## CoreKit/Sources/Domain/Transcription.swift
- `TranscriptionCapability` (15) — 引擎能力（ADR-023 双轨门控两态由 supportsLongForm 承载）
  - `static func baseline(locales:)` (34) — 基线轨默认（60s 上限）
  - `static func longForm(locales:)` (38) — 升级轨默认（长音频免分段）
  - `func locale(matching:)` (43) — 探测标识匹配（精确 → 归一 → 语言码）
  - `func resolvedLocale(for:)` (54) — 方言回落链（粤/闽南/吴/四川/台 → 普通话）
- `TranscriptionLocale.normalizedIdentifier(_:)` (71) — BCP-47 别名归一（仅已知别名；无关区域保持不同）
- `TranscriptionLanguageMode` (87) — FR17.15 语言模式（single 强制/mixed 交给模型语种识别）
- `TranscriptionRequest` (89) — 单次按压请求（sessionID 先分配；contextualStrings 领域词偏置）
- `TranscriptionCompletion` (111) — 完成形态（final/partial/timedOut/interrupted/bufferOverflow）
- `TranscriptionResult` (115) — 转写结果（文本/置信度/实际 locale/分段/段集/完成形态/引擎 id）
- `TranscriptionError` (142) — FR17.6 转写不可用降级错误（不可用即手输，不是崩溃）
## CoreKit/Sources/Domain/TranscriptJoiner.swift
- `TranscriptJoiner.join(_ segments:)` (11) — 转写显示文本统一拼接（CJK 直接相接；拉丁/数字相邻补空格——两轨共用单一实现）

## CoreKit/Sources/Domain/TranscriptRefinementState.swift
- `TranscriptVersion` (3) — native/refined
- `TranscriptSourceSnapshot` (8) — 一次确认的不可变来源（sessionID/generation/授权代次/原文/选用文本/版本）
  - `var requiresOriginalPersistence: Bool` (16) — 选用文本 ≠ 原文时须持久原文
- `TranscriptRefinementState` (22) — SP-55 来源身份与格式选择状态机（无音频/会话引擎所有权）
  - `var canClearLast: Bool` (34) — 有追加历史才可撤回
  - `mutating func edit/append/clearLast/clearAll/select/revokeAI/cancelRefinement` (36-82) — 编辑族（整编失效边界；追加留历史；选择授权门控）
  - `mutating func beginRefinement(authorized:authorizationGeneration:)` (84) — 开始润色（授权 + 非空 + 无紧急词 FR 前置）
  - `mutating func publish(_:for:authorized:authorizationGeneration:)` (94) — 发布修订（来源/代次/授权代次全核对；原文不符 → unavailable）
  - `func snapshot(authorized:authorizationGeneration:)` (112) — 当前快照（accepted 且授权代次相符才用建议）
  - `func matches/canCommit/finishCommit` (123-145) — 提交前校验与收尾（成功提交即 clearAll）
  - `private mutating func invalidate()` (147) — 代次递增 + 清修订/授权/润色态

## CoreKit/Sources/Domain/TranscriptRefinement.swift
- `RefinementSafety` (5) — 润色安全级（accepted/rejected/unavailable/timedOut；只允许格式修正 BR-003/006）
- `TranscriptRevision` (12) — 修订结果（构造时 accepted 即过受保护 token 校验）
  - `var effective: String` (24) — 生效文本：仅 accepted 用建议
  - `static func unavailable(_:)/timedOut(_:)` (25-30) — 降级构造
- `ProtectedTokenValidator.validate(original:suggested:drugNames:personNames:)` (37) — 只许 ASCII 空格归一与句尾句号；字典不是安全边界（每源字节受保护）
  - `private static func normalizedSpaces(_:)` (49) — 连续空格归一为字节序列

## CoreKit/Sources/Domain/TranscriptSession.swift
- `TranscriptSessionAccumulator` (7) — FR17.1 一次按压会话累加器（isFinal 只是提交一段；显示 = 已提交 + 部分）
  - `mutating func commit(_:)/updatePartial(_:)` (15-27) — 空 final 保留最近部分不结束会话
  - `var displayText: String` (30) — TranscriptJoiner 统一拼接
  - `mutating func finish()` (37) — 松手收尾（未提交部分作为末段；幂等）
  - `static func shouldRotate(elapsedSeconds:capability:)` (47) — 基线轨提前 5s 换段判定
- `MixedSpeechVocabulary` (56) — FR17.15 混说词表（≤100 条：已确认药名 → 医疗单位 → 英文医学词）
  - `static let limit/units/englishMedical` (58-66) — 上限与词表（识别偏置，非医学结论）
  - `static func terms(primaryLocale:otherLocales:recentDrugNames:limit:)` (68) — 词表组装（去重截断）

## CoreKit/Sources/Domain/TrendModels.swift
- `MetricType` (7) — F7 指标类型（16 case）
  - `init?(grammarKey:)` (18) — 语音文法键 ↔ 指标类型单一映射
- `MetricOrigin` (34) — hospital/manual/device
- `BloodPressureEntryRules.minPlausibleSys` (43) — 血压自动跳格合理性下限（≥60 mmHg 视为真实收缩压）
- `MetricEntryRules` (50) — 手录/语音指标合理性界限（界外拒绝落库，缺键放行不臆造）
  - `static func plausibleBounds(for:)` (52) — 宽松生理边界表
  - `static func isPlausible(_:for:)` (68) — 界内/无界放行，界外拒绝
- `TrendPoint` (74) — 趋势点（含 A 级参考范围/来源标签/F25 编码投影/聚合窗口统计）
  - `var isHollow: Bool` (114) — 空心=自测/设备、实心=医院（ui-ux 4.7）
- `ReferenceBand` (121) — 一条独立参考带 = 一个来源 + 一个区间（多带并存，类型层无法合并）
- `ReferenceRange` (132) — 参考范围（Grade A=报告自带 > B=信源库）
- `TrendSeries` (143) — 趋势序列（points 与 excludedPoints 分离，聚合路径不可能忘记过滤）
- `UnitConversion` (166) — 单位换算留痕（factor+offset 仿射；原值不动只在查询层换算）
  - `func convert(_:)` (176) — value × factor + offset

## CoreKit/Sources/Domain/TrendRules.swift
- `TrendRules` (6) — 趋势业务规则（结构轮自 TrendService 拆分）
  - `static func visible(_:)` (8) — 软删排除（默认 WHERE excluded=0）
  - `static func resolveBands(points:libraryFallback:)` (21) — FR7.2 铁律：不同医院参考范围绝不合并；有 A 级不带 B 级；空 = 范围不可用；按来源名稳定排序
  - `static func converted(_:using:)` (49) — 换算留痕（点 + 排除点 + 参考带同步换算，防止跨量纲读出假「超标」）
  - `static func sorted(_:)` (73) — 时间升序稳定排序
  - `static func aggregationKey(metricKey:codeConceptId:)` (81) — F25 聚合键（编码优先、无编码回落 metric_key；BR-003 未确认行为空）

## CoreKit/Sources/Domain/TrendVisualization.swift
- `TrendQueryIdentity` (8) — 趋势查询身份四元（患者/指标/来源/区间；渲染层按身份丢弃过期结果）
- `TrendTimeWindow` (24) — 时间窗四档（week=7/month=30/quarter=90/year=365 日历日）
  - `func interval(endingAt:calendar:)` (30) — 距今 N 日窗口（历史签名）
  - `func period(endingAt:offset:calendar:)` (44) — 锚点可参数化的周期（offset ≤ 0 时 end 与锚点逐位相等）
  - `func paged(by:from:calendar:)` (54) — 翻页步进（更早为正）
  - `func paged(by:from:cappedAt:calendar:)` (67) — 翻页落点边界判定（落点达/过今天 → nil 回落自动锚定）
- `TrendMarkFamily` (76) — 按指标选图型（点/日柱/小时区间/时长柱/成对点）
  - `static func family(for:)` (79) — 指标 → 图型族
- `TrendDownsampler` (92) — 保极值降采样（等宽分桶每桶 min/max 两点 + 首尾补点）
  - `static let maxBuckets = 240` (95) — 桶数单一事实源（视图 gap 阈值同源）
  - `static func thin(_:in:maxBuckets:)` (98) — 降采样；点数 ≤ 2×桶数原样返回
  - `static func gapThreshold(range:pointCount:samplingInterval:maxBuckets:)` (145) — 断线阈值（降采样过 = max(步长×1.5, 桶宽×2)；未降采样不得用桶宽）

## CoreKit/Sources/Domain/TrustedModelHashes.swift
- `TrustedModelHashes.Entry` (18) — 单个发布条目（id/version/bytes/sha256）
- `TrustedModelHashes` (17) — FR17.15 构建期生成的下载哈希信任锚（运行时索引可被替换，本表随包签名）
  - `static let supportedSchemaVersion/empty` (43-45) — 支持版本与空表（空表 = 禁止一切运行时下载）
  - `func entry(id:version:)` (49) — 条目查询
  - `func isTrusted(_ release:)` (54) — 安装判定：命中信任锚且哈希一致（fail closed；未登记版本/不一致一律拒绝）

## CoreKit/Sources/Domain/VoiceCalibration.swift
- `VoiceCalibration.Sample` (18) — 一条金样语料（转写 + 期望抽取；isHumanRecorded 才计入 ≥500 配额）
- `VoiceCalibration.Corpus` (37) — 语料集（version + samples）
- `VoiceCalibration.Report` (50) — 定标报告（样本数/数值准确率/结构率/语种配额）
  - `var passesReleaseLine: Bool` (60) — 三条全中才算过（缺语料一律不过）
  - `var blockingReasons: [String]` (67) — 未达标原因（人类可读，进 CI Step Summary）
- `VoiceCalibration` (15) — FR17.4 语音金样定标与放行线（不变量而非断言：未达标只发触屏路径）
  - `static func evaluate(corpus:extract:)` (85) — 跑定标（extract 注入，生产与测试传同一套文法）
  - `static func isNumeric(_:)` (111) — 数值字段判定
- `FeatureFlags` (120) — 能力开关（高风险能力 flag 化；红线功能不设关闭路径）
  - `static var voiceStructuringEnabled: Bool` (125) — 语音结构化 = 定标通过（不可手工打开）
  - `nonisolated(unsafe) static var voiceCalibrationPassed` (131) — 定标结果置位（显式并发语义声明）
  - `static func applyCalibration(_:)` (134) — CI 跑完金样后回写

## CoreKit/Sources/Domain/VoiceConversation.swift
- `VoiceCommand` (13) — F19 指令文法白名单（24 命令：查询/操作/导航/会话/危险受限）
- `VoiceIntent` (53) — 解析意图（command/record(metricText:)/recordQuestion(text:)/unrecognized）
- `VoiceCommandGrammar` (68) — FR19.2 指令文法解析（正则白名单，非开放域）
  - `static let confirmWord/cancelWord` (73-74) — 命令词词汇表单一事实源（App 键盘快捷词同源）
  - `static func ordinalWord(_:)` (75) — 「第 N 个」词表
  - `Pattern/patterns` (81-121) — 命令 → 正则表（23 条，急救语义词在 callContact 前）
  - `static func parse(_ transcript:emergencyNumber:)` (123) — 解析入口（急救号码按区域注入动态正则先匹配）
  - `static func isForbidden(_:)` (169) — FR19.5 删除/剂量变更词表命中即拒（安全侧偏置）
- `ConversationPhase` (178) — listening/selecting/confirming/repeatingObject/ended
- `ConversationState` (186) — 会话状态（相位/选项/待执行命令/复述对象/静默轮/重播源）
- `ConversationEvent` (196) — 会话事件（speak/askOptions/requireRepeatObject/execute/rejectForbidden/exitGracefully）
- `SpeechPrompt` (207) — V3.68 类型化提示语（App 层经 L10n 渲染，BR-006 措辞在模板层）
- `VoiceConversationEngine` (223) — F19 会话规则引擎（纯函数状态机：输入 = 状态 + 转写）
  - `static let maxSilentRounds/maxOptions` (225-226) — FR19.6 两轮退出 / FR19.4 ≤3 列选
  - `static func step(state:transcript:emergencyNumber:)` (228) — 入口：forbidden 前置 → 再说一遍重播 → 相位分派 → 离开列选即清选项
  - `private static func handleListeningOrSelecting(_:_:text:emergencyNumber:)` (274) — 监听/列选相位（文法解析 → 选项名二次匹配防 BR-004 首条代答 → 意图分派）
  - `private static func handleRepeatingObject(_:_:text:emergencyNumber:)` (404) — 复述对象相位（只认 是/否/取消）
  - `private static func handleConfirming(_:_:text:emergencyNumber:)` (431) — 确认相位（只认 是/否/取消；其余计静默轮）
  - `private static func handleYesNo(_:_:yes:)` (447) — 是/否处理（确认相位执行/取消；非确认相位计无效应答）
  - `private static func countInvalidAnswer(_:_:hint:remember:)` (469) — FR19.6 无效应答计数（四相位共用；满 2 轮礼貌退出即取消待确认）
  - `static func optionsPrompt(_:pendingCommand:)` (484) — 列选提示构造（≤3 项；pendingCommand 透传防查询项执行错指令）
  - `private static func numberIndex(_:)` (497) — 首现数字字符 → 选项下标（确定性，不用无序 Dictionary）
  - `private static func extractObject(_:after:)` (512) — 联系人对像提取（剥「给」前缀）
  - `private static func extractMarkTakenObject(_:)` (527) — 服药对象药名提取（剥动作词与语气词）
  - `private static func extractStockObject(_:)` (541) — 库存指令载荷（最早动词边界截断；泛化药词 → nil 回落全清单）
  - `private static func extractPayload(_:)` (555) — 搜索类载荷剥离（与 patterns 同一词表）

## CoreKit/Sources/Domain/VoiceEngineChoice.swift
- `VoiceEngineChoice` (11) — FR17.15 V3.66 识别引擎档位（auto/qwen3/dolphin/zipformer/whisper/advanced/dictation/classic）
  - `static func resolve(_:)` (22) — 持久化值 → 档位；非法/缺省回落 auto
  - `var usesPlatformAnalyzer: Bool` (28) — 平台分析器家族（iOS 26+ 门控标注）
  - `var requiresLocaleAssets: Bool` (36) — 需下载语言资源包的档位
  - `var isBundledModel: Bool` (38) — 随包模型档位
- `VoiceEngineAvailability` (42) — 档位可用性五态（available/requiresNewerOS/unsupportedDevice/missingModelAssets/downloadable）
- `VoiceLocaleAssetStatus` (59) — locale 端侧资源状态（installed/downloadable/unavailable）

## CoreKit/Sources/Domain/VoiceGrammar.swift
- `MetricGrammarRule` (6) — 指标文法规则（metricKey/patterns/unitDefault）
- `ReminderGrammarRule` (15) — 提醒文法规则（time/hour/date/repeat 四类 pattern）
- `ProfileGrammarRule` (31) — 档案文法规则（fieldKey/patterns）
- `NumberNormalizer` (40) — 中文数字归一（一百二=120 / 一百零二=102；混合形态原值返回强制复核）
  - `static let cnDigits/cnUnits` (41-45) — 中文数字与位权表
  - `static func normalize(_:)` (49) — 归一入口（含「零」本身是数值、口语省位形态）
  - `static func parseDecimal(_:)` (99) — 数值录入解析单一出口（逗号小数点归一）
- `VoiceStructuringEngine` (105) — 受限文法引擎（FR17.9-14 子集；纯函数零网络）
  - `private static let regexLock/compiledCache` (108-109) — 编译缓存（Linux ICU 首编非线程安全，经锁）
  - `static func compiled(_:)` (110) — 缓存编译；非法 pattern 返回 nil 由调用侧跳过
  - `static func firstCapture(in:patterns:groups:)` (123) — 逐 pattern 首命中单一实现（五处匹配循环共用；numberOfRanges 校验集中）
  - `static func extractMetric(_:rules:)` (144) — 指标抽取（数值归一 + 单位取 rule.unitDefault；混合形态降置信）
  - `static func extractReminder(_:rules:)` (164) — 提醒抽取（time/date/hour/repeat 四键；下午限定词 +12h 锚定命中短语前文）
  - `static func extractProfile(_:rules:)` (229) — 档案抽取（每 rule 首命中）
- `VoiceInputTemplate` (245) — FR17.13 标准语音输入模板复用断言载体
  - `static func reminderTranscript(from:)` (249) — 提醒草稿正文重组（日期 + N点）
  - `static func confirmationSet(drafts:documentId:)` (262) — 语音草稿 → 统一确认集（suggestedLabel → displayLabel、codeResolution 透传）
  - `static func fallbackDraft(key:value:confidence:)` (277) — unknown 回落草稿（键/置信度只此一处）

## CoreKit/Sources/Domain/VoiceIntentCatalog.swift
- `VoiceIntentKey` (13) — FR17.19 意图目录键（9 类 + unknown；askAssistant 已退役）
- `VoiceIntentEntry` (28) — 目录条目（key/确认标签键/期一可否自动分类）
- `VoiceIntentCatalog` (42) — 意图目录与期一兜底轨分类器（单一事实源：新增录入 = 目录加一行 + 路由加一支）
  - `static let entries` (44) — 目录（呈现顺序；unknown 恒末位）
  - `static func classify(_ text:confidence:)` (61) — 三文法并行抽取命中数多者胜（提醒单命中门槛）；全零 → unknown 整句进速记
  - `private static func regexMarked(_:)` (91) — 文法产出统一标 source=.regex
  - `private static func unknownFallback(_:confidence:)` (100) — unknown 兜底草稿（source=.unknown）
  - `static func extract(for:text:confidence:)` (105) — 显式改类后的槽位抽取（期一无文法的意图回落纯文本草稿）

## CoreKit/Sources/Domain/VoiceModificationGuard.swift
- `VoiceModificationGuard.Category` (10) — dosage/frequency/discontinue
- `VoiceModificationGuard.Rejection` (16) — 拒绝记录（类别 + 命中短语；文案由 L10n 组装）
- `VoiceModificationGuard` (8) — FR17.11/BR-003/006：语音通道对既有计划的剂量/频次/停用修改一律拒绝
  - `static let phrases` (27) — 触发词表（命中即拒，宁可误拒不可误改）
  - `static func evaluate(_:isExistingPlanContext:)` (37) — 判定（仅修改既有计划语境；频次优先于剂量归因）

## CoreKit/Sources/Domain/VoiceReadback.swift
- `AudioRoute` (11) — 音频输出路由（headphones/speaker，FR17.13 耳机感知）
- `ReadbackPreference` (17) — 无耳机回读偏好三态（never/ask/alwaysInCareMode）
- `ReadbackDecision` (24) — 回读决策（readAloud/screenConfirm/askFirst；[朗读] 按钮恒为无障碍出口）
  - `var isReadAloud: Bool` (34) — 耳机状态即时切换判定
- `ReadbackPolicy` (40) — FR17.13 决策半场（纯函数 Domain 层；回读与否牵涉隐私红线 + 无障碍）
  - `static func decide(route:preference:careMode:)` (54) — 决策表（有耳机一律回读；无耳机默认屏幕核对按偏好）
  - `static func isSelectable(_:careMode:)` (69) — 「总是」仅关怀模式可设
  - `static func rerouted(from:to:preference:careMode:)` (75) — 耳机插拔即时重判；决策未变 → nil
  - `ReadbackPart` (83) — 回读字段对（key 为语义键，App 层映射本地化名）
  - `static func readbackParts(_:)` (100) — 回读字段 = 已确认结构化字段（BR-003 未确认过滤；绝不含音频原文）


## CoreKit/Sources/Infrastructure/ActivePointerStore.swift
- `ActivePointerStore` (9) — ASR 模型活动指针与安装目录生命周期（active.json 读写 + 进程级指针缓存 + 崩溃残留回收）
  - `static func applicationSupportRoot() -> URL` (13) — 运行时资产根目录 Application Support/ASRModels
  - `static func activeRoot(for:) -> URL?` (20) — 已激活（校验过）的版本安装目录；无有效指针返回 nil
  - `static func installedVersion(for:) -> String?` (25) — 已装版本号
  - `static func activeAssets(for:) -> ASRModelAssets?` (29) — 以激活目录 + 包哈希构造资产对象
  - `private static func versionRoot(for:pointer:) -> URL` (35) — 统一组装 <root>/<choice>/<directory??version> 路径（dedup 助手）
  - `static let pointerCacheLock` (46) — 指针缓存互斥锁
  - `static func activePointer(for:) -> ActivePointer?` (56) — 进程级指针缓存读取（含撤销吊销检查与负缓存）
  - `private static func computeActivePointer(for:) -> ActivePointer?` (70) — 读盘解析校验 active.json（hash 格式/撤销/choice/version/directory/manifest 存在性）
  - `static func invalidatePointerCache()` (85) — 安装落盘后失效缓存
  - `static func removeStaleStaging(in:fileManager:)` (92) — 回收 .staging- 崩溃残留暂存目录

## CoreKit/Sources/Infrastructure/AppointmentStore.swift
- `AppointmentStore` (8) — F10 预约仓储：创建/改期/取消 + 四级提醒 + 状态机 + 就诊挂接
  - `enum StoreError` (11) — notFound / invalidState / invalidEncounter
  - `func create(...) -> UUID` (26) — 创建预约 + 反算四级触发点预排（过期层级不补发）
  - `func reschedule(id:startsAt:now:) -> UUID` (61) — 改期：旧行 cancelled+rescheduled、新草稿全字段复制 + 重排提醒
  - `func cancel(id:reason:now:)` (108) — 取消 + 移除全部 pending 提醒
  - `func markMissed(id:now:)` (122) — 标记错过 + 取消分级提醒 + 排 2h 跟进
  - `func complete(id:now:)` (154) — 仅 scheduled 可完成 + 补录复诊就诊 + 回写 encounter_id
  - `private func cancelReminders(id:)` (198) — 按前缀清 apt- / apt-followup- / followup-apt- 提醒
  - `func upcoming(patientId:now:)` (215) — 待就诊列表投影
  - `func history(patientId:limit:)` (227) — 状态机历史（四态）
  - `func link(appointmentId:encounterId:purpose:patientId:now:)` (243) — 显式挂接就诊（同成员校验 + 审计）
  - `func unlink(appointmentId:patientId:now:)` (260) — 解除挂接（预约保留）
  - `func candidates(forEncounter:patientId:dayWindow:)` (272) — 可挂接候选（±3 天、医院同名）
  - `private static func assertEncounter(_:belongsTo:db:)` (291) — 就诊存在/同成员/未软删守卫
  - `private static func appointmentRow(_:)` (296) — 行 → AppointmentRow 映射
- `AppointmentRow` (308) — 预约行投影（含 v27 encounterId/purpose）

## CoreKit/Sources/Infrastructure/ASRModelAssets.swift
- `ASRModelAssets` (10) — 随包/下载版 ASR 模型资产验证（manifest/文件字节/SHA/授权）
  - `struct Manifest / Model / Archive / Part / File` (11-15) — manifest.json 解码形态
  - `struct Validated` (16) — 校验通过后的 role→路径映射
  - `func checkPackageAuthorization()` (31) — 包哈希撤销检查
  - `var identity: String` (35) — root+代次的缓存键身份
  - `final class Lease` (38) — 目录租约（引用计数，deinit 释放）
  - `private final class Leases` (46) — 目录租约计数表
  - `func acquireLease() -> Lease` (61) — 取租约
  - `static func removeIfUnused(_:)` (62) — 无租约才删除
  - `private final class Generation` (63) — 安装代次计数器（identity 缓存键组成）
  - `static func resolve(for:) -> ASRModelAssets` (75) — 双路径解析：运行时下载版优先，回落随包
  - `private static let presenceCache = LockedCache<Bool>()` (86) — 进程级存在性缓存
  - `private static let manifestCache = LockedCache<Manifest?>()` (88) — 进程级清单解码缓存
  - `private final class LockedCache<Value>` (92) — 锁保护键值缓存泛型（两缓存共用形态）
  - `func isPresent(_:) -> Bool` (107) — 模型文件存在性（缓存 + 撤销检查）
  - `static func invalidateCaches()` (118) — 安装/指针切换后失效 presence/manifest 缓存
  - `func byteCount(_:) -> Int64?` (124) — 模型体积（files 求和，archive 形态回落 archive.bytes）
  - `func validate(_:) throws -> Validated` (145) — 全量校验入口（流式哈希）
  - `private func files(_:hash:) throws -> Validated` (147) — manifest/逐文件字节/SHA 校验核心
  - `private func readManifest(_:) throws -> Manifest` (186) — 读 manifest（resolved 形态验 sourceDigest）

## CoreKit/Sources/Infrastructure/ASRModelDownloadService.swift
- `ASRModelDownloadService` (18) — FR17.15 模型运行时下载/校验/解压/原子切换门面（显式按钮才联网）
  - `enum DownloadMode` (23) — segmented / singleStream 传输形态
  - `struct DownloadProgress` (28) — 进度（含 series 系列代次，fraction 计算）
  - `enum Failure` (43) — 下载安装失败域（11 case）
  - `struct ActivePointer` (57) — active.json 指针值对象（choice/version/directory/artifactRevision/packageSHA256/variant）
  - `var downloader: ModelPackageDownloader` (115) — 协作类转发：分段下载器
  - `static func fetchIndex(from:)` (140) — 拉取根 URL 链 + 目录索引并校验
  - `private func metadata(from:)` (156) — 受信任小体积元数据拉取（URL 白名单/字节上限/委托校验）
  - `enum InstallPhase` (217) — downloading/verifying/unpacking/activating/pruning 阶段
  - `func install(_:baseURL:progress:onPhase:) -> URL` (228) — 下载→校验→解压→包内校验→原子切换主流程
  - `private func pruneOldVersions(modelRoot:newlyInstalled:previousRoot:)` (338) — 按 (家族, 变体) 保留粒度清理旧版本
  - static 转发（applicationSupportRoot/activeRoot/installedVersion/activeAssets/sha256/removeStaleStaging 120-135）→ ActivePointerStore/StreamingFileHasher；`latest/updateAvailable` 187/203 目录条目选择

## CoreKit/Sources/Infrastructure/AudioCaptureController.swift
- `AudioCaptureController` (19) — 三轨共用音频采集控制器（会话快照对称/引擎 tap/PCM 拷贝/观察者）
  - `struct Configuration` (20) — bufferSize + 单块字节上限（standard 与 SpeechSessionLimits 同源）
  - `func start(configuration:onFormat:onBuffer:onFailure:isStopped:)` (40) — 激活采集会话 + 装 tap + 观察者（失败全还原）
  - `func stop()` (98) — 拆除单一出口（幂等）：观察者/引擎/tap/会话快照对称还原
- `AudioBufferCopier` (117) — PCMBuffer 深拷贝工具
  - `static func copy(_:maximumBytes:) -> (buffer:byteCount:)?` (119) — memcpy 逐平面拷贝 + 字节上限校验

## CoreKit/Sources/Infrastructure/AudioSessionTeardown.swift
- （2026-09-18：原空枚举 `AudioSessionTeardown` 已删除，拆除契约以文件头注释承载）
- `AudioSessionCapture` (37) — 采集会话激活单一出口（与拆除契约对称）
  - `struct State` (39) — 采集前会话状态快照（类别/mode/options）
  - `static func remember() -> State` (52) — 记录当前共享会话状态
  - `static func activateRecordSession() throws` (60) — .record+测量+duck 并激活
  - `static func restore(_:)` (67) — 先类别后停用还原快照（失败不阻断主流程）

## CoreKit/Sources/Infrastructure/AuditLogWriter.swift
- `AuditLogWriter` (10) — §5.6 审计日志写入口（白名单 action + entity_id 哈希，append-only）
  - `static let allowedActions` (11) — 白名单 action 集合
  - `enum Action` (25) — 审计动作常量（调用方引用常量防拼写漂移）
  - `func record(action:entityType:entityId:actorLocal:meta:)` (43) — 独立事务写入口
  - `static func insert(action:...:db:)` (54) — 同事务写入口（供关系更新/事实写门复用）
  - `enum AuditError` (67) — actionNotAllowed

## CoreKit/Sources/Infrastructure/AVSpeechAdapter.swift
- `AVSpeechAdapter` (13) — 生产 TTS（回退链在 SpeechFallback，本类只解析 + 播报）
  - `var availableVoices` (23) — 平台可发声 locale（每次现取，语音包可后装）
  - `func speak(_:localeIdentifier:) -> SpeechOutcome` (28) — 按回退链解析并播报
  - `func stop()` (40) — 立即停止

## CoreKit/Sources/Infrastructure/BackupService.swift
- `BackupService` (11) — FR13.11 备份：envelope 序列化 + 二进制信封 + 校验 + 恢复
  - `struct BackupPackage` (19) — 备份包（文件名/数据/校验和/导出时间）
  - `static let binaryMagic` (33) — 二进制信封魔数 VLBU1
  - `struct BackupEnvelope` (35) — 遗留 JSON v0 信封（兼容读取）
  - `enum BackupError` (42) — checksumMismatch / unsupportedFormat / conflictDetected
  - `func createBackup() -> BackupPackage` (48) — 导出 → 哈希 → 二进制信封组装
  - `struct ConflictAnalysis` (69) — 冲突预览 + 已校验 envelope 复用
  - `func analyzeConflicts(from:)` (73) — 解码校验 + 冲突清单（预览→恢复免二次哈希解码）
  - `func restore(envelope:resolutions:) -> Int` (83) — 已校验 envelope 直用导入
  - `func restore(from:resolutions:) -> Int` (98) — 原始 Data 入口（解外层+重算哈希）
  - `private func verifiedEnvelope(from:)` (105) — 双格式解码 + 长度限界 + SHA 比对
  - `static func sha256(_:) -> String` (148) — 收敛 ContentHashing 单实现

## CoreKit/Sources/Infrastructure/CardExtractionRegistry.swift
- `CardExtractionRegistry` (19) — 按卡抽取三轨注册表：有序轨道链/逐区域失败切换/缩范围重试/并集
  - `static let groundingThreshold` (25) — 必填倾向字段锚定率门槛 0.5
  - `func extract(_:) -> [ExtractedCard]` (27) — 整页抽取主入口（页预算/取消传播/逐卡收口）
  - `private func extractRegion(...)` (63) — 单区域跨轨抽取（含缩范围重试与降级登记）
  - `private func degrade(_:in:)` (119) — 首个降级原因登记
  - `private func applyPrescriptionRowSplit(to:)` (130) — 处方合体行后拆分（RuleExtractor 单出口）
  - `private func run(...) -> Outcome` (158) — 单区域单轨调用（超时竞速 + 调用方取消传播）
  - `private func union(_:_:anchor:) -> RegionExtraction` (185) — 两轨 (row,key) 并集

## CoreKit/Sources/Infrastructure/ClaimStore.swift
- `ClaimStore` (9) — FR13.7 报销票据仓储（纯事实聚合，不做报销建议）
  - `struct ClaimRow` (14) — 票据行投影
  - `func create(...)` (31) — 录入发票/费用/收据
  - `func list(patientId:) -> [ClaimRow]` (50) — 按日期倒序列出
  - `struct Totals` (72) — 汇总（总额/条数/币种）
  - `func totals(patientId:) -> Totals` (81) — 纯事实求和（分位四舍五入归整）

## CoreKit/Sources/Infrastructure/CoreImageCompressor.swift
- `CoreImageCompressor` (14) — Apple 生产压缩轨：ImageIO 降采样 + Core Image 模糊 + LAContext
  - `func generateThumbnail(_:spec:) -> Data` (19) — 缩略图/模糊生成（共享 CIContext）
  - `func authorizeOriginalAccess(_:policy:reason:) -> Data` (50) — 敏感原图生物识别门禁

## CoreKit/Sources/Infrastructure/CryptoKitContentHasher.swift
- `CryptoKitContentHasher` (10) — ContentHashing 生产实现（CryptoKit SHA-256）
  - `func sha256Hex(_:) -> String` (13) — 十六进制小写摘要

## CoreKit/Sources/Infrastructure/DocumentStore.swift
- `DocumentStore` (9) — F5 资料库：列表/归档/收藏/去重/入库/确认/OCR 留痕
  - `enum StoreError` (14) — invalidMember/invalidSource/invalidPage/unreviewedField/reviewConflict/invalidDocTypeKey
  - `private static func validateDocTypeKey(_:)` (21) — v27 稳定键校验
  - `private static func validatePages(_:)` (26) — 页清单形态校验（save 复用）
  - `static func validateSource(_:patientId:documentId:pageIndex:requireRecognizedPage:)` (33) — 来源有效性守卫
  - `struct DocumentRow` (43) — 文档行投影（isPendingConfirmation = grade=='D'）
  - `struct Page` (79) — 页语义（ok/failed/skipped）
  - `func list(patientId:includeArchived:limit:)` (96) — 列表（白名单态过滤）
  - `func fetch(id:)` (111) — 单文档（含 meta_json）
  - `func listPending(patientIds:limit:)` (121) — SP-53 跨成员 D 级待确认队列
  - `func setArchived(id:archived:now:)` (141) — 归档/取消（archived_favorite 组合态状态机）
  - `func setFavorite(id:favorite:now:)` (166) — 收藏（对已归档收藏 → archived_favorite）
  - `func duplicates(sha256:patientId:)` (191) — 哈希精确重复检测（不自动删除）
  - `func save(...) -> UUID` (205) — 入库（BR-002 只 INSERT；页/审阅同事务）
  - `func pages(documentId:) -> [Page]` (242) — 文档全部页
  - `func documentsMissingTypeKey(patientId:limit:)` (257) — v27 首启回填读面（分批）
  - `func setDocTypeKey(_:documentId:patientId:now:)` (277) — 稳定键写面（成员校验）
  - `func updateReview(...)` (291) — 复核更新（凭据冻结页文本守卫 + 状态变更持久化）
  - `private static func stageReview(...)` (383) — 草稿卡暂存 + 已确认字段留痕
  - `func confirmText(id:patientId:now:)` (421) — BR-003 D→C 闸门（用户显式确认）
  - `func saveOCRResult(...)` (439) — FR6.1 OCR 留痕（唯一写入口）
  - `private static func row(_:) -> DocumentRow` (466) — 行映射单实现

## CoreKit/Sources/Infrastructure/EmergencyCardStore.swift
- `EmergencyCardStore` (20) — F15 急救卡：逐项选择（FR15.1）+ 已选聚合
  - `func select(patientId:itemId:kind:)` (27) — 选中条目入卡
  - `func deselect(patientId:itemId:)` (38) — 移除条目
  - `func candidates(patientId:) -> EmergencyCard` (49) — 全部候选（不含选择态）
  - `func selected(patientId:) -> EmergencyCard` (61) — 已选集合（同事务取齐快照一致）
  - `private static func allergyCandidates / medicationCandidates / healthProblemCandidates / contactCandidates` (88/105/121/134) — 四候选查询（confirmed 语义逐源定义）
  - `func bloodType(patientId:) -> String?` (150) — 血型随卡带出（软删成员排除）

## CoreKit/Sources/Infrastructure/EncounterStore.swift
- `EncounterStore` (9) — F4 就诊仓储：字段全集/资料挂接/懒创建/推荐
  - `struct EncounterRow` (14) — 就诊行（含 v25 五叙事列 + linkedDocumentIds）
  - `func upsert(encounter:now:) -> UUID` (53) — 新建/更新（全量覆盖语义）
  - `func list(patientId:limit:)` (91) — 列表（软删过滤）
  - `func get(id:)` (100) — 单就诊
  - `struct LinkedCardRow` (112) — 关联卡片投影（Kind 枚举 + cardKind 映射）
  - `func linkedCards(encounterId:patientId:limit:)` (155) — 关联卡清单（单一映射循环/去重/排序）
  - `private struct LinkedCardSource` (175) — 关联卡数据源规格（kind+sql+args）
  - `private static func linkedCardSources(...)` (181) — 处方/收费/五类直查 + 四类投影（机械表）
  - `private static func firstLine(_:) -> String` (269) — 摘要首行截断
  - `func linkDocument(documentId:encounterId:now:)` (276) — 资料挂接（同成员守卫 + 审计）
  - `func unlinkDocument(documentId:)` (291) — 解除挂接（资料保留）
  - `struct LinkedDocument` (301) — 已挂资料投影
  - `func linkedDocuments(encounterId:patientId:)` (306) — 已挂资料清单
  - `func recommendDocuments(encounter:now:) -> [UUID]` (329) — ±7 天孤立资料推荐（标待确认）
  - `func unconfirmedFields(patientId:)` (358) — BR-003 D 级资料清单（title 而非计数）
  - `enum StoreError` (371) — documentNotFound
  - `private static func rows(...)` (376) — 批量行映射（单次 GROUP 取关联防 N+1）

## CoreKit/Sources/Infrastructure/EngineFactories.swift
- `OCRRecognizerFactory` (7) — OCR 引擎工厂（Vision / Linux 契约桩）
- `SpeechSynthesisFactory` (22) — TTS 工厂（AVSpeechAdapter；`currentSpeechRate` 46 读冻结键）
- `TranscriptionEngineBuilder` (68) — 语音输入档位→引擎唯一构建出口
  - `static func automaticChoice(locale:)` (76) — auto 解析（资产闸门两级回落）
  - `static func fallbackForMissingBundledModel()` (89) — 缺件回落平台轨/基线轨
  - `static func make(choice:)` (99) — 档位→引擎（显式选定缺件不得换引擎冒充）
  - `private static let baselineCapabilitySnapshot` (136) — 基线轨能力进程级快照
  - `static func automaticCapability()` (138) — auto 档能力并集
  - `static func make(rawChoice:)` (156) — 冻结键读取版本
  - `static func availability(of:)` (161) — 档位可用性（三态：可用/可下载/缺件）
  - `static func installableLocales(of:)` (186) — 平台轨可下载语言清单
- `TranscriptionEngineFactory` (198) — 语音输入工厂（热切换代理）
- `ImagePreprocessingFactory` (220) / `ImageDecodingFactory` (234) / `ImageCompressingFactory` (248) — 预处理/解码/压缩工厂
- `TextUnderstandingFactory` (265) — 共享文本理解工厂（主轨+NL 兜底）
- `CardExtractionFactory` (277) — 按卡抽取注册表工厂（T1/T2/T3 链）
- `extension EngineRegistry.registerDefaultEngines()` (300/307) — 默认引擎 if-absent 批量注册

## CoreKit/Sources/Infrastructure/EntitlementStore.swift
- `StorefrontProviding` (12) — StoreKit 交易源端口（生产=StoreKit 2，测试=桩）
- `EntitlementStore` (20) — 权益持久化 + AI 月度配额计数
  - `static func monthKey(_:) -> String` (31) — 配额月份键 yyyy-MM
  - `static func parseUsage(_:for:) -> Int` (38) — 解析 aiMonthlyUsed（JSON/旧纯数字双形态）
  - `func state() -> EntitlementState` (49) — 已购集合 + 当月用量
  - `func purchase(_:) -> Bool` (62) / `func restore()` (66) — 购买/恢复转发
  - `func recordAIUse()` (70) — 月度计数 +1（单键 upsert）
  - `actor InMemoryStorefront` (89) — 测试桩（内存已购集合）

## CoreKit/Sources/Infrastructure/ExportService.swift
- `ExportService` (9) — F13 导出管线：JSON 往返（版本 envelope）+ CSV；ADR-019 冲突裁决
  - `struct Envelope` (15) — 版本化导出信封（35+ 数组字段；`totalRecords` 83 计数）；内嵌 19 个 Export 值对象（DocumentExport 99 / PageExport 136 / OCRPrescriptionExport 145 / PrescriptionLineExport 170 / ClaimLineExport 206 / OCREncounterDetails 229 / OCRMedicationExport 243 / ClaimExport 254 / PlanExport 275 / AppointmentExport 293 / ReminderExport 310 / ObservationExport 331 / AllergyExport 355 / EncounterExport 374 / MetricExport 402 / AlertEventExport 438 / ImmunizationExport 449 / VoiceNoteExport 464 / HealthProblemExport 472，init 508）
  - `func exportJSON() -> Envelope` (549) — 全量导出（约 30 段表投影的机械序列 + validateOCRBackup 收口）
  - `struct ConflictItem` (939) / `enum ConflictResolution` (951) — ADR-019 冲突条目与裁决枚举
  - `func conflictReport(_:) -> [ConflictItem]` (958) — 冲突预览（表级 add 循环 + 字典化标题）
  - `private static func decodeRows<T>(_:_:)` (1108) — 行→镜像值类型（损坏拒收）
  - `func importJSON(_:resolutions:)` (1120) — 导入主事务（FK 拓扑序 1200+ 行：冲突检测 24 表同构、三路裁决 adoptOrSkip、idMap 重写、逐表恢复；需 ImportSession 分解——已登记待办）
  - `enum ExportError` (2345) — conflict / invalidOCRBackup
  - `private static func reviewCardIDs / remapReviewMetadata / documentReference` (2350/2367/2387) — 审阅元数据解析与 id 重映射
  - `private static func validateOCRBackup(_:)` (2395) — 包内校验（主键唯一/父键同成员/枚举/数值有限/回执图）
  - `private static func ocrPages / restoreOCRPages` (2692/2697) — 页导出/恢复助手
  - `private static func validateOCRGraph(_:)` (2720) — 库内 OCR 图校验
  - `private static func decodeMediaIds / encodeMediaIds` (2785/2790) — media_asset_ids JSON 编解码
  - `func encode / decode` (2801/2805) — envelope JSON 编解码
  - `func csv(headers:rows:) -> Data` (2810) — CSV（Domain CSVWriter 复用）

## CoreKit/Sources/Infrastructure/ExtractionOrchestrator.swift
- `ExtractionOrchestrator` (13) — 识别文本→信息卡编排（候选收敛→版面→注册表→续页）
  - `func analyze(lines:pageIndex:documentTypeKey:pageConfidence:allowsGenerativeProcessing:pageBudget:)` (23) — 一页 → [ExtractedCard]

## CoreKit/Sources/Infrastructure/FoundationModelsExtractionEngine.swift
- `ExtractionModelField / ExtractionModelSpan / ExtractionModelResult` (19/28/37) — T1 Generable 解码形态
- `FoundationModelsExtractionEngine` (44) — T1 Foundation Models 轨引擎
  - `func availability(for:)` (49) — 授权/系统可用/互斥锁三闸
  - `func extract(region:spec:request:)` (67) — 生成抽取 + span 装配（出口 await 释放租约）

## CoreKit/Sources/Infrastructure/FoundationModelsUnderstanding.swift
- `OCRModelSpan / OCRModelPage` (9/18) — OCR 主轨 Generable 形态
- `FoundationModelsUnderstanding` (25) — FR17.18 OCR 主轨理解
  - `func isAvailable(for:)` (28) — OCR 源 + 授权 + 文本规模闸
  - `static func splitPrescriptionSpans(_:)` (39) — 处方 drug_name span 后拆分（union 不覆盖）
  - `func understand(_:) -> UnderstandingResult` (53) — 生成→拆分→grounding→结果（1500ms deadline）

## CoreKit/Sources/Infrastructure/GrayscaleImageDecoder.swift
- `GrayscaleImageDecoder` (13) — GrayscaleDecoding Apple 实现
  - `func decode(_:maxDimension:) throws -> GrayscaleImage` (18) — ImageIO 降采样 + CGContext 灰度位图

## CoreKit/Sources/Infrastructure/GRDBCodeIndex.swift
- `GRDBCodeIndex` (18) — F25 医学码表 GRDB 实现（CodeIndex + UnitIndex 双协议）
  - `func loadBundledSeedsIfNeeded()` (29) — 内置种子装载（bundle_version 版本门控幂等）
  - `private static func insertSeeds(_:previousVersion:)` (58) — 升级替换/兜底清理 + 六表种子插入（机械表）
  - `private static func codeResolution(from:)` (142) — 概念行→CodeResolution 唯一映射
  - `func overrideHit(_:)` (152) / `func resolveAlias(_:locale:)` (164) — 覆盖/别名命中
  - `func concept(_:)` (183) / `func unitSpecificConcept(conceptId:unit:)` (195) — 概念读取（单 JOIN 防嵌套读）
  - `func unit(_:)` (211) / `func molarBridge(from:to:conceptId:)` (222) — UCUM 单位/摩尔桥

## CoreKit/Sources/Infrastructure/GRDBPatientPersistor.swift
- `GRDBPatientPersistor` (14) — M1a 生产持久化（owner/consent/成员）
  - `func loadOwner()` (21) — 读 local_owner
  - `func saveOwner(_:profile:)` (33) — 两参形态转发
  - `func saveOwner(_:profile:contact:)` (40) — 本机注册原子流（三段式破环 + 紧急联系人）
  - `func loadConsents()` (78) — 同意记录列表
  - `func saveMember(_:)` (90) / `func members()` (94，走 GRDBStore.profileRow 单实现) — 成员读写
  - `func updateMember(_:)` (106) — FR3.1 字段补全
  - `func saveConsent(_:)` (120) — 普通 INSERT（去重由调用侧）
  - `func databaseHealth()` (141) — 逻辑库大小 + PRAGMA 完整性
  - `func reset()` (151) — UI 测试清态（FK 拓扑序删除清单 50+ 表）

## CoreKit/Sources/Infrastructure/GRDBSearchService.swift
- `GRDBSearchService` (10) — F12 全文搜索（长度路由 trigram/2gram/LIKE）
  - `static let searchableDocPredicate` (15) — BR-003 检索公共谓词（三条路由共用）
  - `func search(_:scope:limit:)` (24) — 路由分派 + 语音速记合并
  - `private static func likeDocHits(...)` (103) — 1 字 LIKE 兜底（90 天窗口 + 通配符转义）
  - `private static func voiceNoteHits(...)` (132) — FR17.14 速记命中
  - `private static func noteTitle(_:)` (157) — 标题首行截断 60 字
  - `private static func hit(_:)` (163) — 命中映射（BR-007/008 敏感行只出标题）

## CoreKit/Sources/Infrastructure/GRDBStore.swift
- `GRDBStore` (17) — M0 装配：连接配置/建库/增量迁移/patient_profile 写
  - `static func configuration()` (27) — FK 开启 + bigrams SQL 函数注册
  - `static func pool(at:)` (40) / `static func inMemory()` (45) — 生产 WAL 池 / 测试内存库
  - `init(writer:)` (59) — 建库（v0 全量 DDL 直达 latest）或增量迁移
  - `private func migrateIncremental(writer:)` (96) — 事务外 FK OFF 迁移 runner（v13/v15 代码步、v25 回填、表重建步）
  - `static func executeIdempotent(_:_:)` (152) — 逐语句执行 + ADD COLUMN 列存在守卫（测试同源）
  - `private static func applyTransactional(_:then:)` (166) — 表重建步：DDL+FK 校验+回填+版本推进同事务
  - `private static func rebuildDoseLogWithFK(_:)` (190) — v13 rename-first 可恢复重建
  - `private static func recomputeLogicalDoseIds(_:)` (241) — v15 逻辑剂量 id 原地重算
  - `private static func moveDoseEvidence / deleteDoseEvidence / deleteEvidenceOfUnresolvedLegacyRows` (369/380/391) — 引用行同步助手
  - `private static func tableExists(_:_:)` (408) — sqlite_master 表存在判定
  - `enum MigrationError` (414) — schemaTooNew / foreignKeysNotReenabled
  - `func insert(profile:)` (430) — patient_profile 全列显式 INSERT
  - `static func profileRow(_:) -> PatientProfile` (452) — 行→档案唯一映射（成员/备份共用）
  - `var foreignKeysOn: Bool` (471) — 运行时 FK 断言

## CoreKit/Sources/Infrastructure/GRDBStore+V25Backfill.swift
- `extension GRDBStore.backfillRecognitionFactLines(_:)` (24) — v25 回执确定性回填（处方行/就诊叙事/票据金额，幂等）
  - `private static func confirmedUnit(_:key:)` (92) — 回执单位原文（无默认，BR-006）
  - `private static func finiteAmount(_:)` (97) — 金额严格解析（NULL 不猜）

## CoreKit/Sources/Infrastructure/GuidelineSource.swift
- `GuidelineSource` (16) — F16 信源库编译期常量（医学数字单一事实源）
  - `static let bundledSeeds` (19) — 内置信源条目（4 条：血糖/血压/血氧/心率，B 级缺省）
  - `static let thresholdsAwaitMedicalReview` (56) — 发布前评审闸门标志
  - `struct Thresholds` (61) — 阈值 JSON 形态（from 75 / applying 80）

## CoreKit/Sources/Infrastructure/GuidelineStore.swift
- `GuidelineStore` (7) — F16 信源库仓储 + 历史评估/合格提醒
  - `func seedBundled()` (12) — 种子装载（幂等 SELECT-WHERE-NOT-EXISTS）
  - `func entry(for:)` (33) / `private static func entry(for:db:)` (37) — 条目读取（DB 优先，回落种子）
  - `func all()` (45) — 全部条目（去重）
  - `private static func decode(_:)` (55) — 行→GuidelineEntry
  - `func evaluateAndRecord(reading:patientId:ruleId:)` (69) — 单次评估+记录
  - `static func recordQualifiedHealthReadings(_:patientId:db:)` (82) — 指标事务内合格判定（持续违规）
  - `private static func save(card:patientId:ruleId:qualified:db:)` (106) — alert_event 幂等保存
  - `func history(...)` (134) / `func event(id:patientId:)` (153) — 历史查询
  - `func markScheduled(id:patientId:at:)` (161) — 标记已排程
  - `private static func decodeEvent(_:)` (170) — 行→AlertEvent
  - `struct AlertEvent` (179) — 事件投影；`enum StoreError` (195)

## CoreKit/Sources/Infrastructure/HealthExamStore.swift
- `HealthExamStore` (10) — v27 体检枢纽只读读面
  - `struct HealthExamDetail` (11) — 表头+子报告+结论+一般检查投影+原件
  - `struct Children` (28) — 体检下子卡清单
  - `func list(patientId:limit:)` (42) — 已确认体检列表
  - `func healthExam(id:patientId:)` (52) — 单张表头（跨成员 invalidCard）
  - `func children(ofHealthExam:patientId:)` (59) — 子卡（检验/检查/结论）
  - `func detail(id:patientId:)` (75) — 详情读面（视图 + 投影点）
  - `private static func exam(id:patientId:db:)` (91) / `private static func conclusions(...)` (97) — 表头/结论查询助手

## CoreKit/Sources/Infrastructure/HealthImportStore.swift
- `HealthImportStore` (6) — HealthKit 导入仓储（绑定/分道锚点/pending 批次/提交）
  - `struct Binding` (7) — 绑定（时区 + connectedAt + calendar）
  - `enum ImportError` (21) — 导入失败域
  - `struct PendingBatch` (26) — 在途批次载荷（分道 lane）
  - `struct CommitReport` (37) — 提交报告
  - `func connect(timeZoneID:)` (47) — 建立绑定（单例行）
  - `func connection()` (69) / `func isEnabled()` (76) — 绑定读取/开关
  - `func scopes(for:)` (85) — 两道回填范围
  - `func anchor(binding:kind:lane:)` (91) / `func pendingBatch(...)` (96) — 锚点/在途批读取
  - `func stage(...)` (104) — 分页暂存（页大小/锚点/在途道守卫）
  - `func affectedWindows(...)` (143) — 受影响窗口
  - `func commit(...)` (156) — 提交物化（窗口完整判定/删除/投影写/锚点推进；~200 行重度不变量，分解待办）
  - `private static func deletedReferences / decodeReference / validatedReferences` (369/383/392) — 引用校验助手
  - `private static func pending / savePending` (405/422) — 在途批读写
  - `private static func validateRow(_:window:visible:)` (430) — 行级校验（指标族键域）
  - `private static func writeProjection(...)` (461) — 投影行 upsert（仅变值改写）
  - `private static func requireBinding / anchorKey / anchor / binding / ownerPatient / requireEnabled` (486-527) — 守卫与键助手

## CoreKit/Sources/Infrastructure/HealthImportStore+Presentation.swift
- `extension HealthImportStore` (9) — 读面扩展
  - `func dashboard()` (12) — 仪表盘（类型摘要 + 最近报告）
  - `func importedRows(kind:before:limit:)` (38) — 导入行分页（游标）
  - `func saveReport(_:)` (77) — 同步报告落盘（绑定守卫）
  - `func automaticImportEnabled()` (89) — 自动同步开关

## CoreKit/Sources/Infrastructure/HealthKitReader.swift
- `HealthKitReader` (9) — 只读 HealthKit 适配器 + 写回（双协议同实例）
  - `enum ReaderError` (16) — unavailable/requestIncomplete/invalidAnchor/incompleteSnapshot
  - `private static func isOwnSample(_:)` (23) — 防回声过滤（本 App 写入样本）
  - `static var readTypes` (28) / `private static func sampleType(_:)` (44) — 读类型集合/映射
  - `static var writeTypes` (58) / `hkQuantityType / hkUnit / hkWriteScale` (63/76/91) — 写回类型/单位/尺度（规则在 Domain）
  - `func requestWriteAuthorization()` (95) / `func writeAuthorizationStatus()` (103) — 写授权（三态如实）
  - `func writeBack(_:) -> Int` (121) — 写回样本（血压相关性合并，单位不符跳过）
  - `func isAvailable()` (164) / `func requestAuthorization()` (166) / `func requestCharacteristicAuthorization()` (178) — 可用性/授权请求
  - `func characteristics()` (189) — 特征型读取（未填如实 nil）
  - `private static func format(blood/sex/components)` (199/214/224) — 特征格式化
  - `func observeChanges(handler:enableDelivery:)` (230) — 后台观察 + 投递开关
  - `func changes(for:scope:anchor:limit:)` (263) — 分道分页增量（防回声 + hasMore 由过滤后批次导出）
  - `func snapshot(for:calendar:)` (309) — 窗口快照（按族分派到四个物化助手）
  - `private static func sleepRows(...)` (355) — 睡眠六键行
  - `private func stepRows(...)` (388) — 步数日累计（验证集同口径比对）
  - `private func heartRateRows(...)` (412) — 心率小时均值（按来源分桶）
  - `private func quantityRows(...)` (446) — 单值族行+读数
  - `private func quantityPoints(_:unit:useEndDate:)` (485) — 压缩序列展开（ordinal 身份）
  - `private func querySamples(for:predicate:)` (512) — 有界分页拉全样本（去重字典）
  - `static func changePredicate(for:)` (539) / `static func stepStatisticsPredicate(...)` (548) — 谓词构造
  - `private static func reference(_:kind:)` (555) — 样本→引用

## CoreKit/Sources/Infrastructure/HealthKitSyncService.swift
- `HealthKitSyncService` (12) — 前/后台/手动导入协调者（inFlight 合并）
  - `func connect()` (33) — 连接（授权+绑定+后台观察）
  - `func characteristics / requestCharacteristicAuthorization / requestWriteAuthorization / writeAuthorizationStatus / writeBack` (46-68) — 特征/写回转发
  - `func connection / dashboard / importedRows / isAvailable` (70-75) — 读面转发
  - `func canAutomaticallySync / canSync` (76/81) — 同步可行性
  - `func cancelSync()` (86) — 取消在途轮次
  - `func performSyncAll(quietStart:quietEnd:maxRounds:timeBudget:)` (95) — 排空轮询 + 多轮报告聚合
  - `func performSync(quietStart:quietEnd:)` (135) — 共享轮次合并（创建者拥有取消权）
  - `private func runAndRecord(id:quietStart:quietEnd:)` (159) — 状态落盘 + 释放 flight
  - `private struct DrainOutcome` (168) — hadWork/hasMore
  - `private func run(quietStart:quietEnd:)` (173) — 轮次主体（逐类型逐道排空 + 合格事件补投递）
  - `private func drain(kind:scope:binding:existing:report:)` (252) — 单道单页排空（取页→暂存→窗口重算→提交）
  - 后台任务组 (292-335)：bgTaskIdentifier / startBackgroundObservation / scheduleBackgroundRefresh / registerBackgroundTask

## CoreKit/Sources/Infrastructure/HealthProblemStore.swift
- `HealthProblemStore` (10) — F11.4 健康问题管理
  - `struct HealthProblemRow` (15) — 问题行
  - `func list(patientId:includeArchived:)` (25) — 列表（归档默认排除）
  - `func create(patientId:name:now:) -> UUID` (41) — 新建/懒创建
  - `func rename(id:to:now:)` (53) / `func setArchived(id:archived:now:)` (61) — 改名/归档
  - `func merge(primary:into:now:)` (71) — 合并（主保留/被并归档，对称存在守卫）
  - `enum StoreError` (93) — notFound / sameProblem

## CoreKit/Sources/Infrastructure/HeavyModelLease.swift
- `HeavyModelLease` (14) — T1/T2 共用模型互斥锁（单飞保证）
  - `static let shared` (15) — 全局单例
  - `func tryAcquire() -> Bool` (20) / `func release()` (27) — 获取/释放
  - `var isOccupied: Bool` (32) — 占用查询

## CoreKit/Sources/Infrastructure/ImmunizationStore.swift
- `ImmunizationStore` (14) — FR4.5/4.6 疫苗接种记录仓储
  - `struct Record` (19) — 接种记录（来源/确认态）
  - `func create(...)` (37) — 录入（手动=C 级，OCR=D 级）
  - `func list(patientId:)` (55) — 按时间倒序列出
  - `func nextDoseNumber(patientId:vaccineName:)` (77) — 下一剂次序号（只建议不判定）

## CoreKit/Sources/Infrastructure/LlamaCppExtractionEngine.swift
- `LlamaCppExtractionEngine` (26) — T2 本机 LLM 轨（llama.cpp 直连 C API）
  - `func availability(for:)` (37) — 授权/模型就绪/互斥三闸
  - `func extract(region:spec:request:)` (50) — GBNF 文法约束抽取（出口 await 释放租约，与 T1 同纪律）
  - `private static func buildPrompt(lines:spec:)` (93) — 防注入指令+编号行合入
- `ModelSpanResult` (99) — T2 输出 JSON 形状
- `LlamaRuntime` (115) — 单实例推理运行时（模型惰性加载跨调用复用）
  - `private final class CancelFlag` (122) — 取消标志盒（锁保护）
  - `func complete(prompt:grammar:modelURL:maxTokens:)` (136) — continuation 桥接 + 取消传播
  - `private func decode(...)` (156) — 阻塞解码段（专用串行队列；逐 token 轮询取消）
  - `private func loadIfNeeded(url:cancelFlag:)` (216) — 惰性加载（URL 未变复用）

## CoreKit/Sources/Infrastructure/LlamaModelManager.swift
- `LlamaModelManager` (9) — Qwen GGUF 模型路径查找/就绪判定/文件校验
  - `modelFileName / bundleSubdirectory / expectedModelBytes` (11/13/15) — 模型常量
  - `static func modelURL(for:)` (18) — 沙盒覆盖位优先，回落随包
  - `static func isModelReady(fileName:)` (26) — 就绪判定（可读）
  - `static func modelSize(fileName:)` (32) — 文件大小（不可寻址=0）

## CoreKit/Sources/Infrastructure/LocalAuthGateUnlocker.swift
- `LocalAuthGateUnlocker` (10) — 门禁系统适配器（每调用新 LAContext）
  - `var isAvailable: Bool` (13) — canEvaluatePolicy 探测
  - `func authenticate(reason:) -> Bool` (18) — deviceOwnerAuthentication 认证

## CoreKit/Sources/Infrastructure/LocalTranscriptRefiner.swift
- `LocalTranscriptRefiner` (15) — FR17.9/17.18 端侧润色（format-only，永不覆盖原文）
  - `timeoutNanos / maximumInputUTF8Bytes` (16/17) — 常量
  - `var isAvailable` (22) — 三层门控（编译期/运行期/授权在 App 层）
  - `func refine(_:localeIdentifier:drugNames:) -> TranscriptRevision` (33) — 单飞 deadline 生成润色
  - `static func makePrompt(original:localeIdentifier:)` (58) — JSON 载荷 prompt 构造
  - `static let instructions` (70) — 润色系统指令（数据非指令通道）
- `TextRefinerFactory` (86) — EAL 第 9 工厂（非 Apple 平台不可用替身）

## CoreKit/Sources/Infrastructure/MedicationPlanComposer.swift
- `UnitOfWork` (10) — §4.2 单事务执行入口（跨聚合写）
  - `func run<T>(_:) -> T` (17) — 同步闭包单事务
- `MedicationPlanComposer` (29) — §4.2 五表原子参考模板 + FR9.15 生命周期
  - `enum ComposerError` (38) — 创建/生命周期失败域
  - `func createMedicationPlan(prescription:plan:initialLot:prescriptionLineId:now:)` (60) — 五表原子创建（BR-003 前置闸门）
  - `func pausePlan / resumePlan` (169/173) — 暂停/恢复（状态机校验）
  - `func endPlan(planId:reason:now:)` (177) — 结束（终态）
  - `func editPlanSchedule(planId:schedule:now:)` (197) — 编辑剂量频次
  - `private func setPlanStatus(...)` (215) — 状态迁移共享实现（active↔paused 白名单 + 事件）
  - `func lifecycleEvents(planId:)` (247) — 计划历史时间轴

## CoreKit/Sources/Infrastructure/MedicationStore.swift
- `MedicationStore` (12) — M1b 用药仓储：计划/批次/双轨扣减/对账/补录
  - `func createPlan / createMedication / createLot` (19/39/52) — 计划/药品/批次写入
  - `func confirmTaken(notifyId:patientId:)` (74) — BR-004 确认服了（幂等 + 转场补差 + 双轨扣减同事务）
  - `func recordAction(notifyId:action:reason:)` (124) — 跳过/忘记/不适/稍后（矩阵扣减）
  - `enum StoreError` (160) — doseNotFound/alreadyResolved/takenMustUseConfirm/notFound
  - `func materializeMissed(now:graceInterval:)` (184) — 零确认补账（整批一事务）
  - `func doseCount(planId:from:to:)` (222) — 已物化剂量行数
  - `func monthlyReport(patientId:from:to:)` (237) — FR9.8.5 两线差异月报（纯事实）
  - `func inventorySummary(patientId:now:)` (269) — 家庭药箱摘要（日当量缓存防 N+1）
  - `struct LotRow` (346) — 批次详情投影
  - `func fetchLot(id:)` (376) / `func updateLot(...)` (400) — 批次读/写
  - `func reconcileLot(lotId:physicalCount:at:note:audit:)` (420) — 盘点归真（审计同事务；audit 开关 2026-09-18 已由假签名 auditSink 诚实化）
  - `static func estimatedDailyUnits(_:unitsPerDose:)` (457) — 日均当量估算（多计划取最大）
  - `struct InventorySummaryItem` (476) — 药箱条目（daysLeft/refillTier）
  - `func materializeWindow(now:calendar:)` (516) — 滚动预排窗口（30 日回溯 + 时区重锚 + 临时表防吞并）
  - `func deliveryFacts(from:to:)` (623) — DoseSource 对账输入
  - `func markAwaitingUser(_:)` (652) — 送达状态置位
  - `func recordTakenAt(...)` (674) — FR9.16 补录（窄/宽/逻辑 id 三路径 + 转场扣减；~165 行重度不变量，分解待办）
  - `private static func logicalDose(...)` (844) — 补录时段→逻辑剂量身份
  - `func expiringLots(patientId:within:now:)` (865) — FR9.11 到期分级数据源
  - `struct PlanRow` (895) — 计划投影（isUnreadable 降级标记）
  - `struct DoseLogRow` (923) — 剂量日志行
  - `func plans(patientId:)` (940) / `func plan(id:)` (954) — 计划列表/详情
  - `private static func planRow(_:)` (969) — 行→PlanRow 唯一映射
  - `func doseLog(planId:from:to:)` (994) — 日程条数据
  - `func adviceForMedication(medicationId:)` (1018) — FR9.9 医嘱原文（stock_lot 关联）
  - `func recordDelivery(...)` (1033) — FR9.18 送达记录（幂等）
  - `func familyPendingDoses(from:to:)` (1053) — FR24.5 跨成员待确认聚合
- `FamilyPendingDose` (1082) — 家庭待确认剂量投影
- `applyResolutionOnLots(patientId:medicationId:notifyId:units:at:action:transitionMatrix:db:)` (1102) — FR9.8.2 扣减矩阵落库（FEFO 分配 + 双轨账本 + 累加式 upsert；自由函数供事务闭包内调用）


## CoreKit/Sources/Protocols/Transcribing.swift
- `TranscriptionEngine` (15) — F17 语音转写端口（音频零落盘类型级保证 + ADR-023 双轨门控）
  - 需求（一处列出）：`capability`(16) 能力快照 / `currentCapability()`(18) / `transcribe(_:onPartial:)`(20) 一次转写 / `finish(sessionID:)`(24) 限时排空停止 / `cancel(sessionID:)`(26) 取消并结算 / `discardSession(sessionID:)`(28) 废弃会话 / `endAudio()`(30) 旧无作用域停止 / `localeAssetStatus(_:)`(34) 端侧资源状态 / `prepareLocale(_:)`(38) 显式下载安装（唯一联网入口）/ `warmUp(_:)`(44) 预热（零联网）
- `TranscriptionCaptureReporting` (48) — 可报告真实硬件启动时点的引擎（onCaptureStarted 重载）
- `UnavailableTranscriptionEngine` (53) — 恒抛 engineUnavailable 替身
- `extension TranscriptionEngine` (61) — 默认实现（finish→endAudio、能力表派生资产状态、prepare/warmUp=false）
- `StubTranscriptionEngine` (78) — 测试/预览脚本化 actor 桩

## CoreKit/Sources/Protocols/TextUnderstanding.swift
- `TextUnderstanding` (9) — FR17.18 共享文本理解端口（识别后文本→D 级草稿+去向；取消沿链抛）
  - 需求：`understand(_:)`(16) / `isAvailable(for:)`(17)；extension 默认 isAvailable=true (20)

## CoreKit/Sources/Protocols/TextRefining.swift
- `TextRefining` (8) — FR17.9/18 端侧润色端口（永不覆盖原文；EAL onDeviceOnly）
  - 需求：`isAvailable`(10) / `refine(_:localeIdentifier:drugNames:)`(12)
- `UnavailableTextRefiner` (16) — 不可用替身（效果=原文）
- `RefinementDeadline` (26) — 单飞 + 超时护栏并发原语（slot 保留至工作线程与取消投递双退出；生产级实现位于 Protocols 层——分层可议）
  - `func run(original:timeout:operation:)`(32) / `private reserve/release`(47/55) / 内嵌 `Request` 类 (61)：start/finish/didDeliverCancellation/takeReleaseIfFinished (79/111/156/165)

## CoreKit/Sources/Protocols/SpeechSynthesizing.swift
- `SpeechSynthesizing` (11) — TTS 端口（发声回退链单一实现点）
  - 需求：`speak(_:localeIdentifier:) -> SpeechOutcome`(14) / `stop()`(15)
- `RecordingSpeechSynthesizer` (19) — 记录桩（锁保护 spoken 数组）

## CoreKit/Sources/Protocols/SensitiveAssetStoring.swift
- `SensitiveAssetStoring` (11) — F8.4 敏感媒体资产仓端口（BR-007/008：双产物+模糊只读+对账+清空）
  - 需求：`savePhoto(_:memberId:)`(13) / `blurData(for:memberId:)`(15) / `originalData(for:memberId:)`(19) / `removePhoto(_:memberId:)`(21) / `reconcileUnreferenced(validAssetIds:)`(24) / `wipeAllFiles()`(28)

## CoreKit/Sources/Protocols/ReminderScheduling.swift
- `ReminderScheduling` (7) — 通知调度端口（注入桩验证；route 深链 Codable）
  - 需求：`schedule(dose:at:route:)`(11) / `scheduleRepeating(...)`(14，默认回落一次性) / `cancel(_:)`(16) / `pending()`(18) / `delivered()`(20) / `removeDelivered(_:)`(23) / `reloadLocalizedContent()`(26)；extension 默认实现 (29)
- `DoseSource` (39) — 剂量事实源（对账输入）：`deliveryFacts(from:to:)`(40) / `markAwaitingUser(_:)`(41)
- `InMemoryReminderScheduler` (45) — 内存桩（routeMap 测试可查 + simulateDelivery/simulateRestart）

## CoreKit/Sources/Protocols/Persistence.swift
- `AuditLogging` (16) — 审计日志写入（append-only）：`record(action:entityType:entityId:actorLocal:meta:)`(18)
- `InventoryScanner` (26) — 铝箔板盘点占位端口（恒 D 级）：`scanBlisterCount(_:)`(28)
- `BlisterScanResult` (31) — count + autoConfirmed 恒 false
- `StubInventoryScanner` (38) — 脚本化桩
- 备注：本文件两职责域（审计 + 盘点）共居——建议拆分文件（协议内聚性）

## CoreKit/Sources/Protocols/PatientPersisting.swift
- `PatientPersisting` (7) — M1a 持久化端口（owner/consent/成员/健康/清态）
  - 需求：`loadOwner()`(8) / `saveOwner(_:profile:)`(9) / `saveOwner(_:profile:contact:)`(12) / `saveMember(_:)`(14) / `members()`(15) / `updateMember(_:)`(17) / `loadConsents()`(18) / `saveConsent(_:)`(19) / `databaseHealth()`(22) / `reset()`(24)
- `ImageTextRecognizing` (29) — FR12.11 图片文字识别端口（零落盘）：`recognize(_:)`(31)
- `StubImageTextRecognizer` (35) — 脚本化桩
- `extension PatientPersisting` (45) — saveOwner(contact:) 默认=两参形态
- 备注：患者持久化与 OCR 识别两域共居——建议拆分文件

## CoreKit/Sources/Protocols/HealthWritingProvider.swift
- `HealthWritingProvider` (11) — 写回 Apple 健康端口（分享权限可观察）
  - 需求：`requestWriteAuthorization()`(14) / `writeAuthorizationStatus()`(16) / `writeBack(_:) -> Int`(19)
- `HealthWriteAuthStatus` (23) — granted/denied/notDetermined 三态
- `HealthWriteError` (29) — unavailable/requestIncomplete/failed

## CoreKit/Sources/Protocols/HealthReadingProvider.swift
- `HealthReadingProvider` (4) — 只读健康端口（读取权限不可观察纪律）
  - 需求：`isAvailable()`(5) / `requestAuthorization()`(6) / `changes(for:scope:anchor:limit:)`(8) / `snapshot(for:calendar:)`(9) / `characteristics()`(13) / `requestCharacteristicAuthorization()`(16)；extension 默认实现 (19)

## CoreKit/Sources/Protocols/EngineAbstraction.swift
- `EngineContext` (15) — 运行时上下文（platform/onDeviceOnlyRequired/probeLocales；current 34 编译期判定）
- `EngineFactory` (50) — 可替换引擎工厂契约：`associatedtype Capability`(51) / `make(_:)`(53) / `onDeviceOnly`(55)
- `EngineError` (60) — offlineViolation/notRegistered
- `EngineRegistry` (65) — 中央引擎注册表（NSLock 保护；register/registerIfAbsent/resolve/isRegistered/assertOfflineOnly 82-135）

## CoreKit/Sources/Protocols/ContentHashing.swift
- `ContentHashing` (10) — 内容哈希端口（ADR-025 CryptoKit 迁移）：`sha256Hex(_:)`(12)

## CoreKit/Sources/Protocols/CardExtraction.swift
- `EngineAvailability` (11) — available / unavailable(DegradedReason)
- `ExtractionEngineError` (13) — unavailable/modelBusy/schemaMismatch
- `CardExtractionEngine` (16) — 三轨同一端口：`track`(17) / `regionTimeout`(18) / `availability(for:)`(19) / `extract(region:spec:request:)`(20)
- `StubCardExtractionEngine` (24) — 契约桩（脚本化区域结果，恒可用）

## CoreKit/Sources/Infrastructure/OCRCardStore.swift
- `OCRCardStore` (7) — FR6.9/BR-001/BR-003 原子确认边界 actor：OCR 卡确认/回执/审计的唯一写入口
  - `supportedKinds` (10) — 可确认落库卡类 = CardKindRegistry 全部条目（单一事实源）
  - `singleRowKinds` (13) — 单行卡类集合（一张卡恰一行）
  - `auditEngine` (14) — 审计 JSON 引擎版本号（ocr-card-v22）
  - `writer` (15) — GRDB DatabaseWriter（共享连接池）
  - `init(writer:)` (17) — 注入数据库写口
  - `factTable(for:)` (23) — 卡类 → 表头事实表（未注册退回卡类名）
  - `lineTable(for:)` (30) — 卡类 → 行表（注册表登记的父键行实体表）
  - `lineParents` (35) — 行表 → 父表/父键（DDL 事实，可安全拼 SQL）
  - `ReceiptScope` (43) — 回执定位谓词（SELECT/UPDATE 共用）
  - `receiptScope(kind:headerId:patientId:)` (48) — 构造表头回执 ∪ 行回执/检验行回执的谓词
  - `receiptArguments(_:_:)` (64) — 拼接回执查询参数
  - `headerId(of:db:)` (69) — 回执行 → 所属表头 id（行回执经父键回到表头）
  - `existingHeader(receipts:db:)` (78) — 校验卡的全部回执回到同一表头并返回
  - `SaveResult` (85) — 保存结果：剩余卡/写入行数/是否完结/pending id
  - `StoreError` (93) — 卡仓错误枚举（invalidCard/pendingIdentityMismatch/corruptReceipt 等）
  - `ReviewState` (99) — 复核态：卡 + 剩余 + 是否有已提交行
  - `remainingCard(for:)` (106) — 取该 pending 的剩余卡（复核弹窗数据源）
  - `reviewState(card:patientId:documentId:)` (116) — 恢复最近草稿或已提交审计（复核前装载）
  - `AuditRecord` (150) — 回执审计记录（备份表示，含实体表/就诊投影）
  - `sourceRefs(entityId:patientId:cardKind:)` (169) — 表头的全部来源页引用
  - `save(card:patientId:documentId:pendingCardId:)` (185) — 原子确认写入：装载→分区→逐卡事实→回执收尾四步单事务
  - `DraftLoad` (227) — 第一步装载产物：pending/previous/receipts/committed/snapshot
  - `loadDraft(card:patientId:documentId:pendingCardId:db:)` (235) — 第一步：pending 同源校验 + mergeDraft/无草稿重放归一
  - `WritePlan` (298) — 第二步分区产物：接受/残行/缺项/投影卡/快照/写入状态
  - `FactWriteState` (308) — 行→实体/行→回执表/就诊与体检归属的写入期状态
  - `planWrites(snapshot:committed:card:patientId:documentId:db:now:)` (316) — 第二步：接受残行分区 + 枢纽裁定 + .newHub 草稿先落主卡
  - `writeFacts(kind:card:receipts:committed:plan:patientId:documentId:db:now:)` (367) — 第三步分发：行卡/单行卡两助手
  - `writeRowFacts(...)` (382) — 行卡事实写入：metric_sample/prescription/claim_item/diagnosis/clinical_conclusion
  - `writeSingleRowFacts(...)` (602) — 单行卡事实写入：encounter/medication/immunization/hospitalization/exam_report/health_exam/surgery/treatment_record
  - `finalizeSave(...)` (730) — 第四步收尾：回执+审计 JSON → pending 快照更新 → 文档投影刷新
  - `encounterCandidates(patientId:)` (763) — 归属候选就诊列表（最近 500 条）
  - `validateAssociation(_:patientId:db:)` (775) — 就诊归属校验（同成员、未软删；.newHub → nil）
  - `validateHealthExamAssociation(_:patientId:db:)` (791) — 体检枢纽归属校验（同成员、已确认）
  - `refreshDocumentProjection(documentId:patientId:db:now:)` (798) — 重算文档已确认投影（ocr_text/grade/标题建议，FTS 触发器同源）
  - `mergeDraft(_:previous:committed:)` (834) — 新草稿与已提交审计的合并（重放归一）
  - `insertReceipt(_:db:)` (865) — 回执行 + ocr_result 审计 JSON 同事务写入
  - `validateReceipt(_:db:)` (884) — 回执完整性校验（来源页/实体存在/同成员/行回执经父表）
  - `normalized(_:)` (953) — 文本列比对口径：trim 后空串视同 NULL
  - `freeOrdinal(table:parentColumn:header:preferred:db:)` (960) — 行序分配：优先卡内原序，占用退回 MAX+1
  - `insertPrescriptionLine(_:db:)` (969) — prescription_line 全列 INSERT
  - `prescriptionLine(from:)` (987) — 处方行 Row → Domain 实体
  - `factColumns(_:)` (1006) — 处方行事实列投影（再确认比对，provenance 列不比）
  - `prescriptionHeaderMatches(_:_:)` (1015) — 已提交处方表头列与意图一致判定
  - `prescriptionLinesMatch(_:header:patientId:db:)` (1028) — 已提交处方行事实列比对
  - `insertClaimLine(_:header:patientId:ordinal:page:now:db:)` (1039) — claim_line INSERT（行 id = 回执 row_id）
  - `factColumns(_:)` (1052) — 费用行意图事实列投影
  - `factColumns(claimLine:)` (1059) — 费用行 Row 事实列投影
  - `claimHeaderMatches(_:_:)` (1066) — 已提交票据表头列与意图一致判定
  - `claimLinesMatch(_:header:patientId:db:)` (1080) — 已提交费用行事实列比对
  - `exportCommits(_:)` (1090) — 回执 + 审计 JSON 对照导出（备份表示，逐键校验）

## CoreKit/Sources/Infrastructure/OCRCardStore+ClinicalEpisodes.swift
- `OCRCardStore` 扩展 (8) — v26 临床事件（住院/诊断/检查/检验）写入助手与行解码
  - `HospitalizationOutcome` (9) — 住院落库产物：实体 id + 就诊 id
  - `saveHospitalization(_:patientId:documentId:associatedEncounter:db:now:)` (19) — 住院卡落库：显式归属补空/无归属新建就诊+住院期
  - `hospitalizationFacts(_:)` (79) — hospitalization 事实列（DDL 同序，normalized）
  - `ensureLabReport(_:card:patientId:documentId:encounterId:db:now:healthExamId:reportSource:)` (94) — 检验表头幂等建/补（source_card_id 键）
  - `insertLabResult(_:db:)` (142) — lab_result 全列 INSERT（结果/参考范围一律原文）
  - `insertDiagnosis(_:db:)` (156) — diagnosis 全列 INSERT
  - `insertExamReport(_:db:)` (169) — exam_report 全列 INSERT（含 v27 报告来源/体检回指）
  - `hospitalization(from:)` (191) — 住院行 → 实体
  - `diagnosis(from:)` (209) — 诊断行 → 实体
  - `examReport(from:)` (221) — 检查报告行 → 实体
  - `labReport(from:)` (238) — 检验表头行 → 实体
  - `labResult(from:)` (257) — 定性行 → 实体
  - `LabSampleRow` (269) — 检验数值行读面（原始名/值/单位/参考范围/异常标记原文）
  - `labSampleRow(from:)` (281) — metric_sample 医院行 → LabSampleRow
  - `labRowsMatch(_:receipts:patientId:db:)` (291) — 已提交检验行逐列比对（provenance 列不比）
  - `diagnosesMatch(_:patientId:db:)` (316) — 已提交诊断行比对
  - `dateString(_:)` (331) — REAL 日期列 → yyyy-MM-dd（详情读面，App 层再本地化）

## CoreKit/Sources/Infrastructure/OCRCardStore+HealthExam.swift
- `OCRCardStore` 扩展 (12) — v27 卡层级（体检枢纽/结论/手术/治疗）写入助手与行解码
  - `ConclusionParent` (14) — 结论行的恰一父键（表/列/id）
  - `insertEncounter(_:patientId:db:now:)` (23) — encounter 全列 INSERT（就诊卡与主卡草稿共用）
  - `ensureHealthExam(_:documentId:db:now:)` (43) — 体检表头幂等建/补（(patient, document) 键）
  - `healthExamFacts(_:)` (78) — health_exam 事实列（一般检查一律原文）
  - `conclusionParent(healthExamId:patientId:documentId:db:)` (91) — 结论卡父裁定：体检枢纽优先，再唯一检验/检查表头
  - `insertClinicalConclusion(_:db:)` (108) — clinical_conclusion 全列 INSERT（三外键恰一非空）
  - `insertSurgery(_:db:)` (129) — surgery 全列 INSERT
  - `surgeryFacts(_:)` (148) — surgery 事实列（编码/级别/植入物原文）
  - `insertTreatmentRecord(_:db:)` (157) — treatment_record 全列 INSERT
  - `treatmentFacts(_:)` (178) — treatment_record 事实列
  - `healthExam(from:)` (186) — 体检行 → 实体
  - `clinicalConclusion(from:)` (202) — 结论行 → 实体
  - `surgery(from:)` (214) — 手术行 → 实体
  - `treatmentRecord(from:)` (234) — 治疗行 → 实体
  - `clinicalReportSummary(from:)` (252) — v_clinical_report 视图行 → 读模型
  - `conclusionsMatch(_:patientId:db:)` (269) — 已提交结论行比对

## CoreKit/Sources/Infrastructure/OCRCardStore+Links.swift
- `OCRCardStore` 扩展 (6) — 详情读面 / 行详情 / 反查 / 改挂就诊
  - `SourcePage` (7) — 来源页标识（documentId#pageIndex）
  - `CardDetail` (13) — 已确认卡详情读面（字段/来源/就诊/各专有子读面）
  - `LabReportDetail` (42) — 检验报告读面（表头 + 数值行 + 定性行）
  - `detailKinds` (49) — 只读详情卡类 = 可确认卡类 ∪ lab_report
  - `receiptCardKind(forDetailKind:)` (52) — 详情卡类 → 回执 card_kind 折算
  - `LineDetail` (56) — 处方行详情（行 + 表头卡 + 来源页）
  - `detailColumns(kind:)` (65) — 表头 TEXT 列 → 详情字段目录（注册表派生 + 键→列重命名）
  - `labReportColumns` (95) — 检验表头列 → 详情字段目录
  - `detail(kind:entityId:patientId:)` (102) — 详情读面 actor 入口
  - `detail(kind:entityId:patientId:db:)` (109) — 详情组装：事实行 + 回执来源 + 专有子读面
  - `relationshipLockedKinds` (230) — 不可改挂就诊的卡类
  - `receipts(kind:headerId:patientId:db:)` (234) — 表头+行回执统一取回（detail/sourceRefs 共用）
  - `pendingCount(kind:headerId:patientId:db:)` (243) — 表头回执范围内活跃待办卡数（detail/associate 共用）
  - `labReportDetail(reportId:patientId:db:)` (252) — 检验报告聚合读面（数值+定性两表 UNION 语义）
  - `lineDetail(lineId:patientId:)` (264) — 处方行详情（成员隔离，不泄露存在性）
  - `cards(documentId:patientId:)` (280) — 原件全部已确认实体卡反向导航（行回执折叠表头）
  - `associatedEncounters(documentId:patientId:)` (317) — 原件关联的全部就诊
  - `associate(kind:entityId:patientId:encounterId:)` (347) — 改挂就诊（事实表 + 全部回执同事务）
## CoreKit/Sources/Infrastructure/TrendQueryStore.swift
- `TrendQueryStore` (9) — F7 指标趋势查询 actor：成员隔离、排除点软删、A 级参考带、换算只查不写
  - `writer` (10) — 数据库写口
  - `QueryError` (15) — 查询错误：设备过滤非本人拒绝
  - `sampleColumns(valueColumn:refProjection:)` (19) — 趋势点统一 SELECT 列清单（series/sleep/latestPoints 单一出口）
  - `noReferenceColumns` (27) — 舒张压分支参考范围 NULL 投影（BR-003 同族防错标）
  - `referenceColumns` (28) — 常规参考范围投影列
  - `series(_:libraryFallback:)` (34) — 趋势序列查询（携身份回传；舒张压并查独立行）
  - `trendPoint(_:)` (98) — 行 → 趋势点唯一映射出口
  - `series(for:metric:range:libraryFallback:)` (120) — 全来源兼容包装
  - `sleepSeries(_:)` (135) — 睡眠整合查询（六键一趟取回）
  - `setExcluded(_:patientId:excluded:)` (173) — 成组排除/恢复（单事务，成员隔离）
  - `setExcluded(_:patientId:excluded:)` (183) — 单点排除/恢复
  - `addSample(patientId:metric:value:secondaryValue:unit:measuredAt:sourceRef:)` (195) — 自测/手输入库（C 级 + selfMeasured）
  - `addHospitalSamples(patientId:documentId:pageIndex:samples:)` (216) — 检验卡确认 → 医院来源行（A 级参考范围随行）
  - `insertHospitalSample(_:id:patientId:sourceRef:db:now:approvedCodingSystem:labReportId:healthExamId:)` (234) — 医院样本单行写入（编码/表头/体检回指校验）
  - `validateHospitalSample(_:)` (271) — 医院样本域校验（有限值/键非空/参考范围低≤高）
  - `addDeviceSamples(patientId:rows:)` (292) — 设备读数落库（幂等 upsert，单事务）
  - `upsertDeviceRows(_:patientId:db:)` (300) — 设备行「先查后插」幂等（source_ref 或 (键,时刻,单位,来源) 定位）
- `TrendQueryStore` 扩展 (358) — 指标宫格数据源
  - `LatestMetric` (359) — 每指标最新点读面（宫格大数字）
  - `latestMeasuredAt(patientId:metric:origin:)` (396) — 任意窗口最近读数时间（诊断性空态）
  - `latestPoints(patientId:metric:limit:)` (438) — 最近 N 条可见读数（语音播报，LIMIT 走索引）
  - `hasDeviceSamples(patientId:)` (469) — 是否存在任何设备读数（SP-13 未连接空态）
  - `latestPerMetric(patientId:)` (479) — 每键一行最新点（窗口函数一次扫描；BR-001 设备行过滤）

## CoreKit/Sources/Infrastructure/TimelineQueryStore.swift
- `TimelineQueryStore` (11) — F11 时间轴联合查询 actor：八类事件投影，游标分页 d DESC/id DESC
  - `entries(for:filter:cursor:limit:)` (16) — 平铺时间轴（单条 UNION ALL 全局排序 + LIMIT 精确取页）
  - `hubPage(patientId:filter:cursor:limit:)` (141) — 主卡+折叠子卡分页（主卡 UNION ALL + 子卡批取 + Domain 分组）
  - `hubs(for:filter:cursor:limit:)` (182) — hubPage 旧名兼容
  - `entry(_:member:)` (190) — 统一列形态 → 时间轴条目（entries/hub 唯一映射出口）
  - `hubBranches` (204) — 主卡分支 SQL（就诊带住院态 / 体检）
  - `labReportReceiptLinked` (235) — 检验表头经回执挂就诊判定片段
  - `documentHubLinked` (242) — 原件已挂就诊/体检判定片段
  - `leaves` (249) — 叶子分支表驱动描述（19 条：kind/表/列/extra 谓词）
  - `leafBranch(_:)` (302) — Leaf → 同形 SELECT（游标谓词下推）
  - `childSources(encounterIds:examIds:member:)` (312) — 子卡源：FK 直连 ∪ 回执关系投影（按 id 生成 IN 列表）

## CoreKit/Sources/Infrastructure/SchemaMigrations.swift
- `SchemaMigrations` (20) — 迁移版本序列（user_version 单一账本，只许末尾追加）
  - `Step` (22) — 迁移步：目标版本/名称/幂等 SQL/事务性/FK 校验表
  - `Step.version/name/sql/transactional/fkCheckTable` (24-37) — 步字段与默认参数 init
  - `baselineVersion` (45) — baseline（v1）= SchemaV2.ddl 全量建表
  - `steps` (48) — 追加式步序列 v2–v30（22 条有 SQL 的步 + v13/v15/v17 代码步占位；每条带名字如 metric-reference-band / clinical-episodes / card-hierarchy）
  - `latestVersion` (847) — 账本目标版本 = max（防回退）
  - `pending(from:)` (850) — current 之后所需的升序步列表
  - `addColumnParts(_:)` (858) — ALTER TABLE ADD COLUMN 语句 → (表, 列)（幂等守卫用）
  - `statements(_:)` (886) — 多语句 SQL 切分：字符扫描、字符串/注释内分号不作边界、触发器 BEGIN…END 配对

## CoreKit/Sources/Infrastructure/SchemaV2.swift
- `SchemaV2` (25) — v2 全量建表基线（tech-spec §4.3 DDL 摘录）
  - `ddl` (26) — 全量建表 SQL 常量（~50 表 + 索引 + FTS 虚表与触发器 + v_clinical_report 视图，带 § 锚注释）

## CoreKit/Sources/Infrastructure/MigrationEngine.swift
- `MigrationOutcome` (5) — 迁移结果：迁移数 / 只读降级
  - `case migrated(count:) / degraded` (6-7) — 成功计数 / 损坏 JSON 降级
- `MigrationEngine` (10) — v1(flutter JSON) → v2 迁移引擎
  - `migrate(recordsJSON:)` (11) — LegacyRecord 数组解码计数
  - `schemaV1` (22) — 旧名兼容引用（语义 = SchemaV2.ddl）

## CoreKit/Sources/Infrastructure/PendingCardStore.swift
- `PendingCard` (16) — 待办卡读取值对象（status: pending/in_progress/resolved/expired/archived）
  - `matchedCard()` (60) — 待办卡 → 复核 MatchedCard（无来源文档拒绝）
- `IncompleteField` (69) — incomplete_fields JSON 行形态（键/行/标签/原文/置信度/原因）
- `PendingCardDraft` (89) — 建卡入参（两个 init：Payload 与旧字典兼容）
- `PendingCardStore` (124) — FR6.9 待办卡仓：建卡/查询/生命周期推进/级联移除（BR-003 表级排除）
  - `upsert(_:)` (134) — actor 建卡入口（同源去重复用快照）
  - `upsert(_:db:now:)` (138) — 同源去重/OCR 守卫/快照合并的写侧实现
  - `list(patientId:statuses:)` (231) — 成员待办卡列表
  - `markResolved(id:by:note:)` (245) — 完结（OCR 源必须经 OCRCardStore）
  - `advanceLifecycle(now:)` (262) — 7 天过期 / 30 天归档推进，返回计数
  - `card(id:)` (283) — 单卡读取
  - `removeForSourceDoc(_:)` (292) — 源文档删除级联移除
  - `aggregationItems(patientId:)` (304) — 聚合中心轻投影（只取五列，非敏感摘要）
  - `StoreError` (324) — inactive / useOCRCardStore
  - `decode(_:)` (326) — 行 → PendingCard（损坏 JSON 抛 corrupt）

## CoreKit/Sources/Infrastructure/ProfileSuggestionStore.swift
- `ProfileSuggestionStore` (17) — 资料建议接受流（collect 只读 / accept 单事务 / dismiss 持久忽略）
  - `AcceptOutcome` (18) — written / skippedExisting
  - `auditAction` (21) — 审计白名单动作名
  - `stateKind` (22) — notification_state 登记 kind
  - `sourceTables` (24) — 建议来源实体表白名单
  - `severities` (27) — 规范严重度（Domain SevereReactionRules 单一事实源别名）
  - `collect(cardId:patientId:)` (36) — 一张卡全部回执 → 建议
  - `collect(cardKind:entityIds:patientId:)` (46) — 计划签名（卡类+实体 id 集）→ 建议
  - `Source` (58) — 回执来源留痕（私）
  - `collect(receipts:patientId:db:)` (65) — 只读聚合：四表叙事/诊断/检验 → Extractor → 过滤已处理
  - `snapshot(patientId:db:)` (145) — 既有资料快照（血型/问题/过敏）
  - `accept(_:patientId:allergySeverity:now:)` (155) — 逐项接受（不覆盖既有值；过敏严重度必须给出）
  - `dismiss(_:patientId:now:)` (232) — 单条忽略
  - `dismiss(_:patientId:now:)` (236) — 批量忽略（同成员校验 + 逐键登记）
  - `validateSource(_:patientId:db:)` (249) — 来源白名单 + 同成员
  - `handledKey(_:patientId:)` (260) — 已处理登记键（成员分域稳定哈希）
  - `markHandled(_:now:db:)` (264) — notification_state 已归档登记
  - `AuditMeta` (271) — 审计 meta（类别 + 留痕，不记原文）
  - `auditMeta(_:)` (277) — 审计 meta JSON 编码

## CoreKit/Sources/Infrastructure/PrescriptionStore.swift
- `PrescriptionStore` (13) — F9 处方数据仓（确认后落库，confirmed 恒 true）
  - `create(patientId:documentFileId:hospital:doctor:adviceText:prescribedAt:source:now:)` (21) — 最小可行入库（成员/文档校验）
  - `StoreError` (48) — invalidDate

## CoreKit/Sources/Infrastructure/QuestionStore.swift
- `QuestionStore` (9) — FR10.5 问医生问题仓（open → asked → dropped）
  - `QuestionRow` (14) — 问题行读面
  - `add(patientId:body:encounterId:now:)` (30) — 新建问题（status=open）
  - `list(patientId:status:)` (44) — 成员问题列表（状态可选过滤）
  - `markAsked(id:now:)` (66) — 标记已问（回填 asked_at）
  - `drop(id:now:)` (75) — 放弃（status=dropped，记录保留）
  - `openQuestions(patientId:limit:)` (84) — 准备包数据源：未问问题最近 N 条

## CoreKit/Sources/Infrastructure/ReminderLinkStore.swift
- `ReminderLinkStore` (12) — v27 通用提醒表首个写入方（来源多态回指，白名单校验）
  - `Error` (13) — invalidSource / invalidKind / notFound
  - `kinds` (23) — reminder.kind CHECK 枚举
  - `ReminderRow` (25) — 提醒行读面
  - `create(id:patientId:kind:title:at:source:repeats:now:)` (47) — 新建提醒（来源白名单 + 同成员）
  - `setSource(reminderId:patientId:source:now:)` (64) — 来源回指设置/清除
  - `setStatus(reminderId:patientId:status:now:)` (74) — 状态流转（active → done/cancelled）
  - `linked(source:patientId:includeInactive:)` (84) — 某来源实体下的提醒
  - `list(patientId:activeOnly:limit:)` (97) — 成员全部提醒
  - `assertSource(_:belongsTo:db:)` (107) — 白名单表 + 同成员实体存在
  - `reminderRow(_:)` (114) — 行 → 读面（来源经 validating 构造）

## CoreKit/Sources/Infrastructure/NotificationStateStore.swift
- `NotificationItemState` (12) — 通知处理状态
  - `case unread / read / archived` (13) — 未读 / 已读 / 已归档
- `NotificationStateStore` (16) — FR14.8 通知状态持久化（notification_state 唯一写入口）
  - `markRead(_:)` (21) — 已读 upsert
  - `markArchived(_:)` (31) — 归档 upsert
  - `unarchive(_:)` (42) — 撤销归档（Undo 条）
  - `states(for:)` (50) — 批量读处理状态（未登记 = unread）

## CoreKit/Sources/Infrastructure/MessageDeliveryStore.swift
- `MessageDeliveryStore` (13) — FR24.2 发送状态仓（不存原文）
  - `StoreError` (18) — illegalTransition / notFound
  - `recordSent(patientId:kind:recipient:at:)` (24) — 落一条 sent 记录
  - `updateStatus(id:to:at:)` (39) — 状态迁移（Domain MessageStatusRules 白名单）
  - `list(patientId:)` (57) — 按成员时间倒序列表

## CoreKit/Sources/Infrastructure/SettingsStore.swift
- `SettingsStore` (10) — F14 设置仓（app_settings 表，只存非默认覆盖）
  - `value(for:)` (15) — 单键读取（回落默认值）
  - `set(_:for:)` (24) — 单键写入 upsert
  - `allValues()` (35) — 全量一次查询（默认值补齐）
  - `restoreDefaults()` (50) — 恢复默认只删设置键域（不误删 AI 配额/词表锚）
  - `bool(for:)` (64) — 布尔语义读取
  - `AuditEntry` (68) — 审计条目读面
  - `auditEntries(limit:)` (78) — 审计列表（append-only 只读投影）

## CoreKit/Sources/Infrastructure/VoiceNoteStore.swift
- `VoiceNoteStore` (9) — FR17.14 语音速记仓（音频即用即弃，只存文本）
  - `create(id:patientId:body:tags:encounterId:inTimeline:now:)` (14) — 新建速记（默认不入轴）
  - `encodeTags(_:)` (30) — tags → JSON 数组列文本（create/update 单一出口）
  - `VoiceNoteRow` (36) — 速记行读面
  - `list(patientId:limit:)` (48) — 成员速记列表
  - `update(id:patientId:body:tags:inTimeline:)` (70) — 编辑（正文/标签/入轴）
  - `delete(id:patientId:)` (86) — 删除（成员隔离）
## CoreKit/Sources/Infrastructure/ObservationStore.swift
- `ObservationStore` (9) — F8 观察数据仓（创建/列表/详情/删除/补字段/孤儿对账引用集）
  - `create(id:patientId:kind:description:selfMark:groupId:mediaAssetIds:now:)` (14) — 新建观察（media JSON 编码）
  - `list(patientId:limit:)` (33) — 成员观察列表（单解码器复用）
  - `fetch(id:)` (48) — 详情页单行投影（与 list 同映射）
  - `delete(id:)` (60) — 硬删行（零行 → missingRow）
  - `DeleteError` (67) — missingRow
  - `updateExtended(id:...)` (70) — 事后补字段（COALESCE 只更新提交列）
  - `rowToEvent(_:memberId:decoder:)` (94) — 行 → 事件全字段投影唯一出口
  - `decodeMediaIds(_:decoder:)` (119) — 媒体 id JSON 数组解码（损坏降级空）
  - `allReferencedAssetIds()` (129) — 全库被引用资产 id 集（观察/头像/库存照片）
- `AllergyStore` (154) — F23 过敏记录仓（ADR-018 一等事件）
  - `create(id:patientId:substance:severity:reactionTags:note:allergenKind:occurredAt:now:)` (162) — 新建过敏（展示词 → 规范值；v30 过敏原类型落库）
  - `AllergyRow` (183) — 过敏行读面（含 v30 allergenKind）
  - `list(patientId:)` (197) — 成员过敏列表
  - `update(id:substance:severity:note:now:)` (213) — 修改（严重度规范化）
  - `delete(id:)` (225) — 删除

## CoreKit/Sources/Infrastructure/MemberDeletionService.swift
- `MemberDeletionService` (14) — FR3.4 删除成员（单事务：影响清单 → 拓扑清理 → 软删 → 系统通知取消）
  - `Impact` (26) — 影响清单（资料/观察/计划/预约/过敏计数）
  - `DeleteChoice` (40) — deletePlans / archivePlans
  - `impact(patientId:)` (46) — 删除前影响清单
  - `deleteMember(patientId:choice:now:)` (64) — 删除成员主流程（本人档案拒绝；拓扑序 FK 清理；写后取消通知）
  - `retryPendingNotificationCancellation(patientId:)` (148) — 软删已提交后重试系统取消
  - `reattributeDocument(documentId:from:to:now:)` (158) — FR3.5 重新归属（保留 OCR 链拒绝）
  - `hasRetainedOCRLinks(documentId:db:)` (176) — 是否存在保留的 OCR 事实/草稿链
  - `StoreError` (187) — memberNotFound/cannotDeleteSelf 等（LocalizedError 文案）

## CoreKit/Sources/Infrastructure/ReminderReconciler.swift
- `ReminderReconciler` (7) — §5.4 对账引擎（四层触发共用入口；actor 内去重）
  - `pendingBudget` (9) — 预算 = 60（留 4 条余量给即时预警）
  - `scheduler/source/isReconciling/logger` (11-14) — 调度端口 / 事实源 / 去重闸 / 日志
  - `snooze(doseNotifyId:slotNotifyId:until:)` (31) — 稍后提醒（先排新后撤旧；返回成败）
  - `priorityOf(_:)` (61) — 标识符优先级（dose/slot/snooze > apt > 其余）
  - `snoozeIdentifier(doseNotifyId:until:)` (71) — snooze 通知 id 构造（与反解成对）
  - `doseNotifyId(ofSnooze:)` (77) — snooze id → 剂量 id 反解
  - `reconcile(now:)` (86) — 主对账：事实/送达/时段聚合/决议/幽灵清理/预算裁撤
- `ReconcilerLogging` (207) — 日志端口协议（App 层注入 os.Logger 适配）
- `PrintLogger` (211) — 打印日志实现（CoreKit 平台无关）

## CoreKit/Sources/Infrastructure/ReminderIDNames.swift
- `ReminderIDNames` (7) — 通知 ID 命名空间（改前缀只动这里）
  - `appointmentPrefix(_:)` (8) — apt-<id> 前缀构造
  - `staleAppointments(in:ids:)` (19) — 待删预约的全部通知形态取回（分级/错过跟进/复诊）

## CoreKit/Sources/Infrastructure/SensitiveAssetStore.swift
- `SensitiveAssetStore` (22) — §5.10 敏感媒体资产仓（目录隔离 + 文件保护 + blur 双产物 + asset 登记）
  - `writer/compressor/baseDir/blurCache/observer/logger` (23-31) — 依赖与缓存/日志端口
  - `savePhoto(_:memberId:)` (58) — 原图 + 模糊版同事务写入（detached 压缩；失败清理半成品）
  - `removePhoto(_:memberId:)` (103) — 先删行后删文件（失败记日志）
  - `blurData(for:memberId:)` (127) — 模糊版读取（NSCache 缓存）
  - `originalData(for:memberId:)` (138) — 原图读取（只在显式解锁后；不缓存）
  - `reconcileUnreferenced(validAssetIds:)` (143) — 孤儿对账（10 分钟宽限窗 + 批量 IN 删除）
  - `wipeAllFiles()` (194) — 清空全部（BR-007 同步清内存缓存）
  - `memberDir(_:)` (207) — 成员媒体目录
  - `orphanFileURL(_:)` (216) — relative_path → 注入 baseDir 下绝对 URL（防 ".." 逃逸）
- `CacheBox` (232) — NSCache 的 Sendable 载体（观察者闭包捕获）

## CoreKit/Sources/Infrastructure/ModelCatalogTrustStore.swift
- `ModelCatalogTrustStore` (8) — ADR-030 信任仓：App 根公钥 → 连续根轮换 → 签名目录（锁外验签、锁内换态）
  - `Failure` (9) — unavailable/invalidMetadata/invalidSignature/expired/rollback
  - `shared` (10) — 单例
  - `baselineIndex` (11) — 随包基线索引（离线可用面兜底）
  - `root/roots/catalog/catalogEnvelope/revokedHashes` (14-18) — 信任链状态
  - `Baseline` (19) — 基线 JSON 形态（entries/版本/目录摘要/撤销）
  - `baselineFloor` (27) — 基线地板（防目录回滚）
  - `normalizedRevocations(_:)` (30) — 撤销摘要统一小写归一
  - `State` (33) — 落盘状态形态
  - `init(bundle:)` (35) — 从 bundle 装载 bootstrap/基线/状态
  - `init(bootstrapData:baselineData:stateURL:)` (43) — 装载 + 状态链校验（损坏缓存不授权新增）
  - `nextRootURL` (94) — 下一个根信封 URL
  - `acceptRoot(_:)` (101) — 接受根轮换（版本 +1、双验签、锁外落盘）
  - `acceptCatalog(_:)` (126) — 接受目录（防回滚 + 同版内容比对）
  - `checkBaselineFloor(_:envelope:)` (151) — 目录不得低于基线地板（同版比 SHA256）
  - `isAuthorized(_:)` (163) — 包是否获授权
  - `baseURL(for:)` (168) — 授权包的下载基址
  - `isRevoked(_:)` (173) — 撤销查询
  - `currentIndex` (182) — 已持久化最新未过期目录索引
  - `authorizedBaseURL(_:)` (191) — 授权判定核心（撤销/目录/基线三级）
  - `persist(_:)` (202) — 状态落盘（上限 + 不进备份）
  - `read(_:)` (214) — 受限读文件
  - `envelope(_:)` (221) — 信封形态校验
  - `date(_:)` (228) — ISO8601 Z 后缀日期解析
  - `validateRoot(_:)` (232) — 根校验（版本/键集/阈值/baseURL 白名单/键摘要）
  - `verify(_:root:role:)` (253) — Curve25519 阈值验签
  - `catalog(_:root:checkTime:)` (268) — 目录校验（rootVersion/有效期/模型清单）

## CoreKit/Sources/Infrastructure/ModelPackageDownloader.swift
- `ModelPackageDownloader` (9) — ASR 模型包下载（HEAD 探测 → 分段并行 → Range 吞掉退单流 → 终态校验）
  - `session/segmentCount/fileManager` (10-12) — 会话/段数/文件管理
  - `download(url:expectedBytes:to:progress:)` (19) — 下载主流程（https 兜底、进度节流聚合）
  - `downloadSegment(session:url:start:end:total:destination:counter:)` (100) — 单 Range 段下载（独立 FileHandle 顺序写）
- `ProgressCounter` (146) — 多段并发进度聚合（≥0.5% 或 ≥200ms 节流；系列代次）
  - `add(_:)` (165) — 累加字节并节流发射

## CoreKit/Sources/Infrastructure/ModelPackageUnpacker.swift
- `ModelPackageUnpacker` (9) — ASR 模型包安全解压（单一职责：zip → 目录）
  - `fileManager` (10) — 文件管理
  - `unzip(_:to:maximumBytes:onProgress:)` (17) — 解压：路径穿越防御/条目与展开量上限/扩展名白名单/CRC 校验/失败自清

## CoreKit/Sources/Infrastructure/ModelResourceTransfer.swift
- `ModelResourceTransfer` (6) — URLSession 下载守卫委托（地址/响应/字节预算约束）
  - `expectedBytes/range/onBytes/lock/storedFailure` (7-11) — 约束与失败记录
  - `record(_:)` (18) — 记录守卫失败（首个优先）
  - `resolve(_:)` (24) — 优先暴露守卫记录的真实原因（S-M4）
  - `recordForTesting(_:)` (26) — DEBUG 测试注入
  - `validate(_:)` (28) — 响应校验（https/状态码/Content-Range/编码/字节数）
  - `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)` (47) — 重定向白名单拦截
  - `urlSession(_:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:)` (54) — 写入进度守卫（超预算取消）
  - `urlSession(_:downloadTask:didFinishDownloadingTo:)` (65) — 空实现（落盘由调用方）

## CoreKit/Sources/Infrastructure/StreamingFileHasher.swift
- `StreamingFileHasher` (9) — 流式 SHA-256（1 MiB 分块，不整包进内存）
  - `sha256(of:onProgress:)` (16) — 流式哈希（按百分比变化发进度，最多 101 次）

## CoreKit/Sources/Infrastructure/ModelSpanAssembler.swift
- `ModelSpan` (7) — 生成轨模型输出 span（key/value/unit/lineIndex；verbatim 契约）
- `ModelSpanAssembler` (18) — 模型 span → RegionExtraction 装配器（T1/T2 共用，收敛单点）
  - `region(shared:rows:spec:lines:pageIndex:)` (20) — spec 键过滤 + 行界校验 + verbatim 子串锚定
- `ModelPromptBuilder` (51) — 生成轨提示词转发壳（实现在 Domain ExtractionPromptBuilder）
  - `systemPrompt(for:)` (60) — 转发提示词组装
  - `numbered(lines:)` (65) — 转发编号行

## CoreKit/Sources/Infrastructure/RuleExtractionEngine.swift
- `RuleExtractionEngine` (8) — T3 规则轨引擎（Domain RuleExtractor 端口包装；确定性零资产）
  - `track/regionTimeout` (9-10) — 轨标识 / 不限时
  - `availability(for:)` (12) — 恒可用
  - `extract(region:spec:request:)` (13) — 规则抽取转发
## CoreKit/Sources/Infrastructure/NLTextUnderstanding.swift
- `NLTextUnderstanding` (19) — 兜底轨理解引擎（零资产恒可用；NLTokenizer CJK 分词 + 词表直配）
  - `orchestrator` (20) — 三轨注册表编排器（EAL 装配）
  - `init()` (22) — 装配：注册表已注册则解析，否则回落规则轨
  - `deptWords` (38) — 科室词表（ExtractionPatterns.deptWordSet 单点）
  - `understand(_:)` (40) — 理解入口（OCR/语音分流）
  - `classifyOCR(_:)` (54) — OCR 侧：类型判定 + 处方走编排器 / 其余逐行启发式 + 叙事多行并入
  - `classifyVoice(_:)` (142) — 语音侧：意图目录 + 槽位抽取（转写置信度直传）
  - `lineDrafts(_:)` (147) — 零判定时行草稿（原文保留）
  - `deptDraft(forLine:)` (159) — 词表直配（整行/行尾 + NLTokenizer token 命中）
  - `deptDraft(value:rawText:)` (185) — dept 草稿构造（source=.heuristic）
- `FallbackTextUnderstanding` (198) — 三轨降级链组合器（降级零崩溃）
  - `tracks` (199) — 轨列表
  - `understand(_:)` (205) — 按序尝试，首个非空产出者胜；单轨非取消异常降级

## CoreKit/Sources/Infrastructure/UnderstandingDeadline.swift
- `UnderstandingDeadline` (8) — 单飞期限执行器（超时返回但不提前释放原生生成槽）
  - `acquire()/release()` (11-12) — 单飞闸
  - `run(timeout:operation:)` (14) — 期限执行（定时器 + 取消处理 + 槽位保留）
  - `Delivery` (42) — 一次性结果投递（先到者胜；锁保护）

## CoreKit/Sources/Infrastructure/OCRPipeline.swift
- `OCRPipeline` (11) — ADR-026 编排层：解码（灰度）→ 质量评估 → 识别 → 归一化
  - `recognizer/grayscaleDecoder` (12-13) — 识别/灰度解码端口（EAL 注入）
  - `Result` (20) — 管线产物（lines/hasText/confidence/qualityTags/failed/layout）
  - `run(imageData:)` (44) — 单图管线（质量评估失败不阻断识别；引擎失败 failed=true）

## CoreKit/Sources/Infrastructure/PDFExportService.swift
- `PDFExportService` (14) — FR13.1 PDF 导出（封面/目录/记录页/水印；UIGraphicsPDFRenderer）
  - `ExportRequest` (19) — 导出请求（维度过滤 + App 层注入文案闭包）
  - `ExportRequest.ScopeKind` (44) — all/member/dateRange/docType/doctorSummary
  - `ExportPackage` (68) — 导出产物（data/页数/记录数）
  - `collect(_:)` (78) — 收集导出数据（区间按各表时间列下推；仅 C 级文本 BR-003/007）
  - `exportPDF(_:progress:)` (167) — 渲染：封面 → 目录 → 逐记录页（每页检查取消）
  - `drawCover(_:request:count:)` (204) — 封面绘制（标题/时间范围/计数/免责）
  - `drawTOC(_:request:records:)` (217) — 目录绘制（页码 = 3 + index）
  - `drawRecord(_:record:page:)` (234) — 记录页绘制（种类/标题/时间/正文/页码）
  - `drawWatermark(_:request:)` (256) — 斜置低透明度水印（开关生效）

## CoreKit/Sources/Infrastructure/PDFKitDecoder.swift
- `PageAccumulator` (11) — @Sendable 逐页回调串行累加器（Swift 6 收敛）
- `PDFKitDecoder` (20) — M-DECODE 生产轨：PDFKit 多页渲染 + ImageIO 降采样
  - `decodeImage(_:maxDimension:)` (23) — 单图解码（EXIF 归正 + PNG 编码）
  - `decodePDF(_:scale:maxPages:)` (37) — 全量路径（经累加器兼容保留）
  - `decodePDFPages(_:scale:maxPages:onPage:)` (50) — 逐页流式渲染（MediaBox 封顶/Rotate 应用/单页释放）
  - `encodeToPNG(_:)` (101) — CGImage → PNG Data
  - `encodeToPNGFromData(_:width:height:)` (111) — 位图 Data → CGImage → PNG

## CoreKit/Sources/Infrastructure/VisionImageRecognizer.swift
- `VisionImageRecognizer` (17) — FR12.11 生产实现：VNRecognizeTextRequest（iOS 16）+ iOS 26 结构化路径
  - `recognize(_:)` (20) — 识别入口（iOS 26 结构化先行，失败回落 VN；detached 跳出主线程）
  - `performRecognition(_:)` (45) — iOS 16 路径：准确级三语识别，行级 bbox（左下→左上原点）
  - `RecognizeError` (85) — engineFailed（LocalizedError）
- `DocumentLayoutBridge` (98) — iOS 26 RecognizeDocumentsRequest 适配（行/表格/段落 → Domain 版面）

## CoreKit/Sources/Infrastructure/VisionImagePreprocessor.swift
- `VisionImagePreprocessor` (16) — M-PREPROC 生产轨：Vision 边缘检测 + Core Image 透视矫正
  - `preprocess(_:params:baseVersion:)` (19) — 主处理链（解码→矫正→色彩→旋转→JPEG；detached）
  - `decodeCGImage(_:)` (70) — 解码并归一化 EXIF 方向（Thumbnail API 不降采样只归正）
  - `detectAndCorrectPerspective(_:)` (85) — 检测 + 矫正组合
  - `detectQuad(_:)` (92) — Vision 矩形检测（置信度 >0.6）
  - `quadCorners(from:)` (111) — Vision 左下原点 → QuadCorners 左上原点（全仓唯一换算出口）
  - `perspectiveCorrect(_:quad:)` (121) — 四角透视矫正（UIKit → Core Image 坐标换算）
  - `applyPerspectiveFilter(_:topLeft:topRight:bottomLeft:bottomRight:)` (130) — CIPerspectiveCorrection（退化四边形面积防护）
  - `quadArea(topLeft:topRight:bottomLeft:bottomRight:)` (151) — 鞋带公式面积
  - `applyColorMode(_:mode:)` (161) — 色彩模式（color/grayscale/binary）
  - `encodeToJPEG(_:)` (178) — JPEG 编码（共享 CIContext）
  - `sharedContext` (192) — 共享 GPU 上下文
  - `detectQuad(_:)` (196) — 交互式选区检测入口（未检出回落整图四角）
  - `correctPerspective(_:corners:)` (207) — 手动裁剪矫正入口

## CoreKit/Sources/Infrastructure/SFSpeechTranscriber.swift
- `SpeechSessionLimits` (7) — 会话边界参数（轮换/收尾/重启/邮箱上限）
- `SpeechAudioChunk<Audio>` (17) — 音频块（buffer/时长/字节）
- `SpeechRecognitionFailure` (23) — 识别失败枚举（noSpeech/unauthorized/unavailable/bufferOverflow）
- `SpeechRecognitionEvent` (25) — 识别事件（文本/是否终稿/置信度/失败）
- `SpeechSessionDriver` (33) — 驱动端口（授权/采集/识别/追加/结束/准备失败原因）
  - `resolvedLocale/authorize/startCapture/stopCapture/startRecognition/append/endAudio/cancelRecognition/endSession/preparationFailure` (35-49) — 端口成员
- `SpeechSessionDriver` 扩展 (52) — endSession 与 preparationFailure 默认实现
- `SpeechStopSignal` (57) — 停止信号（running/finish/cancel；锁保护）
  - `Intent` (58) — running/finish/cancel
  - `finish()/cancel()` (62-63) — 意图推进
- `SpeechAudioMailbox<Audio>` (67) — 有界 tap 邮箱（实时回调不等控制队列）
  - `offer(_:)` (79) — 投递（上限溢出标记；scheduled 去重）
  - `take(closing:)` (98) — 取空（关箱/保留容量）
- `SpeechSessionCoordinator<Driver>` (113) — 队列限定会话协调器（单采集主）
  - `transcribe(_:onPartial:onCaptureStarted:)` (135) — 会话启动（超订/取消/接管裁决）
  - `finish(sessionID:)` (182) — 收尾
  - `cancel(sessionID:)` (192) — 取消
  - `discardSession(sessionID:)` (202) — 退弃
  - `finishCapture()` (212) — 停采集
  - `stop(_:intent:)` (221) — 按意图路由会话
  - `signal(for:)` (229) — 信号取/建（锁）
  - `removeSignal(_:)` (238) — 信号移除
  - `retire(_:)` (244) — 退役登记（256 上限）
- `ContinuousRecognition<Driver>` (251) — 单会话状态机（授权→分段轮换→收尾→结算）
  - `perform(_:)` (301) — 队列定位执行
  - `start()` (309) — 授权回调链启动
  - `finish()` (352) — 收尾（停采集、排空、终段）
  - `cancel()` (373) — 取消结算
  - `consumeMailbox(closing:)` (378) — 邮箱排空（handoff 有界）
  - `startSegment()` (408) — 分段启动（回放 handoff + 轮换定时器）
  - `endCurrentSegment()` (445) — 分段收尾（finalizationTimeout 后恢复）
  - `handle(_:segment:)` (467) — 识别事件（noSpeech 端点/终稿/部分文本）
  - `completeSegment(text:confidence:restartDelay:)` (496) — 分段完结（提交累积器、发布、重启链）
  - `publish()` (531) — 部分文本去重发布
  - `settle(error:)` (538) — 结算（停驱动、取段、continuation 恢复）
- `SFSpeechTranscriber` (581) — ADR-023 基线轨生产引擎（actor 门面 + 协调器）
  - `capability` (582) — 能力快照
  - `probeCapability()` (594) — 支持 locale 探测
  - `currentCapability()` (606) — 能力读取
  - `transcribe(_:onPartial:)` (608) — 转写入口
  - `transcribe(_:onPartial:onCaptureStarted:)` (613) — 转写入口（engineID=classic）
  - `finish/cancel/discardSession/endAudio` (620-623) — 控制路由
- `NativeSpeechAudio` (627) — 原生缓冲包装
- `NativeSpeechSessionDriver` (629) — SFSpeechRecognizer 驱动（AudioCaptureController 采集单点）
  - `authorize(_:isStopped:)` (652) — 语音+麦克风授权
  - `startRecognition(id:onEvent:)` (669) — 识别请求建立（locale 快照复用；noSpeech 端点识别）
  - `startCapture(onAudio:onFailure:isStopped:)` (716) — 采集启动
  - `stopCapture()` (726) — 停采集
  - `append(_:to:)` (728) — 缓冲追加
  - `endAudio(id:)` (733) — 音频结束
  - `cancelRecognition(id:)` (738) — 识别取消清理

## CoreKit/Sources/Infrastructure/SpeechAnalyzerTranscriber.swift
- `SpeechAnalyzerFlavor` (13) — 平台升级轨档位（standard/dictation）
- `SpeechAnalyzerSupport` (22) — 能力探测与语言资源管理（生产零隐式联网）
  - `availability(of:)` (24) — 档位可用性（系统版本 + 设备能力）
  - `supportedLocales(of:)` (39) — 系统支持 locale 集（async）
  - `installedLocales(of:)` (48) — 已安装 locale 集
  - `assetStatus(of:locale:)` (57) — 某 locale 资源状态
  - `install(locale:flavor:)` (65) — 显式下载安装入口
  - `supportedLocale(of:requested:)` (80) — 请求 locale → 系统等价 locale
  - `makeModule(flavor:locale:)` (89) — 档位 → SpeechModule 构造
- `SpeechAnalyzerTranscriber` (112) — FR17.1/FR17.15 平台升级轨引擎（资源缺失整会话回落基线轨）
  - `sessions/intents/baseline/delegated` (115-122) — 会话表/停止意图/基线委托/委托集
  - `currentCapability()` (132) — 实时探测已安装 locale
  - `probe(flavor:)` (134) — 探测实现
  - `transcribe(_:onPartial:)` (141) — 转写入口
  - `transcribe(_:onPartial:onCaptureStarted:)` (146) — 转写主入口（engineID 能力诚实回填）
  - `finish/cancel/discardSession` (160-183) — 控制路由（委托按 id 精确转发）
  - `endAudio()` (185) — 全会话停采集
  - `localeAssetStatus(_:)` (195) — 实验室资产状态
  - `prepareLocale(_:)` (199) — 显式安装
  - `warmUp(_:)` (207) — 零联网预热（绝不触发下载）
  - `mark(_:for:)` (213) — 停止意图推进（cancel 恒胜）
  - `AnalyzerResolution` (221) — analyzer(locale) / delegate 裁决
  - `resolve(locale:)` (226) — 每会话裁决（版本/设备/locale/资产未装 → 委托）
  - `run(request:onPartial:onCaptureStarted:)` (239) — 会话执行（委托窗内重查意图）
  - `baselineEngine()` (272) — 基线引擎惰性单例
  - `runAnalyzer(request:locale:onPartial:onCaptureStarted:)` (279) — 分析会话主循环（授权→采集→泵→等待→定稿）
  - `ensureAuthorized()` (349) — 语音+麦克风授权
- `AnalyzerStopIntent` (368) — 停止意图（running/finish/cancel）
- `AnalyzerSession` (375) — 单次会话（采集 + 分析 + 结果拼装）
  - `Piece` (376) — 结果片段（区间/文本/是否终稿）
  - `analyzer/stream/builder/standardModule/dictationModule/onPartial/lock` (386-392) — 分析器与流
  - `pieces/failure/lastPublished/resultsTask` (395-398) — 结果状态
  - `capture` (401) — 采集封装（AnalyzerCapture）
  - `init(id:locale:module:analyzerFormat:onPartial:)` (403) — 装配（双模块探测 + 流创建）
  - `startCapture()/stopCapture()` (421-427) — 采集转发
  - `finishInput()` (429) — 输入流收尾
  - `analyze()` (433) — 分析序列
  - `finalize(through:)` (437) — 按最后样本定稿
  - `finalizeThroughEndOfInput()` (441) — 按输入尾定稿
  - `abort()` (445) — 中止（取消分析 + 结果泵）
  - `startResultPump()` (452) — 结果泵（取消非故障；重叠区间替换语义）
  - `awaitResultsEnd()` (478) — 等待结果泵退出
  - `handle(text:isFinal:range:)` (484) — 片段合并（区间去重幂等）
  - `publish()` (500) — 部分文本去重发布
  - `displayText` (512) — 拼接文本（TranscriptJoiner 单点）
  - `captureFailure` (518) — 采集/分析失败读取
  - `noteFailure(_:)` (524) — 失败记录（首个优先）
  - `makeResult(localeIdentifier:)` (532) — 结果拼装（volatile → partial）
- `AnalyzerCapture` (549) — 采集侧封装（引擎/tap/观察者/会话快照；失败经 onFailure 回报）
  - `start()` (568) — 开麦（会话快照对称 + tap + 配置/中断观察者）
  - `stop()` (612) — 拆麦（幂等；快照还原）
- `AnalyzerFeeder` (645) — 音频线程转换器（采集格式 → 分析器格式）
  - `feed(_:)` (663) — 转换/拷贝后投喂（失败记标）
  - `copy(of:)` (700) — 缓冲深拷贝
## CoreKit/Sources/Infrastructure/SherpaOnnxTranscriber.swift
- `SherpaOnnxTranscriber` (10) — ADR-023 随包开源权重生产端口（初始化不加载模型、能力查询不启动麦克风）
  - `choice/assets/assetLease/memoryObserver/coordinator` (11-16) — 档位/资产租约/内存观察/会话协调器
  - `init(choice:assets:)` (19) — 装配（双路径资产解析；20s 收尾预算）
  - `unloadWhenIdle()` (43) — 内存警告/空闲卸载入口
  - `capability` (49) — 能力面（资产在位才算；30s 分段语义）
  - `transcribe(_:onPartial:)` (59) — 转写入口
  - `transcribe(_:onPartial:onCaptureStarted:)` (63) — 转写主入口（包授权校验；engineID 如实回填）
  - `localeAssetStatus(_:)` (80) — 资产状态（不返回 .downloadable）
  - `prepareLocale(_:)` (92) — 预热（同 warmUp）
  - `warmUp(_:)` (97) — 本机预加载零联网
  - `finish/cancel/discardSession/endAudio` (108-127) — 控制路由

## CoreKit/Sources/Infrastructure/SherpaSpeechSessionDriver.swift
- `CapturedSpeechAudio` (7) — 采集缓冲包装
- `SherpaSpeechSessionDriver` (11) — sherpa-onnx 驱动（控制队列采集/转换；串行推理队列解码）
  - `inferenceQueue/pool/idleEvictionSeconds` (12-15) — 静态推理队列/运行时池/闲置驱逐时长
  - `owner/request/choice/assets/readinessLock/ready/failure/language/converter/targetFormat/job/capture` (16-32) — 会话状态
  - `resolvedLocale` (39) — 实际服务语言如实回显（方言→模型基线码回译）
  - `preparationFailure` (51) — 准备失败真实原因
  - `preload(choice:request:assets:)` (59) — 预热入池
  - `authorize(_:isStopped:)` (74) — 麦克风授权 → 推理队列准备
  - `prepareRuntime(_:isStopped:deadline:)` (85) — 准备（租约重试窗口；失败如实上报）
  - `startRecognition(id:onEvent:)` (120) — 建立识别 Job
  - `append(_:to:)` (127) — 16 kHz 转换 + Job 投递
  - `endAudio(id:)` (147) — 音频结束调度
  - `cancelRecognition(id:)` (152) — 取消并清 Job
  - `endSession()` (158) — 释放租约 + 延后驱逐
  - `unloadWhenIdle()` (169) — 空闲卸载
  - `schedule(_:)` (171) — 推理调度（预览让位 + 取消/失败上报）
  - `startCapture(onAudio:onFailure:isStopped:)` (196) — 采集启动（onFormat 建 16 kHz 转换器）
  - `stopCapture()` (213) — 停采集
  - `RuntimePool` (215) — 模型运行时池（档位+whisper 语言+资产身份键；租约/代次驱逐）
    - `key(choice:language:assets:)` (228) — 池键构造
    - `load(choice:language:assets:key:)` (232) — 装载（租约 + 校验 + 运行时）
    - `acquire(owner:choice:language:assets:)` (241) — 接管（键匹配复用；授权校验）
    - `preload(choice:language:assets:)` (254) — 预热（不打断在用会话）
    - `release(_:)` (266) — 释放
    - `evictWhenIdle()` (272) — 空闲驱逐
  - `Job` (278) — 单识别任务邮箱（30s@16k 上限）
    - `cancelled/backlogSamples/finishRequested` (290-294) — 状态读取
    - `offer(_:)` (296) — 样本投递（溢出标记）
    - `finish()` (305) — 收尾请求
    - `take()` (308) — 取批（samples/final/overflow）
    - `cancel()` (314) — 取消清空

## CoreKit/Sources/Infrastructure/SherpaASRRuntime.swift
- `SherpaASRRuntime` (8) — 钉版 C API 有限适配层（空句柄抛可恢复错误）
  - `sessionLanguage/sessionHotwords` (15-18) — qwen3 per-stream 语言提示/热词 CSV
  - `lastPreviewSeconds` (20) — 上次预览解码耗时（自适应间隔）
  - `online/offline/stream/vad` (21-24) — 原生句柄
  - `committed/recent/recentStart/samplesSeen/lastPreviewAt/preview` (25-30) — 解码窗口状态
  - `init(choice:language:assets:)` (33) — 构造（zipformer online / qwen3·dolphin·whisper offline + VAD）
  - `deinit` (112) — 句柄销毁
  - `begin(language:hotwords:)` (120) — 每段复位（热词 sanitize；流创建）
  - `accept(_:final:cancelled:allowPreview:)` (142) — 波形投喂（online 流 / offline VAD 分段 + 预览让位）
  - `decode(_:)` (210) — 离线流解码（qwen3 per-stream 选项注入）
  - `setOption(_:_:_:)` (228) — 流选项设置
- `CStringStorage` (233) — C 字符串生命周期保管（strdup/free）

## CoreKit/Sources/Infrastructure/SherpaOnnxSpeechSynthesizer.swift
- `SherpaOnnxSpeechSynthesizer` (20) — Supertonic-3 ONNX 端侧离线 TTS（P1 多语种扩展候选，未接生产链）
  - `tts/voiceMap/defaultVoiceLocale` (21-27) — 合成器/voice.json 音色表/sid 0 真实音色
  - `audioPlayer/lock/generation/synthQueue` (28-36) — 播放器/代次作废/合成串行队列
  - `init?()` (38) — 资产预检七件套 + 配置构造（全程类型推断）
  - `speak(_:localeIdentifier:)` (73) — 回退链解析 + 后台合成播放（代次双重校验）
  - `stop()` (125) — 停止（作废在途/排队合成）
  - `loadVoiceMap()` (137) — voices.json 侧载读取（sid 不依赖下标）
  - `createWavData(samples:sampleRate:)` (157) — WAV 编码（单次 Int16 分配）
  - `assetPaths()` (205) — 七件套预检（缺件/空文件一律回落）
- `SherpaOnnxSpeechSynthesizer`（非 iOS 占位）(227) — macOS/Linux 编译占位（恒不可用）

## CoreKit/Sources/Infrastructure/SwitchableTranscriptionEngine.swift
- `SwitchableTranscriptionEngine` (6) — FR17.15 选择锁定一次按压的引擎开关（按 ID 精确路由）
  - `Stop` (7) — finish/cancel
  - `choiceProvider/builder/serving/stops/retired/captureOwner/cached/cachedAssetIdentity` (8-15) — 选择源/委托缓存/会话表
  - `init(choiceProvider:builder:)` (17) — 装配（Linux 桩默认）
  - `capability` (34) — 同步只读能力面（long-form 空 locale 语义）
  - `currentCapability()` (36) — 能力探测（auto 走聚合能力）
  - `transcribe(_:onPartial:)` (48) — 转写入口
  - `transcribe(_:onPartial:onCaptureStarted:)` (53) — 转写主流程（接管裁决：finish 排水/cancel 取消）
  - `finish(sessionID:)` (97) — 收尾（清 captureOwner 不取消旧结果）
  - `cancel(sessionID:)` (105) — 取消
  - `discardSession(sessionID:)` (111) — 退弃
  - `endAudio()` (117) — 停当前采集
  - `localeAssetStatus(_:)` (121) — 资产状态（门控解析）
  - `prepareLocale(_:)` (125) — 安装/预热（随包模型 = 预热）
  - `warmUp(_:)` (139) — 零联网预热
  - `resolvedChoice(for:)` (148) — auto 档按 locale 解析（transcribe/资产/预热共用的单一门控解析器）
  - `delegate(for:)` (157) — 引擎委托缓存（资产身份参与键）
  - `retire(_:)` (171) — 退役登记（256 上限）

## CoreKit/Sources/Infrastructure/StubGateUnlocker.swift
- `StubGateUnlocker` (7) — Linux 构建桩：恒可用恒成功（行为断言由 App 层 FakeGateUnlocker）
  - `isAvailable` (10) — 恒 true
  - `authenticate(reason:)` (12) — 恒 true

## CoreKit/Sources/Infrastructure/StubImageCompressor.swift
- `StubImageCompressor` (10) — M-COMPRESS Linux/dev 兜底（1x1 透明 PNG 占位）
  - `generateThumbnail(_:spec:)` (14) — 占位缩略图
  - `authorizeOriginalAccess(_:policy:reason:)` (20) — 敏感 + 需授权 → authRequiredForOriginal
  - `transparentPNG()` (29) — 1x1 透明 PNG 常量

## CoreKit/Sources/Infrastructure/StubImagePreprocessor.swift
- `StubImagePreprocessor` (9) — M-PREPROC Linux/dev 兜底（原样返回 + 版本号）
  - `preprocess(_:params:baseVersion:)` (12) — 占位（矫正标记置 false）
  - `detectQuad(_:)` (29) — 恒未检出
  - `correctPerspective(_:corners:)` (32) — 原样返回

## CoreKit/Sources/Infrastructure/StubPDFDecoder.swift
- `StubPDFDecoder` (9) — M-DECODE Linux/dev 兜底（占位 PNG/空白页）
  - `decodeImage(_:maxDimension:)` (12) — 1x1 占位
  - `decodePDF(_:scale:maxPages:)` (18) — 1 页空白占位
  - `transparentPNG()` (26) — 1x1 透明 PNG 常量


## App/AppShell/AppContainer.swift
- `AppContainer` (12) — 组装根：唯一 DatabasePool(WAL) + StoresBundle 全量生产依赖装配（tech-spec §3）
  - `degradedReason` (17) — 生产库打开失败的可视降级原因（非 nil = 只读安全模式，不静默跑内存库）
  - `store / audit / persistor` (18–20) — GRDB 库 / 审计写入口 / 病患持久化
  - `meds / apts / reconciler / reminderScheduler` (21–33) — 用药 / 预约仓与 FR9.18 通道投递门（唯一生产调度器）
  - `composer` (35) — FR9.15 五表原子计划创建（处方→计划参考模板）
  - `search / mediaSession / aiProvider` (36–41) — FTS 检索 / §5.10 敏感媒体会话令牌 / AIProvider 装饰器链（Audited→Safe→LocalRetrieval）
  - `settings / observations / mediaAssets / allergies / entitlements / trends` (42–48) — 设置 / 观察 / 敏感资产仓 / 过敏 / 额度 / 趋势
  - `codeIndex / notificationState / pendingCards / notificationCenterState / voiceNotes` (51–58) — F25 码表 / 通知持久化 / FR6.9 待办卡 / 通知中心门面 / 语音速记
  - `guidelines / emergencyCards / immunizations / claims / messages` (59–63) — 信源库 / 急救卡 / 疫苗 / 票据 / 消息投递
  - `encounters / healthExams / timelineQuery / healthProblems / questions` (65–71) — 就诊 / 体检 / 时间轴 / 健康问题 / 问诊
  - `memberDeletion / documents / prescriptions / backup` (73–79) — FR3.4 删除服务 / 资料库 / 处方 / 备份
  - `pdfExport / healthReader / healthSync` (83–87) — PDF 导出 / Apple 健康读取 / 自动化同步
  - `databaseWasLost(databasePath:originalsDir:)` (100) — 库文件缺失且原件目录非空的文件系统事实判定（绝不静默建空库写入）
  - `live(databasePath:)` (108) — 生产装配（文件库 + WAL + UNUserNotificationCenter 适配）
  - `productionScheduler()` (119) — 生产投递门统一装配（ChannelGatedScheduler 装饰 UNReminderScheduler）
  - `preview()` (130) — 预览/测试装配（内存库 + 内存调度器 + 临时目录资产仓）
  - `liveOrDegraded(databasePath:)` (141) — live 失败返回 degradedReason 非 nil 的占位容器（可见降级引导）
  - `assemble(store:scheduler:mediaBaseDir:degradedReason:)` (165) — 全部 Store 装配单出口（EAL 引擎注册 + HKHealthStore 单实例共享）
  - `defaultDatabasePath()` (280) — Application Support 下生产库路径
  - `defaultOriginalsDir()` (293) — BR-002 原件专用目录 `<Documents>/MedicalNotes/originals/`

## App/AppShell/AppDataChangeCenter.swift
- `AppDataChangeCenter` (15) — 类型化数据变更信号（版本计数即 UI 失效标记，数据库即事件总线）
  - `documentsVersion / metricsVersion / alertsVersion / assetsVersion` (16–23) — 四失效槽（文档/指标/预警/ASR 资产）
  - `documentSaved()` (30) — OCR/文档确认保存后 +1
  - `metricsChanged()` (35) — 设备读数落库后 +1
  - `alertsChanged()` (39) — 预警变化 +1
  - `assetsChanged()` (42) — ASR 模型安装完成后 +1
  - `dataWiped()` (48) — 清空全部后四槽齐拍全量失效

## App/AppShell/AppRootView.swift
- `AppRootView` (11) — 应用根视图：FR14.4 主题注入 + 门禁/向导/主页三路分支 + 全局生命周期补偿
  - `seedBundled / backfillDocumentTypeKeys` (23–27) — F16 信源库种子 / v27 doc_type_key 回填（VitaLiberApp 注入）
  - `body` (43) — 三分支（锁屏/向导/外壳）+ 主题/对比度/字号注入 + 生命周期修饰器
  - `startTasks()` (137) — 启动任务链（body 提取）：设置加载→语言对账→bootstrap→四链并行（失败隔离纪律）
  - `handlePhaseChange(_:)` (186) — scenePhase 状态机（body 提取）：FR1.4 退后台即锁 + 宽限锁 + 回前台对账
  - `seedBundledOrLog()` (278) — 信源播种失败隔离单一落点（错误不外传、不触发 async let 兄弟隐式取消）
  - `effectiveDynamicTypeSize` (292) — 关怀模式在系统字号基础上再放大一档
  - `currentTheme` (301) — FR14.4 主题（AppTheme 枚举映射）
  - `currentLanguage` (308) — 当前显示语言（body 顶层读值注册 @Observable 观察）
  - `highContrastOn` (313) — FR18.16 高对比度（手动 OR 关怀模式，Domain AppearanceRules 判定）

## App/AppShell/AppRouter.swift
- `PendingVoiceIntent` (16) — FR17.19 类型化语音意图草稿（意图 key + 已确认字段，一次性投递语义）
  - `intent / fields` (18–20) — 意图目录 key / 已确认字段（C 级映射）
  - `keyedValues` (22) — 预填消费方的统一读取出口（旧字典形态语义）
- `OcrConfirmationSet.pendingIntent(_:)` (31) — 已确认字段 → 类型化意图草稿（语音确认卡唯一出口）
- `AppRouter` (40) — §5.45 类型安全路由中枢：每 Tab 独立 NavigationStack path + 通知路由分发 + §5.48 跨启动持久化
  - `homePath / recordsPath / remindersPath / healthPath / mePath` (41–45) — 五 Tab 导航栈
  - `selection` (50) — 当前选中模块（导航单一状态源，随 paths 持久化）
  - `pendingVoiceIntent` (75) — 语音意图草稿暂存（内存态不持久化）
  - `markNavigationReady()` (85) — 外壳挂载后放行恢复/投递（幂等，延一拍避开 iOS 26 转场断言）
  - `markNavigationSuspended()` (107) — 外壳卸载挂起（卸载期间路由退回暂存）
  - `enqueue(route:)` (119) — 通知路由入队（就绪即投递；未就绪暂存，同路由移队尾去重）
  - `pop(_:)` (132) — 目的地视图自弹回根（§5.48 已删除实体降级）
  - `finishRestore()` (139) — 恢复幂等入口（只恢复一次）
  - `navigate(to:)` (152) — 路由分发（先切 Tab 再延一拍 push；指标族就地推入；.reminderToday 清栈）
  - `degradeToHome()` (209) — 缺路由显式归零导航状态并清持久化键
  - `select(_:)` (223) — Tab 选中回写统一入口
  - `selectionBinding` (230) — TabView/Sidebar 回写统一绑定
  - `pathBinding / binding(for:)` (242–248) — Tab path 绑定（NavigationStack 消费）
  - `Key` (255) — 五 Tab + selectedModule（+ .ai 遗留键清理）持久化键枚举
  - `pathTable` (265) — Tab ↔ 持久化键 ↔ path 单一映射表（漂移大声失败）
  - `row(for:)` (277) — 映射表行取用（缺行 fatalError 而非静默错栈）
  - `isInPlacePage(_:)` (290) — 跨 Tab 复用页判定（指标族：总览/趋势/快速录入）
  - `persist(path:_:) / persistSelection() / set(_:_:)` (303–320) — 导航热路径增量落盘
  - `restore() / load(_:)` (322–344) — §5.48 跨启动恢复（含 .reminderToday 残留剔除）
- `AppNotificationDelegate` (363) — UNUserNotificationCenterDelegate：didReceive 解码路由入队 / willPresent 前台投递
  - `userNotificationCenter(_:didReceive:withCompletionHandler:)` (368) — 通知点击→路由映射接收端（立即归还回调 + 主线程异步入队）
  - `userNotificationCenter(_:willPresent:withCompletionHandler:)` (399) — 前台呈现（Domain ReminderChannelRules 判定，系统线程不沾 MainActor）
  - `presentation(for:)` (412) — ForegroundDelivery → UNNotificationPresentationOptions 映射

## App/AppShell/AppState.swift
- `AppState` (20) — M1a 纵向切片应用状态仓（@Observable @MainActor，注入环境）：门禁/向导/成员/偏好单源
  - `OnboardingStage` (23) — FR21.9 向导状态机（disclosure/ownerName/addFamily，无 done 态）
  - `stage / onboardingFinished` (29–30) — 向导阶段 / 完成判定单源
  - `speechSynthesizer / imageRecognizer / transcriptionEngine / textRefiner` (52–58) — TTS/OCR/语音输入/润色四端口（EAL 注册表解析，测试可注入）
  - `bootstrap()` (137) — 启动装配：清态→加载所有者/同意/成员→披露断点续填校验
  - `disclosureCards / advanceDisclosure()` (172–194) — 披露三卡 + 断点续填（ConsentRecord key+version 去重）
  - `recordConsent(key:level:version:)` (199) — FR20.3/20.5 场景须知确认（版本变化重确认）
  - `isGateEnabled / needsLockScreen / gateAutoAttempts` (211–219) — 门禁派生状态（冷启动即锁；无 backgroundLocked 转场依赖）
  - `requestUnlock(reason:)` (228) — 门禁/敏感媒体共用系统设备所有者认证入口
  - `createOwner(name:gender:birthDate:bloodType:contact:)` (252) — 注册必要字段建档（先落库成功才推进，身份三处全有或全无）
  - `commitOwner(_:profile:contact:)` (263) — 身份原子提交单出口（DB→内存→defaults→stage）
  - `finishAddFamilyStep() / finishOnboarding()` (279–289) — 向导收尾
  - `currentPatientId` (299) — BR-001 当前成员锚点（defaults 背书 + access/withMutation + 会话级兜底常量）
  - `voiceInterviewStepsByPatient / voiceInterviewCompleted` (318–326) — FR17.11 按成员访谈完成步骤
  - `profileCompletion` (331) — 档案完善进度（Domain MemberProfileCompleteness 纯规则）
  - `setCurrentPatient / loadMembers()` (347–355) — 成员切换/加载
  - `updateMember / memberDeletionImpact / deleteMember / reattributeDocument / addMember` (360–457) — FR3.1 补全 / FR3.4 删除（审计旁路不决定主操作成败）/ FR3.5 重新归属 / FR3.7 添加家人
  - `readbackPreference` (467) — FR14.7 无耳机回读三态（ReadbackPolicy.isSelectable 二次校验）
  - `careMode` (485) — F18 关怀模式（双键镜像 + 旧键一次性迁移）
  - `observationLastKind` (507) — SP-14 上次观察类型（非法值回落默认）
  - `databaseHealth()` (522) — FR22.4 数据与存储健康真实值
  - `persistorReset()` (540) — FR14.3 清空全部（含身份与锚点复位，回到可用全新安装态）
  - `recordBackup(at:) / restoreBackupMark()` (566–575) — FR13.10 备份时刻记录/恢复镜像
  - `fireAudit(action:entityType:entityId:actorLocal:meta:logLabel:)` (581) — 审计 fire-and-forget 单出口
  - `reportFeedback / reportRecognitionIssue / auditCaregiverConfirm / auditExport / auditViewSensitiveOriginal` (598–639) — FR22.5/FR6.7/FR24.5/§7 审计动作
  - `speak(_:) / stopSpeaking()` (645–661) — TTS 单出口（只播 Domain ReadbackPolicy 脚本；回退轻提示）
  - `voiceOutputLocale / setVoiceOutputLocale(_:)` (665–675) — FR17.16 输出语言（access/withMutation 口径）
  - `persist(_:)` (678) — 统一异步持久化出口（§7 错误经 Logger）

## App/AppShell/FakeGateUnlocker.swift
- `FakeGateUnlocker` (7) — 门禁测试替身（XCUITest 无法自动化 Face ID，启动参数注入确定性结果）
  - `result / isAvailable / authenticate(reason:)` (8–11) — 确定性认证结果

## App/AppShell/MediaUnlockSession.swift
- `MediaUnlockSession` (13) — §5.10 敏感媒体跨视图会话令牌（一次认证换取会话级解锁；300s idle 重锁；退后台即锁）
  - `isUnlocked` (15) — 会话解锁态
  - `lastInteraction` (17) — 最后交互时刻（idle TTL 计算）
  - `idleTimer` (19) — 空闲重锁计时器（共享 MediaRelockTimer）
  - `unlock()` (24) — 解锁 + 启动 idle 计时 + 记录交互
  - `relock()` (31) — 显式重锁（用户主动或退后台）
  - `recordActivity()` (38) — 活跃信号刷新 idle 时钟（合并窗口由 Domain MediaUnlockPolicy 控制）
  - `onBackground()` (48) — 退后台重锁钩子
  - `startIdleTimer()` (53) — showcaseTTL 计时武装

## App/AppShell/RootAdaptiveView.swift
- `MainModule` (20) — ADR-021 五模块单一枚举（iPhone Tab 与 iPad Sidebar 同一枚举两种容器渲染）
  - `case home / records / reminders / health / me` (21) — 五模块
  - `id` (22) — rawValue 标识
  - `title` (24) — L10n 导航标题
  - `systemGlyph` (34) — SF Symbol
- `RootAdaptiveView` (46) — L1 外壳：compact=TabView / regular=侧边栏（horizontalSizeClass 容器驱动重排）
  - `selection` (56) — 选中模块绑定（AppRouter 单一状态源）
  - `sidebarSelection` (65) — 侧栏单选 Optional 适配（取消选择不回写）
  - `body` (71) — TabView/NavigationSplitView 分支 + 通知路由目的地 + SOS 悬浮球 + 会话退后台重锁
- `MainModuleID.init(_:)` (172) — MainModule → MainModuleID 转换
- `ModuleRoot` (186) — L2 模块根：switch 穷尽无 default（新增 case 编译期即红）
- `PreviewRoot` (224) — 预览装配容器（与 VitaLiberApp 同构注入；预览禁触生产目录）

## App/AppShell/RouteDestinationView.swift
- `RouteDestinationView` (13) — §5.45 AppRoute → 具体视图唯一分发表（switch 穷尽，未登记 case 编译期不可达）
  - `body` (17) — 全量路由 case → 视图（含 .symptom 旧路由兼容重定向、.memberDetail 查无降级）
- `RouteFallbackView` (251) — §5.48 已删除实体降级落点（提示 + 自弹回根）
- `AutoPopModifier / autoPop(route:)` (268–286) — 自弹回根共享修饰器（统一 sleep-1.2s-then-pop 时序）
- `MainModule.init(tabID:)` (289) — MainModuleID → MainModule 转换
- `ObservationCreateRouteView` (303) — F8 观察创建路由适配（接线 ObservationStoreState.create）
- `DocumentDetailRouteView` (323) — §5.45 文档详情路由适配（DocumentStore 单源查找；查无自弹回根）
  - `loadDocument()` (354) — 按 pendingVersion 重载文档行（失败可见 + §7 日志上报）

## App/AppShell/VitaLiberApp.swift
- `VitaLiberApp` (9) — @main 应用入口：组装根装配 + 通知 delegate 强引用 + 环境逐一下发
  - `container / router / notificationDelegate` (10–16) — 组装根 / 路由器 / 通知代理（delegate 被系统弱引用，必须 App 持有）
  - `body` (210) — WindowGroup：降级页 / 主界面分支
  - `mainRoot` (231) — AppRootView + 21 项环境注入（种子/回填闭包装配层唯一调用点）

## App/Compat/ChartsCompat.swift
- `ChartsCompat` (4) — iOS 17 滚动可见域能力探测
  - `supportsScrollableAxes` (6) — iOS 17+ 才支持横向滚动
- `View.chartWindowCompat(visibleLength:domainEnd:selection:)` (11) — 图表时间窗兼容：iOS 17 滚动+选点；iOS 16 钉轴域+Gesture 反解

## App/Compat/LayoutCompat.swift
- `View.contentMarginsCompat(_:_:for:)` (4) — iOS 17 contentMargins 垫片（16 no-op）
- `View.listSectionSpacingCompat(_:)` (7) — iOS 17 listSectionSpacing 垫片
- `View.recordingPulseCompat(isActive:)` (11) — 录音态符号脉动（iOS 17 variableColor；16 no-op）
- `ContentMarginPlacementCompat / ListSectionSpacingCompat` (15–16) — 不能直接暴露 iOS 17 类型的枚举垫片

## App/Compat/OnChangeCompat.swift
- `View.onChangeCompat(of:initial:_:)` (6) — iOS 17 双参 onChange 兼容；iOS 16 以上一值回放
- `OnChangeCompatModifier` (12) — iOS 16 路径实现（@State 存上一值，onAppear 处理 initial）

## App/Compat/UnavailableViewCompat.swift
- `VLUnavailableView<LabelContent, DescriptionContent, ActionsContent>` (4) — iOS 17 ContentUnavailableView 垫片（iOS 16 原生绘制：大图标/title2/说明/动作区）
- `StackedUnavailableLabelStyle` (23) — iOS 16 图标+标题堆叠样式（48pt 图标经 VLFont token）
- 六组 convenience init 扩展 (32–46) — 与 ContentUnavailableView 同组重载

## App/DesignSystem/CameraPicker.swift
- `CameraPicker` (7) — UIImagePickerController 薄包装（SP-14 步骤2；F5 资料库复用）
  - `onCapture` (8) — 拍摄回调
  - `makeUIViewController / makeCoordinator` (11–20) — 平台桥接件（视图文件不得内联 Representable）
  - `Coordinator` (22) — 代理回调（originalImage 缺失/取消 → dismiss）

## App/DesignSystem/CardKindIcon.swift
- `CardKindIcon` (15) — 卡类图标单一出口（kind → SF Symbol + VLIcon 字形 + 语义色令牌；ui-ux §3.4）
  - `Spec` (16) — symbol/glyph/tint 三元组
  - 色令牌 (24–29) — brand/gradeC/success/warning/danger/secondary（Assets 既有，token-only）
  - `spec(aggregation:)` (39) — 首页聚合行 9 类穷尽
  - `spec(timelineKind:)` (60) — 时间轴条目 22 类穷尽（主表，其余重载归并到此）
  - `spec(hub:hospitalized:)` (92) — 主卡三枢纽（住院期用住院图标）
  - `spec(childKind:)` (100) — 子卡类
  - `timelineKind(cardKind:)` (105) — 卡类字符串 → 时间轴条目类型（未登记回落 document）
  - `spec(cardKind:)` (130) — 卡类字符串图标
  - `spec(metric:) / symbol(metric:) / tint(metric:)` (140–176) — 健康指标 16 类穷尽（单一事实源）
  - `symbol(labItem:)` (182) — 检测/检查项符号（酶类/检查项/常规检验）
  - `timelineKind(linkedKind:) / spec(linkedKind:)` (192–211) — 就诊关联卡 14 类穷尽
  - `spec(documentTypeKey:)` (216) — FR5.5 文档稳定键 → 目标卡首卡类
  - 便捷出口 symbol/tint 八组 (227–236) — 实参标签按枚举区分防二义

## App/DesignSystem/GradeBadge.swift
- `GradeBadge` (7) — BR-003 来源徽章唯一渲染出口（A 医院原文/B 知识库/C 用户确认/D 识别未确认/E AI 解释；D/E/未知虚线+待确认角标）
  - `grade` (8) — 来源等级原始字符串
  - `Parsed` (13) — 等级一次解析（收敛原四次各自 switch + 数组字面量分配）
  - `parsed` (27) — 解析结果
  - `fill` (29) — 等级色（未知按未确认着色，不冒充 C 级）
  - `shortText` (41) — 本地化短文案
  - `isUnconfirmed` (52) — 未确认判定（D/E/未知）
  - `body` (59) — 徽章胶囊渲染（无障碍朗读）
  - `accessibilityText` (90) — 朗读文本（A/B 朗读字母+短文案；D/E/未知朗读「未确认」）

## App/DesignSystem/Haptics.swift
- `Haptics` (21) — tech-spec §5.15 触觉反馈单出口（UIKit 生成器，模型层可发、iOS 13+ 成熟实现）
  - `Impact / Notice` (22–23) — 冲击/通知分级枚举
  - `impact(_:)` (26) — 轻/中/重冲击（prepare 预热压延迟）
  - `notice(_:)` (35) — 结果通知（成功/警告/错误）
  - `uiStyle / uiType` (46–56) — UIKit 样式映射（canImport 守卫）

## App/DesignSystem/MediaImport.swift
- `MediaImport` (13) — 媒体导入共用件：ImageIO 下采样（原图不整图解码）+ PhotosPicker 并发加载
  - `downsample(_:maxPixel:)` (15) — 目标尺寸下采样为 UIImage（仅 MainActor 即时预览）
  - `thumbnailData(_:maxPixel:)` (21) — 下采样并编码 JPEG Data（非隔离上下文可用）
  - `loadWithThumbnails(_:)` (40) — 有界并发（在途上限 4）加载+缩略图，保持选择顺序，单张失败跳过
  - `downsampledCGImage(_:maxPixel:)` (74) — ImageIO 下采样核心（EXIF 方向自动矫正）

## App/DesignSystem/PagingStepper.swift
- `PagingStepper<Label>` (17) — ui-ux §4.17 翻页步进器（大号 ‹ › 双钮，触点 CareModeMetrics 44/64pt，整块 contentShape）
  - `canGoPrevious / canGoNext / previousLabel / nextLabel / identifiers` (18–23) — 可用态/无障碍标签/测试标识
  - `onPrevious / onNext / label` (24–26) — 动作与中间标签
  - `metrics` (30) — 关怀/常规触点度量
  - `body` (32) — 三件套排布
  - `button(icon:enabled:accessibilityLabel:identifier:action:)` (49) — 步进按钮（圆形可点区域）

## App/DesignSystem/SaveFailedAlert.swift
- `SaveFailedAlert` (6) — 保存失败错误态统一出口（四态纪律：失败绝不静默呈现为已保存）
- `View.saveFailedAlert(title:hint:isPresented:)` (22) — 统一修饰器（各表单不再各自复制 alert 三元组）

## App/DesignSystem/SensitiveMediaContainer.swift
- `MediaRelockTimer` (16) — 空闲重锁计时器（SensitiveMediaContainer/OriginalView/MediaUnlockSession 共用；策略常量仍在 Domain MediaUnlockPolicy）
  - `relockTask / unlockTask` (18–21) — 计时句柄 / 在途解锁句柄
  - `schedule(ttl:onExpiry:)` (24) — 武装空闲重锁计时（先取消旧计时；Task 显式 @MainActor）
  - `trackUnlock(_:)` (35) — 登记在途解锁任务
  - `cancelAll()` (40) — 取消计时与在途解锁
- `SensitiveMediaContainer<Content, Placeholder>` (59) — 敏感媒体保护容器（BR-007/008·FR1.9 逐次解锁：默认锁定→系统认证→空闲重锁→退后台即锁）
  - `content / placeholder` (64–66) — 解锁后内容 / 锁定态占位（绝不含可识别内容）
  - `unlocked / relockTimer / unlocking` (70–73) — 私有解锁态 / 共享计时器 / 连点防双认证守卫
  - `body` (83) — 点按解锁 + 活跃手势重置窗口 + scenePhase/onDisappear 重锁
  - `scheduleRelock()` (122) — 空闲重锁武装
  - `relock()` (128) — 重锁（取消在途解锁，认证结果不得复活）

## App/DesignSystem/SensitiveMediaOriginalView.swift
- `SensitiveMediaOriginalView` (11) — §5.10 敏感媒体原始视图（ImageIO 降采样防 OOM；FR1.9 逐次解锁；认证通过后才落内存）
  - `imageData / caption / assetId / originalLoader` (20–25) — 预传数据/标题/审计锚点/认证后按需加载器
  - `unlockedContent` (79) — 缩放/拖动/点按活跃手势 + 失败态 + 进度态
  - `lockedPlaceholder` (121) — 锁定占位（点按触发认证）
  - `authenticateAndUnlock()` (145) — 认证→拉取→解码→审计全时序（BR-007 时序纪律）
  - `scheduleRelock() / relock()` (181–204) — 空闲重锁 + 清解码图/缩放平移态
  - `loadDownsampled()` (206) — ImageIO 降采样解码（损坏载荷明示失败态）
- `ImageIOImageLoader` (223) — ImageIO 降采样工具（tech-spec §5.10）
  - `downsample(data:maxDimension:)` (224) — 按 UIScreen.scale 计算的目标尺寸降采样

## App/DesignSystem/SnippetText.swift
- `SnippetText` (10) — 检索片段渲染单一出口（FTS snippet()/SearchRules.highlight 的 <b> 标记拆段加粗，标记不渗出）
  - `snippet` (11) — 原始片段（带标记）
  - `body` (15) — 拆段拼接 + 无障碍朗读去标记纯文本
  - `composed` (21) — Text 拼接（命中段 .bold()+主色）

## App/DesignSystem/SystemLinks.swift
- `SystemLinks` (9) — 系统跳转单一出口（拨号/健康 App/系统设置；生产零网络三类 URL）
  - `dial(_:)` (13) — 拨号（PhoneNumberRules.dialable 归一；不可拨返回 false）
  - `openHealthApp(completion:)` (23) — 打开系统健康 App（F15 Medical ID 引导）
  - `openSettings()` (29) — 打开本 App 系统设置页

## App/DesignSystem/VLFont.swift
- `VLFont` (8) — 排版/图标尺寸令牌表（超标度字号收敛出口，ui-ux §3.2）
  - `levelDisplay / homeActionIcon / disclosureIcon / exportIcon / metricTileValue` (10–18) — 44/40/48/56/28pt 五令牌

## App/DesignSystem/VLIcon.swift
- `VLIcon` (7) — 精选图标唯一出口（AUTO-GENERATED 勿手改；重新生成 sync_best_selection.py）。图标表见 8 起，共 218 个 `static let`（tab/通用/业务/医疗设备/器官/空态插画）

## App/DesignSystem/VLIcon+ObservationKind.swift
- `ObservationKind.icon` (7) — 观察类型 → VLIcon 映射（Domain 不持 Image；八类穷尽）

## App/Localization/L10n.swift
- `L10n` (14) — 文案唯一出口主文件（语言机制：t() 解析、语言切换、包缓存；键表见各 Keys 分文件）
  - `supportedDisplayLanguages` (170) — FR14.5 可显示语言（原语言显示）
  - `pendingCardAggregationTitle(_:)` (223) — 首页聚合待办卡标题重组（card_kind → 本地化卡类名）
  - `supportedLocalizations` (345) — 三文件纪律（zh-Hans/zh-Hant/en）
  - `languageCache / bundleCache / cacheLock` (360–362) — 语言/包缓存（锁保护，防导出中途切语言撕裂）
  - `bundleLanguage` (364) — 当前语言读取
  - `languageDidChange` (376) — 语言切换通知（非视图副作用信号）
  - `setLanguage(_:)` (381) — 语言切换入口（相等性守卫不重发通知）
  - `restoreLanguage()` (400) — 启动恢复（只恢复不广播）
  - `docTypeKey(forLabel:)` (424) — FR5.5 标签 → 稳定键反查（27 键精确 → 旧标签三语反查；结果缓存）
  - `docTypeKeyCache` (442) — 反查缓存（锁保护）
  - `bundle(forLanguage:)` (458) — 指定语言资源包（不写缓存；跨语言反查用）
  - `resolveBundle(forLanguage:)` (468) — 四步回落查找链单一实现（currentBundle 与 bundle(forLanguage:) 共用）
  - `t(_:)` (481) — 单键解析出口（缺译回落系统默认）
  - `currentBundle` (489) — 当前语言包（缓存）

## App/Localization/L10n+Registry.swift
- `L10n.registeredKeys` (7) — 全部已键化 key 登记表（SU-M15-L10N 遍历断言输入；L0 双向判定）。键值表见 8 起，共 990 键。新增 key 必须同步登记

## App/Localization/L10n+Mapping.swift
- `L10n` 映射扩展 (6) — 参数化文案组装层（String(format:) 模板 + 枚举→文案映射），共 153 个 `static func`
  - 代表性映射：`voicePromptText(_:)` (39) SpeechPrompt 会话提示、`observationKindName(_:)` (160) 观察类型名、`memberRelationDisplayName(_:)` (287) 关系显示名单一出口、`observationMarkName(_:)` (279) 自述标记三值、`exportKindName(_:)` (399) PDF 类型名（F8 复用）、`voiceEngineName/Hint(_:)` (518–542) 识别引擎实验室、`asrModelVariantName(_:)` (491) 模型档位名、`timelineHubCount(_: _:)` (555) 主卡计数徽章、`encounterSummaryDocFields(_:)` (260) 就诊总结未确认行
  - `careParametersSOSValue(seconds:)` (31) — 关怀模式 SOS 生效参数（2026-09-18 已改名对齐 camelCase）

## App/Localization/L10n+Keys-*.swift（16 个键表文件）
每个文件 = `extension L10n`（第 6 行起），键名规则：`域名.语义名`（如 `allergy.title`、`plan.form.dosePerTake`），`static var` 直读 + 少量带逻辑的 `static func`（词表键映射）。键值表见各文件第 6 行起：
- L10n+Keys-Allergy.swift — F23 过敏（27 键；`allergySeverity` 经 SevereReactionRules.displaySeverity 规范化）
- L10n+Keys-Appointments.swift — F10 预约（27 键）
- L10n+Keys-Assistant.swift — AI 模板键（17 键；F12 助手退役后保留 ai.* 七段式；`aiUncertain`/`aiAskDoctor` 参数化）
- L10n+Keys-Confirm.swift — OCR 确认/复核清单（36 键）
- L10n+Keys-Documents.swift — F5 资料库（62 键）
- L10n+Keys-Emergency.swift — 急救卡/SOS（30 键）
- L10n+Keys-Health.swift — F16 Apple 健康（85 键；`healthMetricName` 指标名映射、`healthAggregation` 聚合形态、预警信源名）
- L10n+Keys-Home.swift — F2 首页八卡/聚合中心（160 键）
- L10n+Keys-Medications.swift — F9 用药/双轨库存/批号/计划（119 键；`inventoryReconcileTitle` 等参数化）
- L10n+Keys-Misc.swift — 杂项聚合（351 键；核心映射函数：`trendPeriodRange`(111) 周期标签、`docTitle`(285) 标题回落、`entityCardKindName`(322) 卡类名、`templateFieldLabel`(336) 字段标签、`prescriptionTypeName`(410)/`diagnosisTypeName`(416)/`examReportTypeName`(422)/`profileSuggestionKindName`(458) 枚举词表、`timelineKindName` 时间轴类名、`docTypeName` 稳定键标签）
- L10n+Keys-Observations.swift — F8 观察（54 键；`observationKindName(forKey:)` 未知 key 兜底）
- L10n+Keys-Records.swift — 就诊/时间轴/健康问题（95 键）
- L10n+Keys-Reminders.swift — 提醒/计划（51 键）
- L10n+Keys-Settings.swift — 设置/偏好/备份/生命周期（282 键）
- L10n+Keys-Trends.swift — F7 趋势（39 键；`trendWindow` 四档时间窗）
- L10n+Keys-Voice.swift — F17/F19 语音与附表执行（175 键；`sleepStage` 六阶段、`voicePromptText` 会话提示）


## App/Features/Capture/DocumentSourcePageView.swift
- `DocumentSourcePageReference` (8) — 原文页引用解析值（"doc:<id>#p<n>" → 结构）
  - `init?(sourceRef:)` (13) — 解析引用串，非法返回 nil
- `DocumentSourceRenderer` (23) — PDF/图片单页渲染（只读渲染出口，不落盘）
  - `Failure` (24) — 渲染失败原因（unreadable / pageMissing）
  - `pageCount(data:mimeType:)` (26) — PDF 页数（非 PDF = 1）
  - `image(data:mimeType:pageIndex:)` (32) — 第 N 页缩略图（PDF 走 PDFKit、图片走 downsample）
- `DocumentSourcePageView` (46) — 敏感原件页查看器（加载 / 解锁 / 分页 / 空闲重锁）
  - `Source` (47) — 数据源：库内文档或导入草稿
  - `var body` (84) — 渲染装载/失败/加锁/图片+缩放四态
  - `prepareMetadata()` (128) — 装载元数据（敏感级 / 原图路径 / 页数）
  - `startLoad()` (148) — 重试装载入口
  - `unlock()` (156) — 门禁解锁后加载媒体并登记查看审计
  - `loadMedia()` (172) — 读原图字节 + 渲染当前页
  - `renderPage()` (198) — 当前页解码渲染
  - `scheduleRelock()` (206) — 空闲 TTL 重锁调度
  - `relock()` (217) — 清内存态并取消在途任务

## App/Features/Capture/OcclusionEditorView.swift
- `OcclusionEditorView` (11) — FR5.4 入库前遮挡工具壳（跳过/完成工具栏）
- `OcclusionCanvas` (53) — PencilKit 叠层（原图铺底 + 透明画布）
  - `makeCoordinator()` (66) / `makeUIView(context:)` (68) / `updateUIView(_:context:)` (102) — UIViewRepresentable 三件套
  - `Coordinator` (105) — 涂写变更回写共享状态
  - `render(image:drawing:)` (119) — 像素级合成（涂写按显示矩形映射回图像坐标）
- `CanvasContainerView` (137) — 原图+画布同坐标系容器；`layoutSubviews` (141) 回写显示矩形

## App/Features/Capture/QuickCaptureView.swift
- `QuickCaptureView` (11) — 拍摄/相册/文件统一入口（区域→遮挡→OCR→确认管线）
  - `var body` (46) — 渲染三入口 + 相机/区域/遮挡/确认四层 sheet 编排
  - `beginSelection(step:)` (247) — 建立导入会话并登记步骤
  - `startCamera()` (257) — 相机权限请求 + 拉起相机
  - `startOCR()` (270) — 进 OCR 草稿管线（prepareImageDraft）
  - `recoverSelection()` (283) — 按 captureStep 恢复中断流程（含离屏转场补发）
  - `cancelSelection()` (313) / `failSelection()` (321) — 取消/失败清理
  - `title` (323) / `docTypeHint` (333) / `allowedTypes` (342) — 按 CaptureKind 的派生文案与文件类型

## App/Features/Capture/ScanRegionEditorView.swift
- `ScanRegionEditorView` (11) — FR5.2 四角选区 + 透视矫正
  - `var body` (25) — 图片 + QuadOverlay + 错误浮层
  - `autoDetect()` (72) — 自动检测预置四角
  - `confirm()` (81) — 透视矫正并回调结果
  - `imageFrame(in:)` (103) — aspectFit 实际渲染矩形
- `QuadOverlay` (120) — 四角拖拽叠层
  - `point(_:)` (151) — 归一化角点 → 屏坐标
  - `handle(_:id:)` (156) — 单手柄（44pt 命中区 + 拖拽钳制）

## App/Features/Confirm/EncounterAssociationSection.swift
- `EncounterAssociationSection` (11) — 卡片 → 就诊/体检主卡关联 Picker 区
  - `hub` (24) — 卡类的枢纽类型（Domain 判定）
  - `selection` (27) — Picker 选中值（草稿/未选/既有 id）
  - `var body` (48) — 渲染 Picker + 建议/加载/失败态
  - `select(_:)` (36) — 用户改选（草稿/不关联/既有）
  - `load()` (81) — 候选加载 + 未选择时裁决默认（ParentCardDraftRules）

## App/Features/Confirm/EntityCardConfirmView.swift
- `EntityCardConfirmView` (6) — SP-12 已确认卡确认页（行级字段 + 复核清单）
  - `Mode` (7) — queue（导入会话）/ resume（待办续办）
  - `SourcePresentation` (23) — 原文呈现方式（扫描图 / 行锚定）
  - `var body` (224) — 渲染主卡草稿区/关联区/共享字段/行字段/复核清单
  - `fieldRow(_:index:rowId:required:)` (57) — 单字段行（收敛 13 实参 + 锚点链）
  - `reviewSection(_:proxy:)` (72) — 风险排序复核清单段
  - `sourceLine(forKey:rowId:)` (95) — 字段原文行锚定（无锚定即 nil）
  - `uniqueLabels(_:)` (104) — 清单表头去重字段名
  - `reviewQueueRow(_:proxy:)` (113) — 清单一项（缺/歧义/确认三分支）
  - `confirmField(_:)` (158) — 清单就地确认
  - `sharedRequired` (173) / `rowRequired(_:)` (174) — 必填集（CardKindRegistry 单一事实源）
  - `missingShared(reviewed:)` (179) — 缺失共享字段清单
  - `canSave(reviewed:)` (184) — 保存闸门（含主卡草稿 isComplete）
  - `confirmingDraftFields(_:)` (199) — 卡级确认延伸至主卡草稿（Domain 规则）
  - `invalid(_:reviewed:)` (367) — 行无效字段投影
  - `missingButton(key:rowID:)` (372) — 缺必填补填按钮
  - `addFieldMenu(rowID:present:)` (386) — 「添加字段」目录
  - `appendField(_:rowID:)` (402) — 追加空 D 级字段
  - `fieldBinding(index:rowID:)` (412) — 字段绑定（safe 下标兜底）
  - `revise(index:rowID:value:)` (432) — 修订语义改值
  - `save(reviewed:)` (439) — 保存（批量确认合格字段）
  - `deferCard()` (456) / `discard()` (470) — 延后/丢弃
- `Array` 扩展 `subscript(safe:)` (481) — 安全下标
- `PendingCardResumeRouteView` (485) — 待办卡续办路由（按状态选渲染面）
  - `var body` (495) — 续办/旧卡只读/失败/加载四态
  - `load()` (554) — 加载待办卡并准备续办投影

## App/Features/Confirm/ParentDraftSection.swift
- `ParentDraftSection` (11) — SP-12 主卡草稿区（D 级、逐字段确认）
  - `var body` (19) — 渲染草稿字段 + 日期补填 + 必填/低置信提示
  - `draft` (87) — 草稿投影
  - `update(_:)` (92) — 草稿单一写入口
  - `fieldBinding(index:)` (98) — 草稿字段绑定
  - `draftRequired` (110) — 草稿必填集（按枢纽取）
  - `revise(index:value:)` (115) — fillByUser 语义
  - `dateResolvable(_:)` (121) — 日期可解析判定
  - `hasUnconfirmedLowConfidence(_:)` (127) — 低置信未确认判定
  - `dateBinding(_:)` (132) — 内联日期选择（yyyy-MM-dd、显式选择=确认）
  - `dateText(_:)` (152) — 日期 → yyyy-MM-dd（可逆解析口径）

## App/Features/Confirm/ProfileSuggestionSheet.swift
- `ProfileSuggestionSheet` (12) — D4-2「资料建议」表单（D 级逐项接受/忽略）
  - `RowState` (17) — 行状态机（pending/busy/written/existing/skipped/failed）
  - `state(of:)` (24) / `unhandled` (25) — 行状态读取与未处理集
  - `var body` (29) — 渲染逐行建议 + 完成/全部跳过工具栏
  - `row(_:)` (71) — 单行（徽章/取值/原文入口/严重度/接受/忽略）
  - `statusLabel(_:)` (130) — 行状态文案
  - `severityBinding(_:)` (140) — 过敏严重度绑定
  - `accept(_:)` (144) — 逐项接受（D→C 显式动作）
  - `skip(_:)` (158) — 逐项忽略（持久登记）
  - `skipAll()` (167) — 全部跳过（无「全部接受」）
- `ProfileSuggestionHost` (183) — 建议批宿主修饰器（按 presenterKey 呈现）
- `View` 扩展 `profileSuggestionHost(presenterKey:enabled:)` (211) — 宿主挂载入口

## App/Features/Confirm/SourceLineSheet.swift
- `SourceLineSheet` (10) — 字段 → 原文行锚定面板（行级高亮、非框级）
  - `highlighted` (15) — 行号合法性守卫
  - `var body` (20) — 逐行渲染 + 高亮行滚动定位

## App/Features/Documents/DocumentImportConfirmView.swift
- `DocumentImportConfirmView` (8) — 原件/类型审核页（SP-11 导入确认第一步）
  - `editable` (15) — 可编辑判定
  - `var body` (17) — 渲染类型选择/页状态/跳过入口
  - `typeOptions` (140) — 类型目录（候选+27 稳定键标签+当前值去重）
- `FieldConfirmRow` (147) — 单字段确认行（确认卡/共享页/主卡草稿共用）
  - `var body` (176) — 渲染徽章/置信提示/枚举 Picker 或编辑框/确认·拒绝·原文锚定
- `OCRKeyboardDismissButton` (275) — 键盘工具栏收键盘按钮
- `OCRReviewOwnerRow` (288) — 「归属成员」行（全仓共用）
- `ImportReviewSessionView` (301) — 导入复核会话壳（重复比对→文档审核→共享信息→卡级）
  - `var body` (316) — 按会话阶段分派子视图
  - `createHealthProblem()` (389) — 健康问题建议落地（诊断行优先）
- `OCRCardBrowserNavigation` (409) — 卡级浏览器（卡 chips + 上/下一张）
- `OCRImportReviewHost` (458) — 导入复核宿主修饰器（sheet 呈现 + 队列推进）
  - `presentIfReady()` (495) — 呈现就绪判定
- `View` 扩展 `ocrImportReviewHost(...)` (505) — 宿主挂载入口
- `DocumentReviewRouteView` (511) — 存量文档复核路由
  - `prepare()` (540) — 复用既有会话或重建

## App/Features/Documents/DocumentLibraryView.swift
- `DocumentsState` (12) — 导入管线状态仓（F5/F6 核心：准备→审核→卡级→落库）
  - `ImportOutcome` (42) / `CaptureStep` (43) — 导入结局与采集步骤枚举
  - `ImportSource` (45) — 已落库导入的文档/页投影
  - `ImportSession` (52) — 一次导入会话（草稿/重复/卡队列/共用信息/拍摄态）
  - `PendingReview` (90) — 待办卡续办态
  - `QueuedImport` (108) — 待处理导入队列项（文件/照片）
  - `ProfileSuggestionBatch` (117) — D4-2 资料建议批（按宿主键呈现）
  - `PendingDocument` (127) — 待分析文档载荷（原图/加工图/哈希）
  - `ImportDraft` (140) — 导入草稿（页/字段/类型/快照）；`isPrescription` (163) / `allFields` (164) / `allReviewed` (165) / `entityCards` (175) 派生
  - `ReviewSnapshot` (188) — 复核快照（持久化恢复用）
  - `beginImport(patientId:)` (236) — 开新会话
  - `preparationSession(patientId:)` (244) — 准备态守卫入口
  - `cancelImport(sessionID:)` (255) / `finishImportPresentation(sessionID:)` (263) / `releaseImportPresenter(sessionID:presenterID:)` (270) — 会话生命周期
  - `finishEntityQueueIfNeeded()` (276) — 队列清空即完结
  - `sharedFieldRows(for:)` (286) / `settleSharedFields(_:sessionID:)` (293) / `deferFromSharedFields(_:sessionID:)` (303) — 共用信息步（SP-63）
  - `updateEntityCard(_:)` (316) / `dequeueEntityCard(_:)` (325) / `selectEntityCard(_:)` (334) — 卡队列操作
  - `setImportError(_:)` (340) / `pendingDidChange()` (342) — 错误/变更信号
  - `enqueueFiles(_:patientId:)` (347) / `enqueuePhotos(_:patientId:)` (352) / `processNextImport()` (357) — 批量导入队列
  - `load(patientId:includeArchived:)` (385) / `loadPending(patientIds:)` (405) — 列表/待办加载（BR-001）
  - `fetch(id:)` (411) / `setArchived(id:archived:)` (416) / `setFavorite(id:favorite:)` (423) — 单文档操作
  - `persistOriginal(patientId:data:ext:)` (430) — 原件落盘（BR-002 不可变）
  - `prepareImageDraft(...)` (440) / `importDocument(...)` (451) / `importPDF(...)` (480) — 三路导入入口
  - `prepare(_:in:checkDuplicates:)` (497) — 重复检测 + 页分析
  - `PDFAnalyses` (550) — PDF 页分析收集 actor
  - `analyze(imageData:index:hint:)` (555) — 单页 OCR+理解+代码解析
  - `assembleDraft(_:pages:qualityTags:)` (592) — 草稿组装（类型键/候选/低置信）
  - `DuplicateResolution` (609) / `resolveDuplicate(_:)` (611) — 重复处置（保留/共存/替换）
  - `commitDraft(_:)` (632) — 落库事务（媒体路径→载荷编码→save/update→卡队列）
  - `CommitPayload` (688) — 落库载荷（元 JSON/OCR 全文/页/已确认字段）
  - `persistMediaPaths(_:session:)` (697) — 原件/加工件路径持久化（跨重试保留）
  - `encodeCommitPayload(_:meta:cards:)` (716) — 载荷编码（纯变换）
  - `cardsForCommit(_:)` (739) — 复核冲突检测 + 并发读 reviewState
  - `deferImportDraft(_:)` (782) — 延后整批导入
  - `prepareStoredDocument(id:patientId:)` (793) — 存量文档复核恢复
  - `isClinicalDocType(key:label:)` (832) — 临床类文档判定（健康问题建议门控）
  - `createHealthProblem(patientId:name:)` (838) / `createManual(...)` (844) — 健康问题懒创建/手工建档
  - `docTypeLabel(forStableKey:)` (858) / `docTypeKey(forLabel:)` (867) / `persistedDocTypeKey(label:classifierKey:)` (874) — 稳定键↔标签映射
  - `docTypeKeyOptions` (882) / `docTypeLabelOptions` (888) — 类型目录
  - `hash(_:)` (892) — 内容哈希
  - `ImportError` (893) — 导入错误
- `DocumentLibraryView` (896) — 资料库列表壳
  - `var body` (911) — 列表/空态 + 导入入口四选 + 错误警报
- `DocumentLibraryRow` (987) — 资料行（图标/徽章/锁标/归档收藏滑动）
- `ManualDocumentSheet` (1035) — 手工建档表单
- `DocumentStoreDetailView` (1067) — 资料详情（关系区/原件/复核入口/问题报告）
- `DuplicateCompareSheet` (1114) — 重复对比选择卡；`compareColumn(title:name:grade:)` (1147)
- `ReportIssueSheet` (1159) — 识别问题报告表单

## App/Features/Documents/DocumentsState+DisplayMappers.swift
- `extension DocumentsState` (5) — 展示层映射扩展（2026-09-18 从 DocumentLibraryView.swift 拆出）
  - `nonisolated static func fieldLabel(forKey:)` (9) — 模板键 → 本地化字段名
  - `nonisolated static func timelineEntryTitle(_:)` (43) — 时间轴行标题展示出口
  - `nonisolated static func fieldValueDisplay(forKey:value:)` (81) — 字段值展示层映射（canonical raw → 本地化）
  - `nonisolated static func enumOptions(forKey:)` (123) — 枚举槽位 Picker 目录

## App/Features/Documents/DocumentsState+EntityCards.swift
- `extension DocumentsState` (7)
  - `PageAnalysis` (8) — 页分析结果（行/字段/稳定键/置信）
  - `currentEntityCard` (20) — 当前选中卡投影
  - `entityQueuePosition` (23) — 队列位置（快照缺席回落）
  - `extractPageFields(...)` (33) — 页字段抽取（Domain 出口）
  - `encounterEvidence(typeKey:fields:)` (41) — 就诊卡文档类型证据
  - `matchPages(_:manualTypeKey:)` (49) — 页 → 匹配卡（模板匹配）
  - `reconcileCards(_:previous:)` (84) — 旧卡身份/来源/确认态合并
  - `pendingDraft(_:source:)` (137) — 卡 → 待办载荷
  - `encounterCandidates(patientId:)` (148) — 关联候选
  - `confirmEntityCard(_:confirmed:)` (153) — 卡确认保存（写库+通知+建议）
  - `notifyAfterSave(_:)` (181) — 保存后通知调度
  - `deferEntityCard(_:)` (193) / `deferRemainingEntityCards()` (217) — 延后卡
  - `discarded(_:)` (227) / `discardEntityCard(_:)` (241) — 丢弃卡
  - `residualCard(_:)` (246) / `resumePendingCard(_:)` (251) — 续办恢复
  - `retainedImport(for:)` (274) — 在途导入会话匹配
  - `loadPendingCard(id:)` (282) / `pageCount(documentId:)` (287) — 待办读取
  - `completePendingCard(_:confirmed:)` (292) — 续办卡完成
  - `deferPendingCard(_:edited:)` (328) — 续办卡延后
  - `discardPendingCard(_:)` (353) — 续办卡丢弃
  - `suggestionPresenterKey(session:)` (391) / `suggestionPresenterKey(pending:)` (392) — 建议宿主键
  - `offerProfileSuggestions(...)` (396) — 保存后采集建议
  - `acceptProfileSuggestion(_:severity:)` (409) — 逐项接受
  - `dismissProfileSuggestions(_:)` (419) / `clearProfileSuggestions(presenterKey:)` (426) — 忽略/清批

## App/Features/Documents/DocumentTypeKeyBackfill.swift
- `DocumentTypeKeyBackfill` (17) — doc_type_key 首启一次性回填
  - `doneKey` (19) — 完成标记键
  - `Row` (21) / `Outcome` (28) — 回填行与结局（alreadyDone/completed/failed）
  - `resolve(label:)` (38) — 标签 → 稳定键（未命中 custom）
  - `runIfNeeded(defaults:batchLimit:pending:apply:)` (52) — 幂等分批编排（注入闭包测试形态）
  - `runIfNeeded(store:defaults:batchLimit:)` (86) — 真实仓绑定

## App/Features/Documents/PendingCardCenterState.swift
- `PendingCardCenterState` (16) — 待办卡通知门面（首页聚合可观察投影）
  - `load(patientId:)` (26) — 聚合项加载（BR-001 守卫）
  - `refresh(patientId:)` (40) — 火忘刷新
  - `loadDetail(id:)` (44) — 详情 sheet 数据
  - `resolve(patientId:id:)` (54) — 用户补全完结后刷新

## App/Features/Documents/PendingOcrQueueView.swift
- `PendingOcrQueueView` (14) — FR6.8 待确认聚合队列（SP-53）
  - `pendingRows` (30) — 过滤+逾期旗标+排序（旗标一次预计算）
  - `var body` (42) — 列表/空态/错误 + 成员与时间窗筛选条
  - `load()` (147) — 跨成员加载
  - `windowMatch(_:)` (153) — 时间窗判定（Domain 出口）

## App/Features/Documents/SharedFieldsReviewView.swift
- `SharedFieldsReviewView` (17) — SP-63 共用信息步（跨卡字段一次确认）
  - `SourceAnchor` (28) — 原文行锚定载荷
  - `settled` (34) / `pending` (35) / `pagesLines` (36) — 派生状态
  - `var body` (38) — 逐行字段 + 承载方说明 + 离场工具栏
  - `fieldRow(_:)` (88) — 单行（FieldConfirmRow 复用、不给「拒绝」）
  - `rowHeader(_:)` (100) — 行头（重复/关键 chip）
  - `reasonChip(_:)` (108) — 入池原因 chip
  - `carriersLabel(_:)` (117) — 承载方去重说明
  - `lines(for:)` (140) / `sourceLine(_:)` (147) / `viewSource(_:)` (153) — 行锚定
  - `toolbar` (160) — 稍后/继续
  - `settleAndContinue()` (174) — 回填并进卡级
  - `deferAll()` (181) — 整批落待办

## App/Features/Members/MemberViews.swift
- `MemberManagementView` (11) — F3 成员管理（列表/切换/添加家人 + 配额弹墙）
  - `var body` (20) — 渲染成员行/添加按钮 + 配额与失败警报
- `MemberDetailView` (115) — 成员详情/编辑（FR3.1 字段 + FR3.4 删除流）
  - `var body` (139) — 渲染基础信息/字段表单/删除入口
- `DeleteMemberFlowSheet` (237) — 删除流（影响清单→姓名二次确认→计划处置）
- `MemberConfirmBar` (290) — FR3.3 归属强制确认条（保存前）
- `MemberCreateSheet` (324) — 新建成员表单（Domain 可创建关系目录）
- `extension MemberManagementView` (367)
  - `memberIcon(_:)` (372) — 关系 → 图标（MemberRelation 词表）
  - `memberIconLabel(_:)` (391) — 图标无障碍标签

## App/Features/Onboarding/OnboardingFlowView.swift
- `OnboardingFlowView` (9) — M1a 首启流程编排（三卡→建档→家人）
  - `var body` (12) — 三步进度条 + 按 stage 分派步骤视图
  - `stepIndex` (48) — 阶段 → 进度下标
- `LockOverlayView` (64) — 门禁遮罩（回前台必见、自动认证、SOS 豁免）
  - `var body` (79) — 锁占位 + 解锁按钮 + 失败提示 + SOS
  - `attempt()` (172) — 设备所有者认证

## App/Features/Onboarding/OnboardingViews.swift
- `DisclosureCardsView` (12) — L1 三卡（边界/存储/跳过信息）
  - `var body` (16) — 卡片渲染 + 推进按钮
  - `icon` (56) / `title` (63) — 按卡类映射
- `AddFamilyStepView` (76) — FR21.9 添加家人步骤（可跳过）
  - `var body` (84) — 手动新建 + P1 置灰 + 完成/跳过
- `OwnerSetupView` (155) — 首启建档表单（特征性数据 + 紧急联系人 + 健康预填）
  - `Field` (177) — 键盘焦点枚举
  - `var body` (179) — 表单三分段 + 键盘工具栏
  - `profileSection` (216) / `contactSection` (263) / `actionsSection` (287) — 表单三分段
  - `prefillFromHealth()` (304) — Apple 健康特征型预填（只填空字段）
  - `birthDate` (325) / `bloodValue` (336) / `contactDraft` (345) / `formValid` (351) — 校验派生
  - `create()` (358) — 建档提交（写库失败响亮呈现）

## App/Features/Records/AllergyViews.swift
- `AllergyListView` (10) — F23 过敏列表（严重度色条 + C 级徽章 + 删除确认）
  - `var body` (17) — 列表/空态 + 删除确认对话框
  - `severityColor(_:)` (93) — 严重度 → 语义色（Domain 等级函数）
- `AllergyCreateView` (108) — 三步记录表单（类型→过敏原→严重度）
  - `var body` (132) — 三步 Form + 归属确认条
  - `toggleTag(_:)` (222) — 反应标签切换
  - `save()` (226) — 保存 + 重度急救引导卡（BR-012）

## App/Features/Records/ClaimViews.swift
- `ClaimListView` (7) — FR13.7 报销票据（汇总 + 列表 + 录入）
  - `var body` (13) — 汇总卡/行列表
  - `typeLabel(_:)` (77) — 票据类型 → 本地化名
- `ClaimCreateSheet` (86) — 录入表单

## App/Features/Records/DoctorShowcaseView.swift
- `DoctorShowcaseView` (13) — ui-ux §5.8 就诊展示模式（全屏临时解锁轮播）
  - `var body` (30) — 认证门/加载/内容三态 + 倒计时环工具栏
  - `startCountdown()` (124) / `stopCountdown()` (137) — TTL 倒计时启停（按需订阅）
  - `authenticate()` (146) — 所有者认证 + 会话令牌（复位倒计时）
  - `showcaseContent` (156) — 观察组轮播
  - `exit()` (172) — 退出重锁（BR-007/008）
- `ShowcasePage` (179) — 单组观察展示页（时间/类型/描述/自述标记/敏感媒体条）

## App/Features/Records/EncounterViews.swift
- `encounterKindDisplayName(_:)` (12) — 就诊类型显示名（DocumentsState 出口）
- `EncountersState` (19) — 就诊模块状态仓（列表/详情/挂接/推荐，BR-001）
  - `load(patientId:)` (26) — 列表加载（换成员清屏）
  - `get(id:)` (46) — 详情直取
  - `upsert(_:)` (53) — 保存 + 按发起成员刷新
  - `linkDocument(documentId:encounterId:)` (74) / `unlinkDocument(documentId:)` (83) — 资料挂接
  - `recommendations(for:)` (91) / `unconfirmedFields(patientId:)` (95) — 推荐/未确认统计
  - `linkedCards(id:patientId:)` (100) / `linkedDocuments(id:patientId:)` (103) — 关联卡片/资料
- `EncounterListView` (109) — 就诊列表（成员筛选 + 类型胶囊 + 关联计数）
- `EncounterDetailView` (196) — 就诊详情（头部卡/叙事列/关联资料/推荐/总结入口）
  - `var body` (215) — 详情分段渲染
  - `episodeRow(_:)` (456) — 分段行落点（预约/提醒/已确认卡）
  - `appointmentTitle(_:)` (472) — 预约候选标题
  - `loadAppointmentCandidates()` (477) / `linkAppointment(_:)` (487) — FR10.7 关联预约
  - `linkedCardRow(_:)` (499) — 关联卡行
  - `narrativeFields(_:)` (528) — 非空叙事列
  - `refresh()` (540) — 详情全量刷新
- `EncounterSummaryView` (553) — 就诊总结页（未确认清单红点，BR-003）
- `EncounterFormView` (612) — 就诊表单（字段全集 + 叙事列）
- `EncounterDetailRouteView` (716) — 路由式就诊详情（深链投影 + 降级）

## App/Features/Records/HealthExamDetailView.swift
- `HealthExamViewState` (11) — 体检读面门面（actor store 的 @Perceptible 包装）
  - `detail(id:patientId:)` (17) — 体检详情读取
- `HealthExamDetailView` (25) — 体检主卡详情（表头→一般检查→结论→子报告→投影→原件）
  - `var body` (36) — 内容/查无/失败/加载四态
  - `content(_:)` (67) — 详情分段
  - `reportRow(_:)` (170) — 子报告行
  - `cardKind(for:)` (196) — 报告类型 → 卡类
  - `headerRows(_:)` (205) / `generalRows(_:)` (219) — 表头/一般检查非空行
  - `sampleLabel(_:)` (232) — 投影点标签
  - `load()` (236) — 详情加载（invalidCard → 查无）

## App/Features/Records/ImmunizationViews.swift
- `ImmunizationListView` (8) — FR4.5 疫苗接种（按疫苗分组 + 剂次进度）
  - `groupedRecords` (15) — 按疫苗名保序分组
  - `var body` (25) — 分组列表 + 边界微文案
- `ImmunizationCreateSheet` (95) — 录入表单

## App/Features/Records/MedicalCardDetailView.swift
- `MedicalCardDetailView` (7) — FR4.2/FR6.9 已确认卡详情（就诊/原件共用入口）
  - `var body` (22) — 头部/处方行/叙事列/诊断/结论/检验分段/关联/来源
  - `encounterTitle(_:)` (144) — 关联就诊标题
  - `prescriptionLineLink(_:index:)` (150) — 处方行链接
  - `load()` (157) — 详情+候选加载（路由替换先清投影）
  - `saveAssociation()` (172) — 关系保存（冲突走独立失败通道）
  - `headerFields(from:)` (203) — 头部字段过滤（按卡类剔除清单/叙事键）
  - `narrativeSections(from:)` (223) — 非空叙事列
- `DiagnosisRow` (234) — 诊断行（名称/类型胶囊/编码/日期）；`meta(_:)` (263)
- `ClinicalConclusionRow` (277) — 结论行（类型胶囊 + 原文 + severity 纯文本）
- `LabReportSections` (309) — 检验报告分段（数值/定性默认折叠）
- `LabSampleRowView` (351) — 数值行；`valueText(_:)` (381) / `meta(_:)` (388)
- `LabResultRowView` (396) — 定性行；`valueText(_:)` (423) / `meta(_:)` (428)
- `PrescriptionLineRow` (442) — 处方行摘要（原文拼接零解析，BR-006/007）
- `DocumentRelationsSection` (476) — 原件关联卡/就诊读投影；`load()` (508)

## App/Features/Records/PrescriptionLineDetailView.swift
- `PrescriptionLinePresentation` (9) — 处方行展示字段目录（行详情/列表摘要共用）
  - `fields(_:)` (11) — 全列展示字段
  - `summary(_:)` (41) — 列表摘要拼接
  - `notes(_:)` (50) — 说明+备注
  - `joined(_:unit:)` (56) — 「原文 + 单位」拼接
- `PrescriptionLineDetailView` (66) — 处方行详情（事实全列 + 来源 + 表头入口）
  - `var body` (74) — 内容/查无/失败/加载四态
  - `content(_:)` (96) — 详情分段
  - `headerSummary(_:)` (147) — 表头摘要（医院·医生·开方日期）
  - `load()` (157) — 详情加载（invalidCard → 查无）

## App/Features/Records/RecordsHubStore.swift
- `M2HubStore` (17) — M2 各页共用装配状态仓（药箱/急救卡/疫苗/报销/发送/信源库）
  - `loadSection(_:label:fetch:commit:)` (74) — 分节加载单一惯用法（BR-001 代际守卫）
  - `load(patientId:)` (86) — 六节并发加载 + 成员代际盖章
  - `healthHistory(...)` (148) / `healthEvent(...)` (152) — 预警历史直查
  - `fetchLot(id:)` (158) / `updateLot(...)` (162) — 批次详情/编辑
  - `refreshInventory()` (177) — 药箱缓存刷新单一出口（尽力而为）
  - `reconcileLot(item:physicalCount:)` (186) — 盘点归真（带审计）
  - `dispenseCSV()` (201) — 配药清单 CSV（DispenseListRules）
  - `toggleEmergency(item:selected:patientId:)` (214) — 急救卡选择 + 审计
  - `writeThenRefresh(patientId:logWriteFailure:refreshLabel:write:fetch:commit:)` (247) — 写后刷新单一出口（疫苗/报销/发送/送达共用）
  - `createImmunization(...)` (260) / `createClaim(...)` (272) — 疫苗/报销写入
  - `recordSent(...)` (289) / `markDelivered(...)` (313) — 发送状态写入
  - `auditHelpCardSent(recipient:)` (299) — 求助卡外发审计

## App/Features/Records/RecordsHubViews.swift
- `InventoryHubView` (13) — 药箱挂载壳（加载 + 盘点/导出/求助卡 sheet）
- `CSVTextDocument` (89) — 配药清单 CSV 导出文档（FileDocument）
- `EmergencyCardHubView` (103) — 急救卡挂载壳（含只读锁屏形态）
- `ImmunizationHubView` (143) / `ClaimHubView` (164) / `GuidelineHubView` (297) — 疫苗/报销/信源库挂载壳
- `SentStatusHubView` (184) — 发送状态挂载壳
- `SentStatusListView` (199) — 发送状态列表（最小必要：不存不显原文）；`kindLabel(_:)` (250)
- `StatusBadge` (262) — 发送状态徽章（语义令牌）
- `HelpCardSendHost` (313) — FR24.1 发送前预览 + 收件人选择两步壳

## App/Features/Records/TimelineExpansionStore.swift
- `TimelineExpansionStore` (14) — SP-19 主卡展开记忆（UserDefaults + LRU 淘汰）
  - `keyPrefix` (15) / `orderKey` (16) — 键常量
  - `remembered(_:)` (28) — 读取记忆
  - `set(_:expanded:)` (33) — 写记忆 + LRU 触尾 + 超容量淘汰
  - `forget(_:)` (47) — 清除单条
  - `rememberedCount` (56) — 已记忆键数（测试/诊断）

## App/Features/Records/TimelineHubViews.swift
- `TimelineHubRowView` (10) — 主卡行（图标/胶囊/标题/子卡计数 + 独立详情触点）
  - `spec` (15) / `headline` (20) / `subline` (31) / `accessibilityText` (42) — 派生展示
- `HubCountBadges` (94) — 子卡计数徽章；`ordered(_:)` (98) — 计数序（Domain 出口）
- `TimelineChildRowView` (127) — 子卡行（图标/类型/标题/来源徽章）
  - `title` (138) — 行标题（DocumentsState 单一出口）
  - `summary` (140) — 摘要（处方计数/文档类型/其余原文）

## App/Features/Records/TimelineViews.swift
- `TimelineViewState` (11) — 时间轴状态仓（主卡/子卡分页 + 筛选 + 展开 + 健康问题）
  - `load(patientId:)` (46) — 首屏加载（换成员清屏；hubPage+问题并发）
  - `loadMore(patientId:)` (83) — 游标翻页（去重追加）
  - `visibleHubs` (100) — 筛选可见投影（Domain 规则）
  - `expandedIds` (107) — 展开集（记忆 + 筛选瞬态覆盖）
  - `isExpanded(_:)` (118) / `setExpanded(_:_:)` (121) — 展开读写（筛选态不写记忆）
  - `setFilter(_:)` (129) — 筛选设置
  - `createProblem(...)` (136) / `setArchived(...)` (147) / `mergeProblems(...)` (157) — 健康问题写操作
- `TimelineFullView` (169) — SP-19 健康时间轴（色点/筛选 chips/成员切换/快捷入口）
  - `var body` (175) — 列表/空态 + 筛选条 + 翻页尾部
  - `filterBar` (287) — 筛选 chips + 问题入口 + 成员切换
  - `toggle(_:)` (343) — 类型筛选切换
  - `openHub(_:)` (351) — 主卡「详情」落点
  - `open(_:)` (359) — 行落点全路由（按 kind 分派）
- `TimelineRowView` (419) — 时间轴叶子行（六类色点/健康数据图标/来源徽章）
  - `entryTitle` (425) — 行标题组装（L10n 单出口）
  - `color` (503) — 色令牌（CardKindIcon）
- `FilterChip` (506) — 筛选 chip
- `HealthProblemListView` (532) — FR11.4 健康问题管理（列表/归档/合并）
- `ProblemCreateSheet` (616) — 新建问题表单
- `VisitPrepView` (658) — FR10.4 就诊准备包（五分区一页式摘要）
- `QuestionsState` (780) — FR10.5 问诊问题状态仓
  - `openQuestions` (787) — 未问问题投影
  - `load(patientId:)` (791) / `add(patientId:body:)` (805) / `markAsked(id:)` (816) — 读写
- `QuestionListView` (829) — 问诊问题列表（记录 + 标记已问）

## App/Features/Voice/AppState+VoiceProfile.swift
- `extension AppState` (4)
  - `commitVoiceProfileField(_:value:patientId:)` (7) — FR17.11 访谈答案写入（结构化字段直写、其余追加 note 段落）
  - `voiceProfileSectionTitle(_:)` (27) — 访谈键 → 段落节标题

## App/Features/Voice/ASREngineSettingsSection.swift
- `ASREngineSettingsSection` (23) — FR17.15 生产引擎设置区（档位选择 + 运行时下载）
  - `IndexCheckState` (31) — 「检查更新」三元态
  - `ChoiceAvailability` (51) — 每档位派生结论（已装/最新/可更新/字节数/变体）
  - `appVersion` (74) / `derivationKey` (79) — 版本与重算键
  - `rebuildAvailability()` (91) — 派生结论主 actor 外一次算好（渲染路径不取锁）
  - `var body` (128) — 检查更新 + 档位行 + 下载控制
  - `downloadControls(_:)` (227) — 已装/变体选择/更新/下载按钮
  - `variantBinding(_:_:)` (294) — 尺寸选择绑定
  - `variantHint(for:)` (305) — D6 按 RAM 建议（Domain 规则）
  - `installProgress(_:_:)` (316) — 分阶段进度（下载字节数/校验解压阶段文案）
  - `phaseText(_:)` (345) — 安装阶段文案
  - `indexCheckTimeout` (361) — 检查更新 30s 看门狗
  - `refreshIndex()` (371) — 索引拉取（单飞 + 看门狗 + 三元反馈）
  - `startInstall(_:)` (399) — 发起安装（经安装中心）

## App/Features/Voice/ASRInstallCenter.swift
- `ASRInstallCenter` (21) — ASR 模型安装中心（App 层全局进行态 + 后台窗口 + 广播）
  - `Install` (37) — 单安装可观察对象（观察域分离：进度高频/列表低频）
    - `submit(progress:)` (52) — 进度写入（同系列单调守卫）
    - `submit(phase:)` (67) — 阶段切换（重置进度基线）
  - `isInstalling(_:)` (98) / `install(_:)` (102) — 进行态查询
  - `start(_:baseURL:)` (107) — 启动安装（per-choice 幂等）
  - `dismissFailure()` (119) / `cancel(_:)` (121) — 失败处置/取消
  - `run(_:choice:install:baseURL:)` (125) — 安装执行（后台任务 + 资产广播 + 失败登记）

## App/Features/Voice/DictationPressState.swift
- `DictationPressState` (8) — 触摸按压状态机（点击开关 vs 按住说话，可单测）
  - `EndAction` (9) — 抬手动作（none/toggle/stop）
  - `holdThreshold` (24) — 识别阈值（CareModeMetrics 单一事实源）
  - `holdThresholdNanoseconds` (27) — 纳秒形式（Task.sleep 出口）
  - `begin()` (34) / `recognize(_:)` (41) / `end(cancelled:)` (47) — 状态机三步

## App/Features/Voice/PressToTalkMicButton.swift
- `PressToTalkMicButton` (8) — SP-55 大号按住说话按钮（麦克风环 + 状态行）
  - `var body` (11) — 圆环/波形 + 状态文案 + 交互修饰器
  - `ringColor` (88) — 录音态环色
- `DictationInteraction` (97) — 按压交互修饰器（长按阈值/点击开关/无障碍/场景失活处理）
  - `var body` (107) — 手势 + 无障碍动作 + scenePhase 观察
  - `prepareAuthorization()` (190) — 授权同步
  - `toggle()` (194) — 点击开关
  - `endPress(cancelled:)` (200) — 抬手动作分派

## App/Features/Voice/VoiceDictationModel.swift
- `VoiceDictationModel` (9) — FR17.1 听写模型（按压身份/采集生命周期/有序最终交付）
  - `Phase` (10) / `FailureReason` (14) — 录音阶段与失败原因
  - `failureMessage` (18) — 失败文案（两个挂载点共用映射）
  - `partial` (22) / `resolvedLocale` (24) / `resolvedEngineID` (25) — 会话态
  - `hasPendingTranscriptions` (28) — 在途转录判定
  - `onTranscript` (29) / `onEmergency` (31) / `onActivityChange` (33) — 回调出口
  - `preferredLocale` (36) / `contextualStrings` (38) / `languageMode` (41) — 语言配置
  - `PressContext` (42) — 单次按压上下文（请求/代际/回调/部分门）
  - `applyLanguageSettings(storedLocales:mixedInput:recentDrugNames:)` (72) — 语言装配
  - `applyLanguageSettings(settings:recentDrugNames:)` (85) — 装配入口收敛（三处调用同源）
  - `warmUp()` (96) — 模型预热（不采音不联网）
  - `isBestEffortFallback` (101) — 方言回落判定（FR17.15 能力诚实）
  - `start()` (107) / `stop()` (139) — 开始/按次松手
  - `stopForDisappear()` (153) — 视图销毁清理（废弃集 + 引擎 cancel）
  - `setAuthorization(_:)` (190) — 授权变更（关闭即清理）
  - `dictate(_:)` (196) — 采集主流程（能力探测→转录→结果登记）
  - `applyOutcome(_:sessionID:lifetime:)` (244) — 完成回调 → UI 状态（废弃守卫 + FR8.9 提示）
  - `deliverCompleted(lifetime:)` (274) — 交付循环（发起序投递 + 应急拦截）
  - `applyPartial(_:revision:sessionID:epoch:)` (294) — 部分文本应用（修订号守卫）
- `PartialGate` (303) — 部分文本去重 + 修订计数（线程安全）
- `VoiceDictationButton` (326) — 通用听写按钮（FR14.1 授权消费点）
  - `var body` (341) — 授权禁用态/录音按钮/部分文本/失败/方言回显
  - `ensureModel()` (403) — 引擎装配（语言值变化即重建）
  - `onEmergency` (422) — BR-012 横切动作（默认跳急救卡配置）

## App/Features/Voice/VoiceEngineLabView.swift
- `VoiceEngineLabView` (18) — FR17.15 识别引擎实验室（SP-62）
  - `LabResult` (21) — 对照测试结果行
  - `testLocale` (53) — 测试语言解析
  - `var body` (58) — 档位选择/资源安装/对照测试/结果列表
  - `select(_:)` (178) — 档位切换（写入设置 + 重建测试模型）
  - `rebuild()` (188) — 重建测试模型
  - `refreshAssetStatus()` (206) — 资产状态刷新（代际守卫）
  - `testFallbackNote` (216) — 对照测试回落诚实标注
  - `install()` (243) — 语言资源安装
  - `label(for:)` (258) / `hint(for:)` (262) — 档位文案
  - `rebuildAvailability()` (273) — 可用性一次算好（主 actor 外）
  - `assetLabel` (289) — 资产状态文案
  - `metaLine(_:)` (297) — 结果元信息行

## App/Features/Voice/VoiceGuidedViews.swift
- `VoiceReminderDraftView` (13) — FR17.10 语音提醒设定（一句话→抽取→确认→调度）
  - `var body` (29) — 转写输入 + 听写按钮 + 确认卡挂载
  - `buildDraft()` (98) — 文法抽取 + 时间可解析守卫
  - `commit(_:)` (117) — 调度提交（写库结果决定清稿）
- `VoiceGuidedProfileView` (152) — FR17.11 语音引导式档案访谈
  - `steps` (161) — 访谈四步
  - `InterviewPhase` (171) — 三阶段（隐私卡/测麦/访谈）
  - `var body` (191) — 按阶段分派 + 拒绝卡 + 确认卡
  - `voiceConsentRecorded` (255) / `recordVoiceConsent()` (259) — FR17.12 一次性同意
  - `commitFields(_:)` (266) — 逐字段落库（任一失败即停）
  - `interview` (288) — 访谈视图（提问朗读 + 跳过/下一步）
  - `interviewDoneView` (344) — 完成态（按写入/跳过数如实报告）
  - `buildDraft()` (369) — 步骤草稿（计划语境修改拒绝 BR-003/006）
- `RejectionBox` (389) — 拒绝对象 sheet 包装（Identifiable）

## App/Features/Voice/VoiceInputTemplateView.swift
- `AudioRouteMonitor` (26) — FR17.13 音频路由监听（耳机感知）
  - `start()` (33) / `stop()` (49) — 幂等观察者注册/注销
  - `refresh()` (54) — 路由刷新（耳机端口集）
- `VoiceConfirmSheet` (66) — 统一确认卡（四处语音入口唯一确认 UI）
  - `script` (100) — 回读脚本（BR-003：按即将保存的取值）
  - `applyingEdits()` (116) — 编辑应用 + 全体确认（脚本与保存同源）
  - `showsAsk` (132) / `binding(for:)` (137) — 询问态/字段绑定
  - `label(for:)` (148) — 字段友好标签（MetricType 单一映射）
  - `bystanderWarning` (164) — 旁人警告判定
  - `var body` (169) — 判定行/字段列表/回读/操作按钮
  - `showRouteToast()` (357) — 路由切换 Toast（2 秒消退）
- `VoicePrivacyHeadphoneCard` (372) — FR17.12 一次性须知卡
- `VoiceModificationRejectionCard` (416) — 语音受限修改拒绝卡（BR-003/006）
- `VoiceConfirmSheetPresenter` (452) — 确认卡装配单出口（回读决策 + TTS 注入）
- `View` 扩展 `voiceConfirmSheet(...)` (489) — 挂载入口
- `VoiceIntentDispatch` (508) — 期一可分发意图目录
  - `dispatchableKeys` (509) — 有目标页消费者的意图键
  - `candidateKeys` (522) — 候选去向行（可分发 ∩ 可自动分类）

## App/Features/Voice/VoiceLevelCheckView.swift
- `VoiceLevelCheck` (17) — 语音访谈前置音量自检（测试句朗读 + 实时音量条）
  - `tooLow` (26) — 音量过低派生（阈值单点）
  - `var body` (28) — 音量条 + 提示 + 通过/跳过
  - `stopAndPass()` (88) / `stopAndSkip()` (89) — 离场动作
- `VoiceLevelMeter` (96) — 麦克风实时电平（AVAudioEngine tap + RMS）
  - `lowThreshold` (98) — 判定阈值
  - `start()` (108) — 会话激活 + tap 安装（10Hz 节流）
  - `stop()` (141) — 拆除（对称还原会话状态）

## App/Features/Voice/VoiceNoteViews.swift
- `VoiceNoteState` (12) — FR17.14 语音速记状态仓
  - `load(patientId:)` (20) — 列表加载（BR-001）
  - `perform(patientId:_:)` (34) — 写操作统一出口（失败返回 false）
  - `refreshIfCurrent(patientId:)` (48) — 写后刷新（不重盖加载标记）
  - `create(...)` (60) / `update(...)` (67) / `delete(...)` (75) — 读写三件
- `VoiceNotePanelView` (82) — 语音速记面板（SP-59）
  - `var body` (96) — 列表/输入区 + 确认卡 + 详情 sheet
  - `currentPatientId` (213) — 当前成员
- `VoiceNoteDetailSheet` (218) — 速记详情/编辑（正文/标签/入轴/删除）

## App/Features/Voice/VoiceQuickLaunchView.swift
- `VoiceQuickLaunchView` (25) — FR17.9 全局语音快速入口（SP-55 全屏工作台）
  - `refinerEnabled` (59) / `accumulatedText` (60) / `transcriptVersion` (61) / `revision` (62) / `refining` (63) — 转录派生
  - `sourceSnapshot` (64) / `effectiveText` (68) / `previewOnly` (69) — 授权快照派生
  - `warmUpKey` (71) — 预热键（语言/档位变化重预热）
  - `var body` (77) — 麦克风/编辑区/双版本分段/操作区/确认卡
  - `ensureModel()` (321) — 转录模型装配
  - `invalidateConfirmation()` (337) — 确认态清空
  - `stopRefinement()` (350) / `revokeRefinement()` (356) — 修正态终止/撤销
  - `selectVersion(_:)` (365) / `editTranscript(_:)` (373) — 版本切换/手编
  - `appendSegment(_:confidence:)` (383) — 录音段追加
  - `clearLastSegment()` (393) / `clearAllSegments()` (402) — 清除
  - `confirmFromTranscript()` (412) — 确认（冻结来源 + 应急前置）
  - `refineCurrentText()` (441) — LLM 修正请求
  - `understand(source:confidence:patientID:)` (470) — 共享理解层判定（FR17.18）
  - `target(for:)` (494) — 意图 → 分发目标
  - `startDispatch(_:)` (505) / `retryDispatch()` (518) — 分发启动/重试
  - `dispatch(_:source:patientID:intent:)` (529) — 落库分发（速记/暂存路由）
  - `open(_:)` (571) — 目标页导航

## App/Features/Voice/VoiceRouteAdapters.swift
- `VoiceReminderDraftRouteView` (9) — FR17.10 挂载适配（调度通道注入）
- `VoiceNotePanelRouteView` (28) — FR17.14 面板路由
- `VoiceGuidedProfileRouteView` (45) — FR17.11 访谈挂载适配（字段提交注入 + 换人重建）

## App/Features/Voice/VoiceSessionView.swift
- `VoiceSessionState` (27) — F19 关怀语音会话状态仓（状态机镜像 + 事件渲染）
  - `engineState` (28) / `caption` (29) / `options` (30) / `pendingObject` (31) — 引擎镜像
  - `rejected` (32) / `isListening` (33) / `ended` (34) — 会话标志
  - `clearPendingObject()` (38) / `clearRejection()` (42) / `end()` (43) / `start()` (44) — 状态操作
  - `systemFeedback(_:speak:)` (51) — 反馈句（不进状态机）
  - `systemFeedback(success:failure:speak:perform:)` (58) — BR-004 写库结果决定播报
  - `presentOptions(_:for:speak:)` (71) — 多命中列选相位
  - `pause()` (83) / `resume()` (84) — 前台生命周期（FR19.1）
  - `submit(_:speak:)` (90) — 输入一轮 → 渲染事件 → 返回执行命令
- `VoiceSessionLaunchCard` (136) — 关怀模式首页入口大卡
- `VoiceSessionView` (173) — 会话视图（聆听指示/字幕/列选/复述/拒绝/键盘降级）
  - `var body` (194) — 会话主界面
  - `captionBlock` (280) / `optionsBlock` (294) — 字幕/列选块
  - `repeatConfirmBlock` (320) — 拨号复述确认（FR19.5）
  - `rejectionBlock` (347) — 拒绝卡（删除/剂量变更引导触屏）
  - `listeningIndicator` (369) — 聆听状态（门控诚实：未接通不渲染「正在聆听」）
  - `handleChoice(number:)` (391) — 列选应答
  - `handleExecution(_:object:)` (402) — 执行矩阵分派（清候选/载荷消费后逐命令转发）
  - `executeCall(_:)` (458) — 拨号（复述确认后）
  - `executeNavigation(_:)` (467) — 时间轴/首页导航
  - `executeExitSession()` (479) — 退出会话（FR19.6 保持位置）
  - `executeTodayMeds(object:)` (487) — 附表①今日用药分页
  - `executeNextAppointment()` (499) — 附表②下一预约
  - `executeRecentGlucose()` (513) — 最近血糖（recentValues 直查）
  - `executeStockRemaining(object:)` (530) — 附表③余量
  - `executeStockLocation(object:)` (548) — 附表④存放位置
  - `executeStockExpiry(object:)` (563) — 附表⑤有效期
  - `executeExpiringSoon()` (586) — 附表⑥临期清单
  - `executeAskMedicationTaken()` (591) — 附表时段服药回读
  - `executeMarkTaken(object:)` (606) — 附表②标记已服用（BR-004 逐条确认）
  - `executeRecordMetric(object:)` (660) — 附表⑦记录指标（文法抽取 + 合理性界限）
  - `executeRecordQuestion(object:)` (736) — 附表⑧问诊速记
  - `executeStartCamera()` (749) — 附表⑩拍摄
  - `executeOpenSearch(object:)` (755) — 搜索词注入 + 全局搜索
  - `metricType(for:)` (763) — 文法键 → MetricType
  - `markTakenOptionLabel(_:)` (770) — 列选唯一标签（BR-004 反查）
  - `speakTodayMedsPage(_:page:)` (777) — 附表①分页播报
  - `routeEmergencyIfNeeded(_:)` (800) — BR-012 紧急关键词前置
  - `performCall(_:)` (808) — 联系人解析拨号（精确名/唯一子串/不可拨即播报）
  - `matchingLots(_:)` (851) — 药名匹配批次（InventoryRules 出口）
  - `expiringSummary()` (860) — 附表⑥三级分组播报（BatchExpiryRules）
  - `endSession()` (892) — 结束会话


## App/Features/Settings/AppSettingsStore.swift
- `AppSettingsStore` (12) — F14 设置状态仓：桥接 Infrastructure SettingsStore actor，同步 UserDefaults 冻结键镜像（分裂脑防护全在此层）
  - `var values: [AppSettingKey: String]` (13) — 全部设置键值缓存（读侧口径一律按键默认值解析）
  - `var authAIRevision` (14) — AI 授权代际（守卫陈旧授权写入）
  - `var auditEntries: [AuditEntry]` (19) — 审计展示列表（loadAudit 填充）
  - `struct AuditEntry` (25) — 审计行视图模型（action/entityType/at）
  - `func load()` (40) — 批量装载全键值（代际守卫：装载期间有写即弃）
  - `func seedMirrorsIfNeeded()` (63) — 升级后把 DB 值回填 UserDefaults 镜像（只补不覆盖，幂等）
  - `func set(_ value: String, for key: AppSettingKey)` (88) — 单键写入：入口校验→授权串行链→审计→TOCTOU 复核→镜像双写
  - `func syncRuntimeMirror(_ value: String, for key: AppSettingKey)` (170) — 运行时镜像同步（readback/careMode 写 Bool/通道/TTS 冻结键）
  - `func restoreDefaults()` (193) — 恢复默认：授权链+settings.reset 审计+镜像清理+语言缓存复位+重载
  - `func clearLegacyRuntimeMirrors()` (249) — 清 readback/careMode/旧键 "careMode" 镜像（恢复默认路径）
  - `static var careModeTruth: Bool` (257) — 关怀模式运行时真源（UserDefaults 权威，含旧键兼容）
  - `static let mirroredKeys: [AppSettingKey]` (271) — 通道/横幅/TTS 冻结键镜像集合（补种与复位同源）
  - `func loadAudit()` (282) — 装载审计列表

## App/Features/Settings/AppEntitlementStore.swift
- `AppEntitlementStore` (14) — SP-61 权益状态仓：桥接 EntitlementStore，五时机弹墙调度+24h 频控持久化
  - `var owned / aiMonthlyUsed / lastShownAt` (15) — 已购产品集 / AI 月度用量 / 各触发点最近展示时刻
  - `func load()` (28) — 装载权益状态
  - `func restoreShownAt()` (45) — 从 UserDefaults 恢复弹墙频控（解码失败归零）
  - `func persistShownAt()` (59) — 弹墙频控落 UserDefaults
  - `func purchase(_:)` (65) — 购买（成功即入 owned）
  - `func restore()` (78) — 恢复购买；失败返 nil 区分「无记录/出错」
  - `func shouldShowPaywall(trigger:now:)` (90) — 频控判定委托 Domain PaywallRules
  - `func markShown(trigger:at:)` (96) — 记录展示时刻并持久化
  - `func recordAIUse()` (101) — AI 额度计数
  - `func evaluateTrigger(_:now:)` (117) — 五时机标准入口：判定+标记+置 pendingPaywallTrigger
  - `var pendingPaywallTrigger` (125) — 待展示弹墙触发器（PaywallHost 观察）
  - `func clearPendingPaywall()` (126) — 清待展示触发器

## App/Features/Settings/AppearanceViews.swift
- `AppTheme` (7) — FR14.4 外观主题三态（light/dark/system）
  - `var colorScheme: ColorScheme?` (11) — 主题→系统配色（nil=跟随系统）
  - `case light / dark / system` (8)
- `AppearanceRules` (22) — FR18.16 叠加规则纯函数：高对比度生效=手动开 OR 关怀模式
  - `static func highContrastEffective(highContrastEnabled:careMode:)` (23) — 叠加判定
- `AppSettingsBindings` (30) — 设置绑定统一工厂（主题/布尔读口径三处复制收敛一处）
  - `static func bool(_:for:)` (33) — 布尔读统一口径（values 未装载落键默认值）
  - `static func theme(_:)` (38) — FR14.4 主题 Binding（DB 值→AppTheme，即时生效）
- `ThemeSettingsView` (54) — 外观设置页：三段选择器+高对比度开关（关怀模式强制叠加明示）
  - `var body` (58) — 渲染设置表单
  - `var themeBinding` (81) — 主题绑定（工厂委托）
  - `var highContrastBinding` (85) — 高对比度开关绑定
- `ThemeSegmentedPicker` (95) — 水平三段主题选择器+迷你预览
  - `var body` (98) — 渲染三段选择器
  - `func segment(for:)` (111) — 单段按钮（选中态品牌描边+对勾语义）
  - `func label(_:)` (138) — 主题→L10n 标签
- `ThemePreviewSwatch` (148) — 迷你预览色块（浅/深/半白半黑）
  - `var body` (151) — 渲染三态预览
  - `func swatch(background:bar:)` (170) — 单色预览色块绘制

## App/Features/Settings/SettingsViews.swift
- `SettingsView` (7) — F14 设置中心：授权开关/外观/安全/通知/习惯/数据/Pro/隐私/关于分组
  - `var body` (13) — 渲染设置表单全部分组
  - `var authKeys` (200) — 可执行授权开关键集（仅真实生效项）
  - `func binding(for:)` (204) — 授权开关绑定（careMode 读运行时真源/其余统一布尔口径）
  - `var themeBinding` (227) — 主题绑定（工厂委托）
  - `var currentLanguageName` (231) — 当前语言原名
  - `func label(for:)` (236) — 开关键→L10n 标签
- `AuditLogView` (255) — FR14.2 审计记录页（append-only 事实列表）
  - `var body` (257) — 渲染审计行列表

## App/Features/Settings/BackupViews.swift
- `BackupState` (19) — FR13.11 备份状态仓：fileExporter/Importer 四态+ADR-019 冲突裁决
  - `var onRestored` (24) — 恢复末步回调（重建提醒投影）
  - `enum Phase` (25) — idle/working/exported/restored/conflicts/degraded
  - `var pendingAnalysis / resolutions` (40) — 已校验冲突分析（复用不二次哈希）/逐项裁决（默认保留本机）
  - `var iCloudSignedIn` (49) — iCloud 登录态快照（令牌查询+变更通知刷新）
  - `func prepareBackup()` (64) — 创建备份信封（失败不归罪空间不足）
  - `func restore(from:)` (79) — 恢复：detached 读文件→冲突分析→直接恢复或进裁决
  - `func setResolution(_:_:)` (117) — 单条冲突裁决
  - `func applyConflicts()` (122) — 应用裁决并恢复
  - `func cancelConflicts()` (141) — 取消裁决（回 idle）
  - `func clearDocument()` (147) — 清导出文档
- `BackupDocument` (153) — FileDocument 字节包装（.data/.json 双格式）
  - `static var readableContentTypes` (154)
  - `func fileWrapper(configuration:)` (160)
- `BackupView` (165) — SP-24 备份与恢复页：门禁验证+隐私确认+冲突预览 UI
  - `var body` (177) — 渲染列表+阶段分支+导出/导入器+确认弹窗
  - `func conflictKindLabel(_:)` (339) — ADR-019 表名→可读类别
  - `func conflictChoice(_:)` (348) — 冲突裁决绑定

## App/Features/Settings/DisclosureViews.swift
- `L2DisclosureSheet` (7) — FR20.3 L2 首用须知半屏 Sheet（我知道了+落 ConsentRecord）
  - `var body` (12)
- `L3DisclosureBanner` (56) — L3 常驻微文案（可折叠不可关闭）
  - `var body` (60)
- `SceneDisclosureModifier` (98) — 场景须知修饰器：按 level 分流 L2 sheet / L4 弹窗
  - `func body(content:)` (107)
  - `func checkAndShowDisclosure()` (138) — 版本感知确认检查+呈现分流
  - `func findDisclosure()` (153) — 场景→须知条目
- `extension View` (159) — 修饰器入口
  - `func sceneDisclosure(scene:level:)` (161)

## App/Features/Settings/ExportWizardView.swift
- `ExportWizardState` (13) — FR13.2 导出向导状态机：四态+代际守卫防取消后旧任务覆盖
  - `enum Phase` (14) — idle/working(processed,total)/finished/degraded
  - `var exportURL` (22) — 导出 PDF 临时文件
  - `func run(_:)` (32) — 启动导出（进度回调同代校验；CancellationError 独立态）
  - `func cancel()` (63) — 取消导出任务
  - `func reset()` (67) — 复位状态机
- `ExportWizardView` (73) — SP-22 导出向导：范围→内容开关→门禁验证→进度→分享
  - `var body` (87) — 按 phase 分支渲染（idle 表单/进度/完成/失败）

## App/Features/Settings/FeedbackView.swift
- `FeedbackView` (9) — FR22.5 反馈页：六类分类+附件逐项勾选（默认只附脱敏日志）
  - `var categories` (19) — 六类反馈名称（L10n 三文件）
  - `var body` (21)

## App/Features/Settings/HelpViews.swift
- `AuthorizationStatusLabel` (11) — 系统权限状态→L10n 文案（权限诊断/提醒诊断共用口径）
  - `static func notification(_:)` (13) — UNAuthorizationStatus→文案
  - `static func capture(_:)` (24) — AVAuthorizationStatus（相机/麦克风）→文案
- `HelpRootView` (35) — F22 帮助中心根：七类教程+三诊断+关于
  - `var body` (38)
  - `var helpTopics` (92) — 教程条目表
- `HelpTopicView` (106) — 教程主题页（语音主题带朗读出口）
  - `var body` (111)
- `HelpPermissionDiagnostics` (137) — FR22.2 权限诊断（相机/麦克风/通知/FaceID，只引导不循环弹框）
  - `var body` (143)
  - `func checkPermissions()` (168) — 四类权限状态探测
- `PermissionRow` (182) — 权限诊断行
  - `var body` (187)
- `HelpReminderDiagnostics` (203) — FR22.3 提醒诊断（权限/待处理剂量/今日时段）
  - `var body` (209)
  - `func checkNotificationStatus()` (249) — 通知权限状态读取
- `HelpDataHealth` (258) — FR22.4 数据与存储健康（PRAGMA 实测完整性/大小/最近备份）
  - `var body` (264)
  - `func checkHealth()` (296) — 实测库大小+完整性+最近备份时间戳
- `HelpAboutView` (324) — FR22.8 关于页（三部件版本+许可+法律）
  - `var buildInfo` (326) — 版本三部件组装
  - `var body` (334)

## App/Features/Settings/LanguageSettingsView.swift
- `LanguageSettingsView` (10) — FR14.5 显示语言选择器（zh-Hans/zh-Hant，切换即时生效）
  - `var current` (14) — 当前语言码
  - `var body` (18)
- `VoiceInputLanguageRules` (57) — FR17.15 输入语言点选规则纯函数（追加/提升为主/取消保底一项）
  - `static func toggled(_:selecting:)` (58) — 点选变换；不足两项取消返回 nil
- `VoiceLanguageSettingsView` (79) — FR17.15/16 语音语言设置：输入多选+输出单选+引擎实验室入口
  - `var outputLang` (90) — 输出语言（app.voiceOutputLocale）
  - `struct T2Info` (97) — T2 说明卡载体
  - `var inputLanguageOptions` (103) — 输入语言选项（Domain 单一出口派生）
  - `var body` (110) — 渲染输入/输出语言列表+混合输入开关+实验室入口
  - `func load()` (254) — 先等 settings.load 再读多语言集合（写前读竞态防护）
  - `func toggleInput(_:)` (266) — 点选并持久化（规则委托 VoiceInputLanguageRules）
- `T2ExplanationSheet` (277) — T2 方言尽力识别说明页
  - `var body` (282)

## App/Features/Settings/PaywallView.swift
- `PaywallHost` (8) — 弹墙宿主：观察 pendingPaywallTrigger 在根层级弹 SP-61（防双弹/漏关）
  - `func body(content:)` (11)
- `extension View` (24) — `func withPaywallHost()` (25)
- `TriggerBox` (28) — PaywallTrigger→Identifiable 包装
- `PaywallView` (36) — SP-61 付费墙：三档产品卡+购买/恢复错误态+信任文案
  - `var body` (42)
  - `func productCard(_:_:detail:)` (90) — 产品卡
  - `func load()` (103)
  - `func purchase(_:)` (106) — 购买（busy 态+失败可见）
  - `func restore()` (112) — 恢复（区分失败/无记录）
- `EntitlementGate<Content>` (124) — 权益门：未解锁=预览态提示升级，绝不阻断
  - `var body` (128)

## App/Features/Settings/PreferencesViews.swift
- `PreferencesView` (9) — FR14.7 常用习惯设置：回读/日期格式/语速（只保留真实生效项）
  - `var body` (19)
  - `func loadValues()` (108) — 载入回读偏好
  - `func save()` (112) — 离页保存（loaded 守卫+ReadbackPolicy 校验）
- `DataLifecycleView` (128) — FR14.3 数据生命周期页：四级删除语义+影响清单确认
  - `var body` (137)

## App/Features/Settings/PrivacyAuthorizationView.swift
- `PrivacyAuthorizationView` (9) — FR14.1 分目的授权面板：八开关+系统权限说明行
  - `var authKeys` (14) — 可执行开关键集（顺序即面板顺序）
  - `var body` (20)
  - `func binding(for:)` (61) — 开关绑定（SettingsRules.resolved 口径，装载前后一致）
  - `static func title(_:)` (78) — 键→面板标题
  - `static func subtitle(_:)` (92) — 键→面板副标题

## App/Features/Settings/ProOutputViews.swift
- `ProOutputHubView` (11) — Pro 产出包入口：六产出预览+五时机 proOutputFirstTap 触发
  - `var products` (18) — 产出表（计算属性：语言切换即时）
  - `var body` (29)

## App/Features/Reminders/ChannelGatedScheduler.swift
- `ChannelGatedScheduler` (29) — FR9.18 系统通知投递门装饰器：按通道偏好跳过无应用内承接类别的系统投递
  - `static func preference(for:)` (37) — notifyId→类别偏好值（未识别回落全局键）
  - `static func shouldSuppressSystem(_:)` (55) — 抑制判定委托 Domain suppressSystemDelivery（含横幅总开关）
  - `func schedule(dose:at:route:)` (63) — 透传调度（抑制类别跳过）
  - `func scheduleRepeating(...)` (68) — 透传重复调度
  - `func cancel(_:)` (75) / `func removeDelivered(_:)` (79) — 透传
  - `func reloadLocalizedContent()` (83) / `func pending()` (87) / `func delivered()` (91) — 透传

## App/Features/Reminders/InAppBanner.swift
- `InAppBannerHost` (9) — §4.22 前台到期用药横幅：确认/稍后 15 分+5 秒自动收起（跨 Tab 顶层 overlay）
  - `var body` (28) — 渲染横幅+自动收起计时任务
  - `var currentBanner` (100) — 触发条件：开关+2h 窗口未处理剂量+排除已收起
  - `func hide()` (116) — 取消计时任务

## App/Features/Reminders/ReminderChannelSettingsView.swift
- `ReminderChannelSettingsView` (15) — §5.58 提醒触达设置：六类三选一+应用内横幅总开关
  - `var categories` (19) — 六类提醒键/名称表
  - `var body` (28)

## App/Features/Reminders/ReminderHubLoader.swift
- `ReminderHubLoader` (17) — FR2.1 聚合中心数据装配（纯映射：各源投影→AggregatedReminderItem，零业务判定）
  - `static func doseItems(_:memberId:)` (24) — 今日时段→聚合行（status 透传 pending/taken/resolved）
  - `static func appointmentItems(_:memberId:)` (41) — 预约→聚合行
  - `static func inventoryItems(_:memberId:)` (54) — 库存续药/补录待办→聚合行
  - `static func alertItems(_:memberId:)` (88) — alert_event 分级映射（L1+ 置顶证据卡入口）
  - `static func ocrItems(_:memberId:)` (108) — 待确认 OCR→聚合行（逾期置顶）
  - `static let profileProgressKind` (123) — 资料完善聚合类别键
  - `static func systemItems(done:total:memberId:)` (125) — 资料完善系统行
  - `static func planId(fromNotifyId:)` (138) — dose-{planId}-{epoch}→planId 解析

## App/Features/Reminders/UNReminderScheduler.swift
- `UNReminderScheduler` (11) — 生产通知适配器：锁屏隐私文案+AppRoute 深链+滚动预排窗口
  - `func schedule(dose:at:route:)` (16) — 一次性触发的排程
  - `static func content(route:)` (24) — 通知内容组装（隐私标题固定+route Codable 入 userInfo+分级中断级别）
  - `func scheduleRepeating(...)` (55) — 重复提醒：逐次一次性触发窗（14/12 针）+旧 -wd 清理
  - `static func isSameFamily(_:as:)` (100) — 同族 id 判定（基础/-occ-/-wd{1..7}，分隔符守卫）
  - `func cancel(_:)` (110) — 同族判定取消（含重复针）
  - `func removeDelivered(_:)` (125) — 同族判定清送达
  - `func reloadLocalizedContent()` (139) — FR14.5 语言切换重写待投递文案
  - `static func isAppOwned(_:)` (164) — 本仓前缀判定（Domain categoryKey 单一事实源）
  - `func pending()` (168) — 待投递 id→触发时刻
  - `func delivered()` (179) — 已送达 id 集

## App/Features/Reminders/ReminderStore.swift
- `ReminderStore` (14) — M1b 提醒状态仓：今日时段聚合+服药动作集+预约闭环+对账/续药/到期/备份/语音提醒调度
  - `var todaySlots / upcomingAppointments / loading` (15) — 今日时段卡/未来预约/加载态
  - `var pendingCount` (23) — 未处理剂量计数（Domain isUnresolved 单一出口）
  - `func refreshTriggered(patientId:now:force:)` (72) — 触发型刷新入口（500ms 去抖+成员例外+force 例外）
  - `func reloadLocalizedScheduledContent()` (90) — 语言切换重写通知文案
  - `func refresh(patientId:now:)` (97) — 加载链：物化→补账→对账→时段聚合→续药/到期/语音续期
  - `func scheduleVoiceReminder(title:fireAt:repeatRule:patientId:)` (163) — FR17.10 语音提醒设定（先簿记后调度）
  - `func scheduleObservationFollowUp(...)` (196) — FR8.10 观察随访提醒
  - `func scheduleBackupReminderIfNeeded(lastBackupAt:now:)` (217) — FR13.10 备份提醒（幂等+划掉防御）
  - `func clearBackupReminderDelivered()` (240) — 备份完成清提醒+武装集
  - `func scheduleRefillReminders(patientId:pending:delivered:)` (265) — FR9.8.3 分级续药通知（≤3 天/当日，ADR-009 偏早）
  - `func scheduleExpiryReminders(patientId:pending:delivered:)` (303) — FR9.11 批次到期三级提醒（30/7/当日）
  - `func confirmTaken(patientId:dose:careMode:)` (334) — 确认服药（震颤防抖+清送达+刷新）
  - `func confirmSlotAllTaken(...)` (354) — FR9.17 时段级全部已服（单次防抖判定）
  - `func skipSlotPending(...)` (374) — 时段级跳过（BR-004 逐剂写 skipped）
  - `func snoozeSlotPending(...)` (390) — 时段级稍后（先调度后记动作）
  - `func skipDose(dose:reason:careMode:patientId:)` (403) — 单剂跳过
  - `func removeDeliveredReminders(for:)` (418) — 清剂量本体+时段通知
  - `func slotNotifyId(for:)` (432) — 剂量→真实时段通知 id 反查（合并时段分叉修复）
  - `func forgetDose(dose:careMode:patientId:)` (452) — 忘记服用（显式 missed）
  - `func recordDiscomfort(dose:note:careMode:patientId:)` (464) — 记录不适（两线各 −1）
  - `func backfillTaken(planId:patientId:medicationId:actualTime:doseUnits:)` (476) — FR9.16 补录服药
  - `func snoozeDose(dose:minutes:patientId:careMode:)` (488) — 单剂稍后（先调度成功再记 .snoozed）
  - `func tremorAccepted(careMode:)` (511) — 震颤防抖门卫（Domain TremorGuard）
  - `func createPlan(patientId:medicationId:name:spec:schedule:startDate:doseUnits:)` (523) — 计划创建（价值先行通知授权）
  - `func createMedication(...)` (534) — 药品创建
  - `func plans(patientId:)` (543) / `func plan(id:)` (547) — 计划列表/单计划
  - `func doseLog(planId:from:to:)` (552) — 本周七日格数据
  - `func lifecycleEvents(planId:)` (557) — 计划历史时间轴
  - `func medicationAdvice(medicationId:)` (562) — FR9.9 医嘱原文
  - `func pausePlan(planId:patientId:)` (566) / `func resumePlan(...)` (578) — 暂停/恢复（立即对账）
  - `func endPlan(planId:reason:patientId:)` (587) — 结束计划（显式携带成员）
  - `func editPlanSchedule(planId:schedule:)` (599) — 编辑排程
  - `func createPlanFromPrescription(prescription:plan:initialLot:)` (605) — 处方→计划五表原子创建
  - `func createAppointment(...)` (617) — 预约创建（复诊规则 1/4 排提醒；返回成败）
  - `func completeAppointment(patientId:id:)` (645) / `func markAppointmentMissed(...)` (655) — 完成/错过
  - `func cancelAppointment(patientId:id:reason:)` (665) / `func rescheduleAppointment(...)` (675) — 取消/改期
  - `func appointmentHistory(patientId:)` (688) — 历史（读失败 nil 保留旧列表）
  - `func appointmentCandidates(forEncounter:patientId:)` (698) — 就诊关联候选（±3 天同医院）
  - `func linkAppointment(id:encounterId:patientId:)` (703) — 用户确认后挂接
  - `func familyPendingDoses(from:to:)` (709) — FR24.5 跨成员待确认剂量
  - `func requestNotificationAuthorization()` (715) — FR20.2 通知授权（价值先行）
  - `var notificationDenied` (726) — 通知权限拒绝态（只读不弹框）
  - `func armedNotificationIds()` (740) / `func markArmed(_:)` (743) / `func unmarkArmed(_:)` (747) — 武装持久集薄委托
  - `func persistedVoiceReminders()` (760) / `func persistVoiceReminder(...)` (763) — 语音提醒登记薄委托
  - `func rearmVoiceReminders()` (769) — 滚动续期重武装
- `ArmedNotificationIds` (787) — 通知武装持久集（UserDefaults）：同 id 本机只武装一次（划掉防御）
  - `var ids` (790) — 已武装 id 集
  - `func mark(_:)` (796) / `func unmark(_:)` (800) — 标记/移除并落盘
  - `func save()` (805) — 写回 UserDefaults
- `VoiceReminderRegistry` (814) — 重复语音提醒持久登记（notifyId→(fireAt,repeatRule)）
  - `func entries()` (817) — 读取登记（损坏条目跳过）
  - `func register(notifyId:fireAt:repeatRule:)` (829) — 登记并落盘

## App/Features/Reminders/RemindersViews.swift
- `RemindersView` (7) — 提醒模块主视图：今日时段聚合卡+服药动作+预约列表
  - `var body` (19) — 渲染今日时段/预约/照护入口+新建 sheet+失败告警
  - `var currentPatientId` (190)
  - `func statusLabel(_:)` (192) — 预约状态→L10n
  - `func statusColor(_:)` (201) — 状态→语义色
- `NewPlanScheduleMapper` (215) — FR9.4 表单→MedicationSchedule 映射纯函数（canSave 与提交同闸门）
  - `static func schedule(kind:timeText:)` (216) — 映射；非法输入返 nil
- `NewPlanSheet` (241) — 用药计划创建 sheet（fixed/interval/meal/asNeeded）
  - `var body` (251)
  - `var scheduleHint` (286) — 按类型输入提示
  - `var canSave` (301) — 可保存判定（名字非空+映射闸门）
- `DoseSlotCard` (313) — 时段卡：药名/规格+动作集+n/N 进度+全部已服按住确认
  - `var takenCount` (329) — 已处理剂量数（taken/discomfort）
  - `var body` (333)
  - `var skipBinding` (461) / `var discomfortBinding` (464) — 弹窗呈现绑定
  - `func submitSkip(_:)` (468) — 提交跳过（默认原因 "skip"）
  - `func actionShortLabel(_:)` (475) — 决议短标签
- `NewAppointmentSheet` (487) — 预约创建最小形态（医院/科室/时间）
  - `var body` (494)

## App/Features/Trends/MetricEntryView.swift
- `MetricEntryValidation` (11) — FR7.5 录入校验纯函数（解析/合理性界限全在 Domain）
  - `enum Failure` (12) — invalidValue / outOfRange
  - `static func validate(primaryText:secondaryText:metric:)` (14) — 校验；返回可落库值对或失败原因
- `MetricQuickEntryView` (49) — SP-13 自测指标两步录入：类型宫格→数字面板→保存入趋势
  - `var metrics` (67) — 六类可录入指标
  - `var body` (70) — 渲染两步表单+语音确认链
  - `func applyConfirmed(_:)` (204) — 语音确认结果→录入框
  - `func applyDraft(_:)` (208) — 草稿预填（grammar 键→指标/双值，sys 恒优先）
  - `func save()` (229) — 校验（收敛 MetricEntryValidation）→写库→成功/失败可见反馈
- `extension TrendEntryState` (257) — 录入/单位记忆/排除接线
  - `func rememberedUnit(for:)` (260) — FR7.8 指标单位记忆读
  - `func rememberUnit(_:for:)` (264) — 单位记忆写
  - `func addSample(patientId:metric:value:secondaryValue:unit:measuredAt:)` (272) — 自测落库（C 级；成功后写回 Apple 健康+刷新宫格）
  - `func toggleExcluded(_:patientId:metricKey:)` (304) — FR7.4 排除/恢复（软删+审计+详情刷新）

## App/Features/Trends/MetricOverviewView.swift
- `MetricOverviewView` (12) — §5.45 指标总览宫格：双列 MetricTile+快速录入/按住说话入口
  - `var columns` (20) — 双列宫格布局
  - `var body` (23) — 宫格/空态分支+语音确认链
- `MetricTile` (107) — 宫格瓦片：大数字+单位+来源点+30 天迷你趋势线
  - `var body` (115)
  - `var metricName` (184) — 指标键→L10n 名（未知键空串）

## App/Features/Trends/TrendEntryView.swift
- `TrendEntryState` (16) — F7 趋势状态仓：详情序列/宫格最新点双轨+代次/身份双守卫
  - `var latestMetrics` (18) — 宫格最新点
  - `var writeBack` (30) — Apple 健康写回注入点（事后装配）
  - `func loadDetail(patientId:metricKey:window:periodEnd:origin:)` (66) — 详情序列加载（三查询并行+身份守卫；未知键拒绝）
  - `func recentValues(patientId:metric:limit:)` (154) — F19 事实播报专用读取（不写槽位）
- `TrendChartRouteView` (163) — SP-13 路由目的地：周期分段+翻页+空态诊断+排除接线
  - `var metricType / isSelf / routeKey / taskID` (181) — 本页身份推导
  - `var currentIdentity` (193) — 当前请求身份（成员/指标校验后采用）
  - `var requestedEnd` (202) — 请求周期末（身份权威值，不重算 Date()）
  - `var identityMatches` (211) — 槽内序列身份/周期逐位同构校验
  - `var matchedSeries / matchedSleep` (216) — 身份匹配的序列槽
  - `var period` (226) — 当前周期区间
  - `var showsConnectGuidance / emptyTitle / emptyHint` (233) — 空态分流文案
  - `var latestOutsidePeriod` (239) — 诊断行与出口按钮同一判据
  - `var canPageForward` (247) — 已翻页才可前进
  - `func page(_:)` (251) — 周期平移（越过今天回落自动锚定）
  - `var body` (255) — 渲染图表/睡眠整合/空态+周期控件
- `TrendPeriodLabel` (391) — SP-13 周期标签（nil=定位中）
  - `var body` (394)
  - `var text` (406) — 周期区间格式化
- `extension TrendEntryState` (414) — 宫格轨
  - `func loadLatest(patientId:)` (416) — 宫格最新点加载（BR-001 守卫）
  - `func refreshLatestIfCurrent(patientId:)` (437) — 写后刷新（不重盖成员标记）
  - `static func gridRows(_:)` (452) — 宫格行过滤+睡眠族折叠单一出口
  - `func refreshDetailIfCurrent(patientId:metricKey:)` (462) — 写后详情刷新（沿用身份）
  - `func setExcluded(night:excluded:patientId:metricKey:)` (483) — 睡眠夜整夜排除（单事务+单审计）

## App/Features/Trends/TrendViews.swift
- `TrendChartView` (16) — F7 指标趋势图：Swift Charts+四条渲染铁律（参考带中性色/空心点/列表 VoiceOver 主通道）
  - `func bandLabel(_:)` (35) — 参考带来源标签（空串回落缺省）
  - `func bandOpacity(_:)` (39) — 参考带不透明度阶梯
  - `func originLegendRow(solid:label:)` (45) — 来源图例行（实心/空心）
  - `var selectedPoint` (56) — 选点最近命中
  - `var selectedPoints` (66) — 同刻并列点（60s 容差收敛）
  - `var xDomainStart / xDomainEnd` (78) — 数据范围首末点
  - `func dataMarks(_:points:axisTime:axisValue:tint:maxGap:)` (85) — H4 按图型族生成数据标记
  - `static func contiguousSegments(_:maxGap:)` (130) — gap 断线连续段切分（纯函数）
  - `func pointMark(...)` (148) — 单点标记（实心/空心描边）
  - `var body` (162) — 渲染图表+图例+选点气泡+全量列表+已排除分段
- `TrendPointBubble` (325) — 选点气泡：值/单位/医院/参考范围/日期+回原报告
  - `var body` (329)
- `TrendPointRow` (376) — 数据行（VoiceOver 主通道+排除/恢复）
  - `var statisticsLine` (384) — 设备统计行（聚合/来源/极值/样本数）
  - `var body` (397)
- `SleepTrendDetailView` (455) — SP-13 睡眠整合页壳
  - `var body` (461)
- `SleepTrendChartView` (471) — 睡眠堆叠柱+阶段图例+逐夜列表
  - `var range` (480) — 查询范围（身份回传；夜集跨度兜底）
  - `var presentStages` (488) — 本窗口出现阶段（图例只列存在的）
  - `var selectedNight` (494) — 选中夜（按日最近）
  - `var body` (501)
  - `var unit` (584) — 单位（可见夜集首个）
  - `func stageTotal(_:)` (588) — 该阶段窗口合计
  - `func durationText(_:)` (594) — 时长+单位拼接
- `SleepStagePalette` (602) — 睡眠阶段配色（分类编码令牌，BR-006 不表达优劣）
  - `static func color(_:)` (603)
- `SleepNightBubble` (616) — 选夜气泡：日期+总时长+逐段明细
  - `var total` (620) — 总时长（asleepHours 优先）
  - `var body` (622)
- `SleepNightRow` (648) — 逐夜行：日期+总时长+分段明细+排除/恢复
  - `var total` (654) / `var breakdown` (656) — 总时长 / 分段明细串
  - `var body` (662)
- `TrendDetailView` (698) — 双来源趋势页面壳
  - `var body` (705)

## App/Features/Medications/InventoryViews.swift
- `InventoryListView` (16) — F9.8 药箱总览：批次卡列表+配药清单导出入口
  - `var body` (21)
  - `func dispenseRows()` (58) — 药箱摘要→配药清单行映射
- `InventoryRow` (69) — 批次卡：药名/规格/续药档位/约剩 N 天/双轨条/校正入口
  - `var body` (73)
- `RefillBadge` (124) — 续药档位徽章（t7/t3/t0）
  - `var body` (127)
  - `var label` (138) — 档位→L10n
- `InventoryReconcileSheet` (150) — FR9.8.7 盘点滑块：拖到实际格数→差异确认→归真写回
  - `var difference` (158) — 物理与账实差
  - `var isEqualToBook` (162) — 容差判等（Domain InventoryRules）
  - `var body` (166)
- `InventoryBar` (220) — §4.11 分段余量条（绿>50%/琥珀 20-50%/红<20%）
  - `var ratio` (224) — 安全线占比
  - `var color` (229) — 占比→语义色
  - `var body` (237)
- `InventoryMonthlyReportView` (254) — FR9.8.5 消耗差异月报（纯事实句式+负清单一票否决兜底）
  - `var body` (259)

## App/Features/Medications/MedicationHelpCardView.swift
- `MedicationHelpCardSheet` (10) — FR9.13a 药品求助卡：多选批次→生成分享（位置照片显式勾选）
  - `var body` (19)
- `HelpCardShareHost` (96) — 系统分享宿主（UIActivityViewController 包装；判 completed 防伪造审计）
  - `func makeUIViewController(context:)` (102)
  - `func updateUIViewController(...)` (118)
- `HelpCardRecipientSheet` (124) — FR24.1 收件人选择（预览+候选/手输+完成回调携收件人）
  - `var body` (134)

## App/Features/Medications/MedicationPlanViews.swift
- `MedicationPlanListView` (10) — FR9.15 计划列表：按计划行→详情（unreadable 降级徽标）
  - `var body` (16)
  - `func load()` (65) — 读取（失败保留旧列表）
- `MedicationPlanDetailView` (80) — 计划详情：头部+日程条+今日剂量+医嘱引用+生命周期+历史
  - `var body` (93)
  - `func lifecycleSection(status:)` (208) — §5.26 生命周期按钮区（随状态变化）
  - `func historySection()` (244) — FR9.15 历史时间轴
  - `func emptyState()` (264) — 加载失败/不存在两态分离
  - `var todayRows` (281) — 今日剂量队列（日历日界）
  - `var planAdviceText` (289) — 医嘱原文占位（Phase 3 挂接点）
  - `func load()` (293) — 计划+历史+七日格并行语义加载（失败清 plan 呈重试态）
  - `func actionLabel(_:)` (326) / `func actionColor(_:)` (337) — 剂量动作→文案/色
  - `func eventIcon(_:)` (346) — 生命周期事件→图标
  - `func eventLabel(_:)` (356) — 事件→L10n（含结束原因）
  - `func endReasonLabel(_:)` (366) / `func endReasonLabelText(_:)` (376) — 结束原因→文案
- `WeekStrip` (383) — FR9.16 日程条：本周七日格（已服✓/漏服!可点补记）
  - `var body` (387)
  - `enum DayCellState` (433) — empty/done/pending
  - `func dayState(_:)` (440) — 单日格三态判定（符号与颜色同源）
  - `func daySymbol(_:)` (451) / `func daySymbolColor(_:)` (459) — 三态→符号/色
- `BackfillSheet` (469) — FR9.16 补记 sheet（实际时间+单剂基线缺失响亮拒绝）
  - `var body` (476)
- `MedicationPlanFormView` (521) — FR9.1-9.3 计划创建表单：处方字段全集+调度+初始批次
  - `var doseParseFailed` (534) — 非空不可解析剂量就地报错
  - `var body` (558)
  - `func save()` (635) — 校验时刻+组装处方/计划/批次→五表原子创建
- `MedicationKnowledgeCardView` (695) — FR9.9 药品知识卡（医嘱原文+储存+BR-006 固定话术）
  - `var body` (700)
  - `func loadAdvice()` (740)
- `PlanStatusBadge` (751) — 计划状态徽章
  - `var body` (753)
  - `var statusLabel` (762) / `var color` (770) — 状态→文案/色

## App/Features/Medications/StockLotViews.swift
- `StockLotDetailView` (9) — SP-17 批次详情：双轨卡/档案卡/编辑/盘点/废弃（过期零用药建议）
  - `enum Phase` (16) — loading/loaded/failed
  - `var body` (26)
  - `func load()` (84) — 批次读取
  - `func summaryItem(_:)` (95) — 批次→盘点摘要投影（两处复制收敛）
  - `func unitKindDisplay(_:)` (105) — 单位种类展示名
  - `func save(_:)` (109) — 编辑保存（失败信号回传 sheet 内呈现）
  - `func content(_:)` (126) — 详情主体组装
  - `func header(_:)` (140) — 头部（过期显著标注，BR-006 零建议）
  - `func statusBadge(_:)` (159) — 状态胶囊
  - `func dualTrackCard(_:)` (167) — 双轨库存卡
  - `func archiveCard(_:)` (180) — 档案卡（效期缺失=待补填）
  - `func archiveRow(_:_:)` (203) — 档案行（空值隐藏）
  - `func actions(_:)` (213) — 编辑/盘点/废弃按钮区
  - `static func statusName(_:)` (239) — 状态→L10n
- `LotEditDraft` (250) — SP-17 编辑草稿值类型
- `StockLotEditView` (258) — 批次编辑 sheet（效期归一当日 23:59:59；失败 sheet 内可见）
  - `var body` (277)
  - `func prefill()` (366) — 表单预填
  - `func save()` (376) — 解析总量→组装草稿→onSave
  - `static func normalizedEndOfDay(_:)` (395) — 效期日期归一（三处同款收敛）

## App/Features/Home/HomeDispositions.swift
- `extension ReminderDisposition` (8) — FR2.1⑦ 滑动处置→文案/图标/色纯呈现映射（语义全在 Domain）
  - `var title` (9) / `var systemImage` (23) / `var tint` (35) — 动作→L10n/SF Symbol/色
- `HomeActionToast` (50) — 首页底部条载荷：撤销（写成功）/重试（写失败），id 为动作代次
  - `enum Kind` (51) — undo(key) / failed(retry)
  - `var autoDismissSeconds` (59) — 失败条 8s / 撤销 5s

## App/Features/Home/HomeView.swift
- `HomeView` (21) — F2 首页：统一提醒聚合中心（SP-04；关怀模式 FR18.5 四大卡覆写）
  - `var rowAnimation` (46) — Reduce Motion 感知行动画
  - `var todayDayKey` (52) — 自然日键（驳回横幅次日重现）
  - `func aggregatedItems(profileCompletion:)` (79) — 各源投影→Domain 聚合唯一出口
  - `func isHidden(_:now:)` (110) — 读侧隐藏判定（Domain hideKeys）
  - `func perform(_:on:)` (116) — 动作分派（导航立即/写类先落库成功才动画）
  - `func write(_:item:)` (138) — 写类动作落库（两阶段；部分成功可幂等重试）
  - `func undo(_:key:)` (170) — 撤销（代次守卫不误清新条）
  - `var actionToastBanner` (190) — 底部撤销/重试条（.task(id:) 代次计时）
  - `var currentWindow` (220) — 时间窗解析（"过去日,未来日"）
  - `var body` (228) — 根视图：关怀/标准分支+工具栏+sheet 群+load 任务
  - `var standardHome` (324) — 标准聚合列表（每帧单次求值纪律；ADR-021 单视图自适应）
  - `var filterHeader` (381) — 筛选区（标题+时间窗 Menu+类别 chips）
  - `func filterChip(_:_:icon:)` (400) — 类别过滤 chip
  - `var windowMenu` (421) — FR2.1a 时间窗 Menu
  - `var windowLabel` (439) — 窗口→L10n
  - `func aggregationRows(_:profileCompletion:)` (453) — 聚合行 ForEach（下载卡/滑动动作/长按）
  - `func dispositionButtons(_:side:)` (499) — 按源动作表生成滑动/菜单按钮
  - `func profileProgressCard(_:)` (508) — FR2.1b 资料完善卡
  - `func modelDownloadCard(_:)` (548) — 模型下载进度卡（独立观察域）
  - `func downloadCardContent(_:)` (572) — 下载卡主体（进度读取只准在此）
  - `func modelDownloadFailedCard(_:)` (644) — 下载失败卡（重试+关闭）
  - `func downloadModeText(_:)` (669) — 传输形态→文案
  - `func detailText(_:)` (677) — 阶段/进度文案
  - `func aggregationRow(_:)` (693) — 聚合行内容（L1+ 级别徽章/L0 注记/置顶）
  - `func open(_:)` (755) — FR2.2 点击直达（待办卡详情 sheet/其余 routeKey 跳转）
  - `func route(for:)` (767) — routeKey→AppRoute（稳定键契约）
  - `var isNewUser` (787) — 新用户判据
  - `var emptyAggregation` (794) — FR2.1c 筛选空态（一键回全部）
  - `var newUserGuide` (811) — 首日引导四任务卡
  - `var notifDeniedBanner` (830) — 通知关闭常驻提示（可关次日重现）
  - `func kindLabel(_:)` (866) — 类别→筛选 chip 文案
  - `var careModeHome` (882) — FR18.5 关怀模式四大卡
  - `var pendingImportRecovery` (915) — 未完成导入恢复条
  - `var pendingLoadFailure` (933) — 待办卡加载失败重试条
  - `var headerTitle` (945) — 成员问候标题
  - `var settingsVoiceEntryVisible` (952) — FR14.7 语音入口显示开关
  - `func load()` (958) — 六仓并发加载+通知拒绝态+归档状态装载
- `GuideTaskCard` (980) — 引导任务卡（done 打勾态）
  - `var body` (986)
- `BigCareCard` (1009) — FR18.5 关怀模式大卡（≥72pt）
  - `var body` (1015)
- `MemberPickerSheet` (1039) — FR2.1① 成员切换抽屉（半屏+当前打勾+添加入口）
  - `var body` (1044)
- `PendingCardDetailSheet` (1082) — 待办卡详情 sheet：跳过字段/已存草稿/原文/继续补全/废弃
  - `var body` (1097)
  - `func loadDetail()` (1251) — 待办卡读取（加载/失败/不存在三态）
  - `func pendingField(_:)` (1261) — 草稿字段行（rejected 删除线）

## App/Features/Observations/ObservationDetailViews.swift
- `ObservationDetailView` (10) — FR8.11 观察详情页（SP-14）：敏感媒体链+行内补充编辑+随访+删除三问
  - `var body` (41) — 四态分支+确认弹窗群+随访 sheet
  - `var navTitle` (113) — 类型名标题
  - `func content(_:)` (119) — 主体：头部/锁定媒体条/字段/底栏
  - `func header(_:)` (135) — 头部（类型+自述标记+查看同组）
  - `func fields(_:)` (171) — 字段分组（已存扩展字段回显/空态）
  - `func row(_:_:)` (206) — 键值行（空值隐藏）
  - `func editor(_:)` (218) — FR8.7 行内编辑表单
  - `func prefill(_:)` (252) — 编辑草稿预填
  - `func save(_:)` (265) — 补充信息保存（可选草稿：未触碰不覆写）
  - `func bottomActions(_:)` (290) — 随访/删除底栏
  - `var followUpSheet` (311) — 随访天数选择
  - `static func markName(_:)` (338) — 自述标记→展示名（L10n 转发）
- `SameGroupSheet` (344) — FR8.5 同组观察条目列表
  - `var body` (348)

## App/Features/Observations/ObservationViews.swift
- `MediaThumbRow` (15) — 缩略图横排（blur 条与创建预览共用；逐张点击可达原图）
  - `var body` (23)
- `ObservationStoreState` (41) — F8 观察状态仓：观察/过敏双轨+敏感资产链（BR-007/008）
  - `var groups / allergies / isLoading / loadFailed / loadedPatientId` (42) — 投影与四态
  - `func createAllergy(patientId:substance:severity:tags:note:allergenKind:occurredAt:)` (71) — FR23.2 过敏三步落库（写后只刷过敏列表）
  - `func deleteAllergy(id:patientId:)` (102) — FR23.6 删除（按所属成员刷新）
  - `func load(patientId:)` (116) — 观察+过敏并发读（BR-001 双向写回纪律）
  - `enum DetailPhase` (145) — loading/loaded/failed
  - `func loadDetail(id:)` (151) — 详情读取（晚到丢弃守卫）
  - `func saveExtended(id:...)` (174) — FR8.7 补充字段行内写回+就地镜像
  - `func deleteObservation(id:)` (210) — FR8.8 删除
  - `func reconcileAssets()` (222) — 启动孤儿资产对账
  - `func wipeMediaFiles()` (233) — FR14.3 媒体目录全清
  - `func create(patientId:kind:description:selfMark:photoData:)` (242) — 保存观察（照片先落资产仓；失败补偿回滚）
- `ObservationListView` (299) — 观察列表：四态+媒体锁定徽标+随访快捷入口+过敏区
  - `var body` (305)
  - `var skeletonState` (343) / `var errorState` (354) / `var emptyState` (371) — §6 三态
  - `var contentList` (383) — 观察组+过敏列表
  - `var currentPatientId` (456)
- `LockedMediaStrip` (462) — BR-007/008 列表内敏感媒体条：只渲染 blur+逐次认证查看原图
  - `var imageCache` (472) — 解码缓存
  - `struct MediaViewerPayload` (474) — 查看器载荷（原图 loader 认证后才拉取）
  - `var body` (482) — blur 行+全屏查看器
  - `static func thumb(id:memberId:state:)` (526) — 单张 blur 读取（缓存+降级）
  - `func openOriginal(assetId:)` (539) — 点击解锁流程
- `ObservationCreateSheet` (551) — SP-14 观察创建：归属确认+类型宫格+媒体+描述（语音确认链）
  - `var maxPhotos` (569) — 相册上限 6 张
  - `var photoData / previews` (582) — 分源存储合成（相机+相册）
  - `var currentMember` (586) — 归属成员
  - `var body` (590)
  - `var memberSection` (695) / `var kindSection` (705) / `var mediaSection` (718) / `var detailSection` (761) — 四分区
  - `func kindCell(_:)` (790) — 类型宫格单元
  - `func appendCamera(_:)` (817) — 相机照片追加（跨源上限钳制）

## App/Features/Emergency/AlertViews.swift
- `LegacyWordingVeto` (22) — BR-006 旧行文案否决（负清单判定收敛一处）
  - `static func isBanned(_:)` (24) — 命中措辞负清单判定
  - `static func sanitized(_:)` (30) — 可上屏串；命中返 nil 调用侧降级
- `AlertHistoryView` (38) — F16 预警历史：级别/指标筛选+证据卡入口+信源原文链接
  - `var events` (53) — 当前成员事件
  - `var filtered` (57) — 级别/指标筛选+时间倒序
  - `var metricOptions` (65) — 指标筛选项
  - `var body` (69)
  - `func sourceEntry(for:)` (149) — 信源条目命中（guidelineID 优先→四元组唯一匹配）
- `EvidenceCardRow` (160) — 五段证据卡行（L1+；引用式提示 ADR-010）
  - `var body` (164)
  - `static func pathText(_:)` (221) — 处置路径文案（旧 path 过负清单）
- `SeverityTag` (234) — 级别徽章（L0-L3）
  - `var body` (237)
  - `var color` (248) — 级别→语义色
- `GuidelineSourceListView` (262) — FR16.4 参考范围来源列表（阈值照抄原文只读）
  - `var body` (265)
  - `func thresholdText(_:)` (301) — 阈值文本行
- `extension GuidelineEntry` (309) — `var thresholdTable` (310) — L1–L3 阈值表投影（列表/详情共用）
- `GuidelineSourceDetailView` (317) — FR16.3/16.4 信源原文详情（B 级徽章+完整阈值表+准入说明）
  - `var entry` (323) — 条目查找
  - `var body` (327)
  - `func content(_:)` (342) — 详情主体
  - `func thresholdRow(_:_:_:_:)` (395) — 单级别阈值行
- `extension AlertEvidenceCard` (409) — `var summaryTitle` (410) — 证据卡摘要行（结构化书目→旧行→指标键逐级回落）
- `AlertEvidenceRouteView` (418) — V3.68 证据卡路由页（成员/资格校验+降级）
  - `var body` (426)
  - `var permitted` (461) — 本人或成员资格

## App/Features/Emergency/EmergencyCareViews.swift
- `EmergencyCardView` (14) — F15 急救卡：四节内容+系统医疗急救卡引导+SOS（两步可达）
  - `var body` (25)
  - `func section(_:items:empty:)` (74) — 卡片节（空态/条目）
- `CardRow` (97) — 血型行
  - `var body` (102)
- `GuideCard` (116) — FR15.2 系统医疗急救卡引导卡（不静默写入）
  - `var body` (120)
- `MedicalIDGuideSheet` (145) — 分步图文引导（用户手动在健康 App 完成）
  - `var body` (148)
- `EmergencyCardSelectorView` (191) — FR15.1 逐项勾选（数据存在≠同意入卡）
  - `var body` (196)
  - `func selectorSection(_:items:)` (208) — 候选节
- `SOSButton` (244) — SOS 两步可达：长按越防误触门槛+二次确认（规则在 Domain SOSRules）
  - `var metrics` (250) — 关怀/标准参数
  - `var requiredHold` (254) — 按住时长（Domain 单一事实源）
  - `var body` (260)
- `SOSOrb` (310) — FR18.6 关怀模式 SOS 悬浮球（环形进度反馈+位移取消）
  - `var body` (320)
  - `func progress(_:)` (390) — 按住进度（TimelineView 帧驱动）
- `SOSHelpView` (404) — FR18.6 全屏求助页：拨 120/联系人/急救卡（BR-012 唯一免门禁）
  - `var contacts` (411) — 已确认紧急联系人
  - `var body` (415)
  - `func dial(_:)` (498) — 系统拨号（失败响亮可见）
- `CareModeSettingsView` (508) — 关怀模式开关与展示参数
  - `var body` (512)
- `extension EmergencyCardItem` (549) — `var displayDetail` (553) — 展示 detail L10n 组装（存储层零中文拼串）

## App/Features/Health/DeviceConnectionView.swift
- `F16DeviceState` (9) — SP-29 设备连接状态仓：可见性三态/同步/特征型候选/写回
  - `enum Phase` (10) — idle/syncing/done(count)/degraded
  - `var availabilityProbed` (20) — 能力是否已探测（未探测≠不支持）
  - `var isSyncing` (35) — 同步谓词由 phase 派生（单一事实源）
  - `func pageState(enabled:)` (45) — FR16.1 可见性三态（Domain HealthImportVisibility）
  - `var importedRowCount` (51) — 仪表盘六类型行合计
  - `func requestAuthorization(authEnabled:)` (56) — 请求授权（unavailable/未完成/缺本人/禁用分态）
  - `func permissionRevoked()` (89) — 撤销即时生效（取消在途同步）
  - `func currentAuthorization()` (95) — 探测可用性+回填报告（.degraded 保留到重新同步）
  - `func sync(authEnabled:quietStart:quietEnd:maxRounds:)` (113) — 全量同步（轮询下沉服务层；取消非失败）
  - `func refreshDashboard()` (156) — 仪表盘六查询（缺本人独立态）
  - `func requestRegistrationPrefill()` (178) — 首启注册预填（特征型读取；失败调用方静默回落）
  - `func refreshCharacteristicCandidates(profile:)` (185) — 本人档案对比生成候选
  - `struct WriteSummary` (198) — 写回摘要（written/skipped/failed）
  - `func probeWriteAuthorization()` (207) — 写回分享授权探测
  - `func requestWriteBack()` (215) — 请求写回授权并回传获准状态
  - `func writeBackSample(patientId:metric:value:secondaryValue:unit:measuredAt:)` (232) — 指标写回（开关∧本人∧单位一致才写）
  - `func updateAutomation()` (255) / `func importedRows(kind:before:)` (256) — 后台观察注册/分页行
- `DeviceConnectionView` (263) — SP-29 设置与展示唯一宿主（ADR-021；授权/同步/报告/候选/写回/展示区）
  - `var body` (271)
  - `var healthEnabled` (492) — 读取开关解析
  - `var pageState` (496) — 页面三态（Domain 纯函数）
  - `func preference(_:)` (497) — 开关绑定（关闭 authHealthRead 即撤销；写后按需刷新仪表盘）
  - `func sync()` (511) — 手动同步统一入口（quietHours 解析一处）
  - `func refreshCandidates()` (520) — 以本人档案（导入绑定同源）刷新候选
  - `func fieldLabel(_:)` (526) — 特征字段→L10n
  - `func adopt(_:)` (536) — 采用候选（AppState.updateMember 单一写门）
  - `var writeBackOn` (558) — 写回开关解析
  - `var writeBackPreference` (564) — 写回开关绑定（开启先拿授权，未获准回退关闭）
- `HealthImportedDataView` (582) — SP-29 已导入数据详情：趋势入口+同日折叠日卡+翻页
  - `var healthEnabled` (598) / `var gateOpen` (602) — 开关/门状态（与宿主同判定）
  - `var trendAllowed` (613) — 趋势链接实时判定（行集非空即放宽）
  - `func statisticsLine(_:)` (621) — 设备统计行（与 SP-13 同款构成）
  - `var dayGroups` (636) — 同日折叠分组（日历日键）
  - `func dayBinding(_:)` (649) — 日卡展开绑定（最近一天默认展开）
  - `func healthReadingRow(_:)` (665) — 单条读数行（MedicalNumberFormat.oneDecimal 同趋势页口径）
  - `var body` (692)
  - `func reload()` (771) — 整页重载（代次推进+loading 复位成对）
  - `func load()` (781) — 分页加载（重入守卫+代次校验+BR-001 身份过滤）

## App/Features/Health/HealthTabView.swift
- `HealthTabView` (22) — SP-29 健康 Tab 根：Apple 健康数据展示面（六类行+检索/总览入口）
  - `var body` (27)
  - `var pageState` (51) / `var healthEnabled` (54) — 同 SP-29 判定
  - `var dataSection` (59) — 探测前加载态/探测后页体
  - `var pageBody` (77) — 可见性六态分支
  - `var importedSection` (122) — 六类已导入数据行（归属文案 BR-001）
  - `var entrySection` (193) — 搜索/指标总览入口

## App/Features/Appointments/AppointmentDeepLinkView.swift
- `AppointmentDeepLinkCard` (9) — FR10.6「去挂号」深链卡（本地映射表匹配，无网可用）
  - `var entry` (16) — 精确→模糊匹配条目
  - `var body` (23) — 跳转按钮/未找到文案/预约编号补录

## App/Features/Appointments/AppointmentViews.swift
- `rescheduleSeed(from:)` (11) — 改期种子（过去时刻钳到「现在」；列表/详情同源）
- `AppointmentListView` (18) — SP-18 预约列表：四态筛选+行操作（改期/取消/完成/错过）
  - `var statuses` (33) — 四态筛选档
  - `func scheduledActions(for:)` (38) — scheduled 行操作钮（时间门槛在 Domain）
  - `var body` (73)
  - `var cancelBinding` (209) — 取消弹窗呈现绑定
  - `func submitCancel(_:)` (213) — 提交取消（选填原因）
  - `func load()` (224) — 历史读取（失败保留旧列表）
  - `func statusColor(_:)` (232) — 状态→语义色
- `AppointmentFormView` (246) — 预约表单：字段+复诊规则五种（模糊规则必须落具体日期）
  - `var rules` (266) — 复诊规则档
  - `var body` (268)
  - `func save()` (367) — 创建预约（复诊配置随单保存；失败保留表单）
- `AppointmentDetailRouteView` (394) — §5.45 通知直达详情卡（查不到回落降级）
  - `var body` (402)
  - `func load()` (465) — 历史中查目标（失败保留旧值）
- `extension View` (475) — `func apptRowButton(prominent:)` (476) — 预约行按钮统一样式（≥44pt）

## App/Features/Search/GlobalSearchView.swift
- `SearchViewState` (18) — F12 全局搜索状态：FTS 命中+代际守卫+语音注入一次性投递
  - `var query / docHits / loadFailed` (19) — 查询词/命中/失败态
  - `func setQuery(_:)` (33) — 用户键入（代际推进）
  - `func bumpGeneration()` (41) — 成员切换代际推进（BR-001）
  - `func injectQuery(_:)` (52) — 语音注入（一次性投递语义）
  - `func consumeInjectedQuery()` (58) — 取走即清
  - `func search(patientId:)` (63) — FTS 检索（空词清空；旧代际丢弃；失败独立态）
- `GlobalSearchView` (89) — SP-20 搜索页：五分区命中（文档/语音速记/健康/观察/用药）+防抖
  - `var query` (97) — 输入词
  - `var documentHits / voiceNoteHits` (101) — 命中分流（voice_note 单独成组）
  - `var healthDataHits` (113) — 健康数据命中（本地化名匹配→类型列表页）
  - `var observationHits` (124) / `var medicationHits` (134) — 内存过滤命中（BR-001 守卫）
  - `var allEmpty` (147) — 全空判据（含健康命中）
  - `var body` (151) — 四态+五分区渲染+250ms 防抖
  - `var healthDataSection` (273) / `var documentSection` (288) / `var voiceNoteSection` (304) — 命中分区
  - `func observationSection(_:)` (318) / `func medicationSection(_:)` (344) — 观察/用药分区（参数传入避免每帧重算）
- `SearchResultRow` (366) — 搜索结果行：徽章+标题+片段+日期（敏感命中锁定态）
  - `var body` (375)

## App/Features/Notifications/NotificationCenterState.swift
- `NotificationCenterState` (23) — 通知中心可观察门面：已读/归档语义+写代次守卫（两阶段悲观归档）
  - `var itemStates` (24) — 键→状态
  - `func beginLoad()` (34) — 快照代次（可测竞态）
  - `func applyLoaded(_:requestedKeys:snapshot:)` (37) — 只合并请求键；快照后被本地写不回滚
  - `func load(keys:)` (44) — 装载（读失败保持现状）
  - `func noteLocalWrite(_:_:)` (52) — 本地写（代次+1）
  - `func markRead(_:)` (56) — 标记已读（非破坏性）
  - `func persistArchive(_:)` (62) / `func persistUnarchive(_:)` (63) — 落库
  - `func applyArchived(_:)` (64) / `func applyUnarchived(_:)` (65) — 改可观察态
  - `func archive(_:)` (69) / `func unarchive(_:)` (71) — 悲观两阶段路径

## App/Features/Notifications/NotificationCenterView.swift
- `NotificationCenterView` (11) — FR14.8 通知中心（SP-27）：可行动消息流（用药/预约/临期/预警/OCR）
  - `var body` (31) — 五分区+归档失败重试弹窗+load 任务
  - `var pendingDoses` (163) — 待处理剂量（±30min 容差 Domain 单一事实源）
  - `var appointments` (169) — 未来预约
  - `var visibleAppointments` (174) — 归档过滤后可见（节头/行/空态同源）
  - `func aptKey(_:)` (180) / `func lotKey(_:)` (184) / `func alertKey(_:)` (187) — 归档键（Domain 单一编码）
  - `var expiringLots` (192) — 临期批次（30 天窗口）
  - `var visibleExpiringLots` (200) / `var visibleL1Alerts` (208) — 归档过滤后
  - `var l1Alerts` (204) — L1+ 预警（本人+qualified）
  - `var pendingOCRCount` (214) — 待确认 OCR 数
  - `func state(for:)` (218) — 键状态（缺省 unread）
  - `func loadStates()` (222) — 归档键装载（只合并请求键）
  - `func markRead(_:)` (232) — 已读标记
  - `func archive(_:)` (237) — 悲观归档（失败弹重试）
  - `func archiveAction(_:)` (246) — 归档滑动按钮（非 destructive）
  - `var allEmpty` (251) — 空态判据（与行可见性同源）
- `PendingDoseRow` (261) — 待处理剂量行（独立子视图控制类型检查预算）
  - `var body` (265)

## App/Features/Caregiving/CaregiverViews.swift
- `CaregiverViews` (14) — FR24.5 同机照护者视图：跨成员代确认入口（BR-001 落回所属成员）
  - `var body` (27) — 禁用说明态/待办列表+分钟级墙钟推进
  - `func loadPendingDoses()` (106) — 跨成员聚合读取（窗口含前一日；失败保留旧列表）
  - `func confirmOnBehalf(of:)` (122) — 代确认（成功后写「由你代确认」审计）


定位口诀：套件声明带 `// binds: SU-xxx`（gate-suites.tsv 的 token 来源）；SU 编号 → 阶段（M0/M1a/M1b/M1c/M15/M2），FR 编号 → function-spec 功能需求。fixture 建造器统一收敛在 TestStoreFixtures.swift / HealthImportTestSupport.swift / MatchedCardTestSupport.swift。

## Tests/VitaLiberTests/AuthorizationReloadTests.swift
- `AuthorizationReloadTests` (10) — SU-M1c-FR14（BR-010）：授权重载不得撤销在途的「拒绝」写
  - `test_failedDenialStaysClosedUntilAnExplicitGrant()` (11) — 注入写入失败触发器 → 拒绝落库失败仍保持关闭态，显式授权后 revision 前进
  - `test_WALReloadCannotReplaceAnOutstandingDenial()` (29) — WAL 库 + 阻塞写并发：load() 不得用旧读覆盖在途拒绝；持久层终态与内存一致

## Tests/VitaLiberTests/CardKindIconTests.swift
- `CardKindIconTests` (10) — SU-M1c-REGRESSION（ui-ux §3.4 卡类图标表 / BR-004 色按类型）
  - `test_timelineAllTypesHaveSymbols_v27TwelveKindsNoDocumentFallback()` (12) — 时间轴全类型有符号；v27 十二类不回落 doc.text；各锚点符号逐类钉死
  - `test_registeredCardKindsNoDocumentFallback_unknownKeyFallsBack()` (31) — 注册卡类字符串不回落文档图标；未知键回落 doc.text
  - `test_encounterCardKindsAndSubKindsMergeIntoSameTable()` (41) — 就诊关联卡类 / RecordChildKind / HubKind 三路归并同一符号表
  - `test_documentStableKey_structuredTargetPrimaryIcon_attachmentOnlyFallsBack()` (60) — 文档稳定键 → 结构化目标首卡类图标；仅附件文档键回落

## Tests/VitaLiberTests/ClaimAcceptanceTests.swift
- `ClaimAcceptanceTests` (11) — SU-M2-CARE（FR13.7 报销票据落库纯事实）
  - `test_entryAndSummaryPureFacts()` (19) — 录入 + totals 纯事实汇总（数量/金额/币种），组装句不含建议
  - `test_summarySentencesAvoidReimbursementAdviceWords()` (38) — 汇总句过报销判断词黑名单（可报销/建议/应该）
  - `test_memberIsolation()` (53) — BR-001 跨成员票据隔离
- `makeStore()` (13) — 夹具：内存库 + 报销测试成员（经 TestStoreFixtures.inMemoryWithPatient）

## Tests/VitaLiberTests/DeviceStateTests.swift
- `DeviceStateTests` (14) — SU-M2-F16（子项目 C6）：F16DeviceState 三态映射（缺本人 ≠ 同步失败；关闭优先）
  - `test_missingOwnerMapsToOwnerMissingStateNotSyncFailed()` (30) — 缺 local_owner → .ownerMissing 独立状态，phase 保持 .idle
  - `test_pageStateFollowsBindingAndImportedRows()` (44) — 绑定 + 已导入行驱动 .notConnected/.connectedEmpty；趋势链接可用性
  - `test_syncWithToggleOffPresentsDisabledNotGenericFailure()` (60) — run() 抛 disabled → 状态呈现「已关闭」而非通用失败
- `makeState(seedOwner:)` (16) — 夹具：内存库（可选 Owner 种子）+ HealthImportStore + F16DeviceState
- `F16StubProvider` (76) — HealthReadingProvider 桩：设备可用、任何道空页、快照抛错

## Tests/VitaLiberTests/DictationPressStateTests.swift
- `DictationPressStateTests` (5) — SU-M15-VOICE（FR17.1 按住说话按压状态机）
  - `test_shortPressTogglesExactlyOnce()` (6) — 轻点 = 开关；cancel 后无动作
  - `test_recognizedHoldStopsInsteadOfTogglingOnRelease()` (13) — 识别过的长按抬手 = stop 而非 toggle；重复识别拒绝
  - `test_cancelledPressCannotBeStartedByItsLateTimer()` (22) — 迟到的旧计时器不得启动已取消按压
  - `test_holdThresholdIsLongerThanANormalTap()` (35) — 阈值 0.4–1.0s 长于普通点击；纳秒出口与秒值同源

## Tests/VitaLiberTests/DocumentsFieldDisplayTests.swift
- `DocumentsFieldDisplayTests` (11) — FR6.9 展示层映射：canonical raw → 本地化；未知值/自由文本透传
  - `testKindMapsEveryEncounterKindToLocalizedName()` (19) / `testKindUnknownRawPassesThroughUnmapped()` (25) — kind 枚举全映射；未知透传
  - `testDocTypeKeysMapToLabels()` (32) / `testDocTypeUnknownValuePassesThrough()` (44) — doc_type/document_type 稳定键标签；未知透传
  - `testItemTypeMapsAllThreeCanonicalValues()` (53) / `testItemTypeUnknownValuePassesThrough()` (59) — 报销类型三值；透传
  - `testUnitKindMapsCanonicalSet()` (65) / `testUnitKindUnknownPassesThrough()` (71) — 剂型名已知集；透传
  - `testCurrencyCNYMapsToLocalizedName()` (77) — CNY 本地化、USD 透传
  - `testDiagnosisTypeMapsEveryCanonicalValueAndPassesUnknownThrough()` (84) / `testReportTypeMapsEveryCanonicalValueAndPassesUnknownThrough()` (94) — 诊断/报告类型 CHECK 枚举全映射 + enumOptions 出口
  - `testOtherKeysPassThroughUntouched()` (105) — 药物名/医院/指标键原样透传
- `display(_:_:)` (13) — fieldValueDisplay 简写

## Tests/VitaLiberTests/DocumentTypeKeyBackfillTests.swift
- `DocumentTypeKeyBackfillTests` (13) — SU-M2-PENDINGCARD（FR5.5 文档稳定键首启回填 · 原 D3-2）
  - `test_legacyLabelLookup_threeLanguages_missBecomesCustom_existingKeyPassesThrough()` (42) — 旧标签三语反查；未命中 custom；已键者直通
  - `test_orchestration_idempotent_successSetsMarker_failureLeavesMarkerForRetry()` (63) — 编排：失败不置标记、重试只补未写行、成功后零访问
  - `test_realStore_oldRowsBackfilled_keyedRowsUntouched_batched_idempotent()` (97) — 真实仓：跨成员旧行分批回填、带键新行不动、幂等
  - `test_realStore_writeFailureLeavesMarker_retryAfterFixCompletes()` (127) — 触发器模拟写失败 → 未置标记，修复后重试补齐
- `defaults()` (14) — 独立 UserDefaults suite；`storeFixture()` (22) — 两成员 + 文档仓；`legacySave(_:patient:label:sha:)` (36) — 旧标签形态入库

## Tests/VitaLiberTests/EmergencyCardAcceptanceTests.swift
- `M2EmergCardAcceptanceTests` (14) — SU-M2-EMERG / SU-M2-CARE（FR15.1 逐项选择；BR-003；迁移 v4）
  - `test_unselectedExcluded_selectedIncluded()` (23) — 数据存在 ≠ 入卡；退选只删选择行不删数据源
  - `test_unconfirmedItemsExcluded_domainCriterion()` (54) — EmergencyCardService.assemble 过滤 confirmed=false
  - `test_emptyCardGuidesAndDoesNotWrite()` (68) — 空卡触发系统医疗急救卡引导；无静默写入面
  - `test_bloodTypeCarriedIntoCard()` (79) — 血型随卡带出
  - `test_migrationV4SelectionTableUsable()` (87) — 迁移 v4 emergency_card_selection 建表可写

## Tests/VitaLiberTests/HealthAlertAcceptanceTests.swift
- `HealthAlertAcceptanceTests` (13) — SU-M2-F16：信源库单一事实源 + 预警事件链（TC-M2-04）
  - `test_sourceLibrarySeedIdempotentAndOfflineSearchable()` (22) — 种子幂等入库、离线检索命中、信源链接/机构/年份准入
  - `test_noSourceNoReportedRangeRefusesGrading()` (47) — 无适用范围拒绝定级（不臆造阈值）
  - `test_alertEventsPersistAndHistoryQuery()` (61) — L3 事件落库 + 证据卡结构化 + 成员隔离
  - `test_threeConsecutiveExceedancesPersistChain()` (88) — 连续 3 次越限 → AlertRuleEngine L1 + 逐条留痕
  - `test_sameTimeDifferentMetricsDoNotShareEvidenceIdentity()` (105) — 同时刻不同指标证据 id 独立
  - `test_rawEvaluationDoesNotBecomeAQualifiedReminder()` (120) — 裸评估不成为合格提醒
  - `test_migrationV3BackfillsSourceThresholdColumns()` (131) — 迁移 v3 补齐阈值列（只应用 v3 步）

## Tests/VitaLiberTests/HealthBackupAcceptanceTests.swift
- `HealthBackupAcceptanceTests` (9) — SU-M1c-EXPORT / SU-M15-TREND / SU-M2-F16（FR13.5/FR7.9/FR16.2 备份往返）
  - `test_backupRoundTripsFullMetricsWithoutPortableHealthKitConnection()` (79) — 指标全列往返；授权/游标/样本索引不可携带；恢复不建立连接
  - `test_metricAdoptReplacesAllColumnsAndRemapsBothPatients()` (143) — adopt 全列替换 + 两成员 coexist 重映射
  - `test_metricCoexistRemapsPatientButKeepsHealthIdentityAndLocalRow()` (188) — coexist 保 sourceRef/excluded、原行不动
  - `test_legacyOptionalFieldsRestoreAndAdoptWithMappedSelfFallback()` (218) — 旧 JSON 缺可选字段恢复；INSERT/adopt 双路径
  - `test_missingCodeDictionaryRejectsRestoreAtomicallyInsteadOfDiscardingTheCode()` (277) — 缺码表引用 → 整库原子拒绝零残留
  - `test_alertHistoryRoundTripsButIsNotEligibleForNotificationRetry()` (330) — 预警历史往返、恢复态不复活提醒、旧证据键保留
  - `test_alertConflictsRequireResolutionAndKeepAdoptCoexistRemapSafely()` (377) — 预警冲突必须裁决；keep/adopt/coexist 组合态
- `makeStore()` (10) — Owner+家人两成员 + local_owner；`makeMetricStore()` (27) — 11 类指标样本 + 血压/血糖成员样本；`makeAlertStore()` (294) — 7 条预警事件（含 legacy evidence）

## Tests/VitaLiberTests/HealthImportAcceptanceTests.swift
- `HealthImportAcceptanceTests` (9) — SU-M2-F16：HealthImportStore 检查点/投影/分道/待办批的落库级验收
  - `test_connectionUsesOwnerAndKeepsItsTimeZone()` (22) — 连接绑定本人 + 时区不可被二次连接改写
  - `test_checkpointAndDeletionAreCommittedWithTheProjection()` (31) — 已知删除必须对账受影响窗；空快照不得推进游标
  - `test_emptyReadDoesNotDeleteKnownDataOrAdvanceCursor()` (61) — 空读可见性未知 → 不删数据不动游标
  - `test_revokingAppPermissionRejectsInFlightCommit()` (84) — 事务边界复核授权撤销
  - `test_missingAddedSampleSnapshotCannotAdvanceCheckpoint()` (100) — 缺新增样本快照不得确认游标
  - `test_emptySnapshotAfterTombstonePreservesUntombstonedSample()` (115) — 墓碑后空快照保留无删除证据的样本；重启续批完成
  - `test_reconnectAfterRestoreKeepsUnindexedRestoredReadings()` (159) — 恢复后重连：未索引 A 保留、B 按身份重放
  - `test_checkpointReplayDoesNotChangeExcludedRows()` (201) — 同身份重放不复活排除点
  - `test_snapshotForUnrequestedWindowIsRejected()` (238) — 批外窗口快照不是对账工作
  - `test_transactionFailureRollsBackSamplesAndCursor()` (259) — 触发器注入失败 → 四表全回滚、耐久页存活可重放
  - `test_staged501DeletionsDrainWithoutAdvancingCommittedAnchor()` (292) — 501 删除分页排空前不推进已提交游标
  - `test_crossWindowSeriesDeletionRetiresIndexAfterEveryWindow()` (341) — 跨窗序列删除：单窗/跨提交两路径均逐窗退役索引
  - `test_restoredAggregateIsPreservedWhileOtherProjectionsProgress()` (386) — 恢复的聚合行保留且不被 hk_projection_state 认领
  - `test_nonContributingSampleCannotClaimRestoredHeartOrSleepAggregate()` (424) — 无贡献样本不得认领恢复的心率/睡眠聚合
  - `test_additionMustBeVisibleInEveryCoveringWindow()` (456) — 新增必须在每个覆盖窗可见（先窗可见不验证后窗）
  - `test_invalidReferencesCannotBeStagedAndCorruptIndexIsNotInvented()` (473) — NaN/Inf/1e30 时间引用拒绝；坏索引 UUID 不臆造
  - `test_bindingDeletionCascadesMetadataButPreservesMetricFacts()` (504) — 删绑定级联元数据、保留医疗事实
  - `test_laterTombstoneReopensPreviouslyCompletedCoveringWindow()` (526) — 迟到墓碑重开已完成的覆盖窗
  - `test_legacyAggregateCannotBeAdoptedByTimestampAndSourceName()` (557) — 旧聚合不被时间戳+来源名认领
  - `test_visibleReferenceWithoutItsPriorRowDoesNotAuthorizeDeletion()` (585) — 无先行的可见引用不授权删除
  - `test_stalePendingRevisionCannotCommitOverAStagedSuccessor()` (610) — 陈旧待批 revision 不得覆盖新分页
  - `test_subsecondReplayUsesThePersistedEpochPrecision()` (627) — 亚秒重放按持久化 epoch 精度判定（不误判换样本身份）
  - `test_legacyPendingBatchWithoutLaneIsDiscardedInsteadOfWedgingTheType()` (654) — 旧 payload 缺 lane → 作废不卡死
  - `test_lanesKeepIndependentCursorsAndOnlyOneLaneMayBeInFlight()` (672) — recent/history 双道游标独立、单道在途
  - `test_bindingCarriesConnectedAtAndRoundTripsEqual()` (701) — binding 携 connected_at、重读相等
- `makeStore()` (10) — 夹具：Owner 绑定库（经 TestStoreFixtures.inMemoryWithOwner）；`checkpoint(_:binding:kind:previousAnchor:batch:snapshots:)` (15) — stage+commit 两步简写

## Tests/VitaLiberTests/HealthImportTestSupport.swift
- `extension HealthImportStore` (18) — history 道默认便捷（`anchor(binding:kind:)` 19 / `stage(binding:kind:previousAnchor:page:)` 23）：两份逐字重复的私有扩展收敛的单一出口
- `extension XCTestCase` (31) — `shanghaiCalendar` (32)：时区固定 Asia/Shanghai 的日历（Stock 三套件对账/物化/补录共用）

## Tests/VitaLiberTests/HealthKitReaderPredicateTests.swift
- `HealthKitReaderPredicateTests` (9) — SU-M2-F16：HealthKit 读取谓词边界（#if os(iOS) 编译守卫）
  - `test_stepStatisticsExcludeSamplesArrivingAfterIdentityEnumeration()` (10) — 步数统计谓词排除枚举后迟到的贡献样本
  - `test_changePredicatesPartitionSamplesOnEndDateAtCutoff()` (29) — recent/history 两道谓词以样本 end 在 cutoff 处互补，与 Domain matches 一致

## Tests/VitaLiberTests/HealthKitSyncServiceTests.swift
- `HealthKitSyncServiceTests` (10) — SU-M2-F16：HealthKitSyncService 飞行/分页/取消/预算/进度
  - `test_partialSnapshotFailureKeepsCheckpointAndReplaysAfterRestart()` (40) — 部分窗口失败：不推进游标、重启重放续批、双道请求序列正确
  - `test_historyPagesPublishCompleteWindowsBeforeTheFinalCheckpoint()` (75) — 历史分页在最终游标前发布完整窗
  - `test_fullAddedPageWithDeletionDoesNotGetStuckAtStaging()` (113) — 满页+删除不停留在暂存
  - `test_dashboardReportIsDurableAndBoundToTheConnection()` (122) — 仪表盘报告持久且随连接绑定；重连清报告
  - `test_windowBudgetKeepsCheckpointUntilRemainingWindowsResume()` (136) — 32 窗预算耗尽不推进游标、后续轮续完
  - `test_cancelledCallerCannotStartOrStageFlight()` (161) — 已取消调用者不得启动/暂存飞行
  - `test_unreadableWindowsDoNotStarveLaterReadableWindows()` (184) — 不可读旧窗不饿死可读新窗
  - `test_cancellingFlightOwnerPropagatesToItsQueries()` (204) — 取消飞行所有者传播到其查询任务
  - `test_cancellingAnotherCallerDoesNotCancelActiveOwner()` (222) — 合并调用者被取消不杀在飞所有者
  - `test_runThrowsDisabledNotMissingOwnerWhenToggleOff()` (248) — 开关关闭 = 独立失败态（不与缺本人混同）
  - `test_recentLaneIsProbedBeforeHistoryAndProgressIsReported()` (262) — recent 先探空页再 history；剩余窗/道报告；双道游标键隔离
  - `test_sparseWindowsFromSnapshotsAreReported()` (293) — 稀疏窗计数上送（事实非失败）
  - `test_syncReportDecodesLegacyJSONWithoutNewKeys()` (308) — 旧 report_json 无新键可解码（Optional 字段）
- `makeStore()` (11) — 夹具：Owner 绑定库；`service(_:imports:provider:)` (18) — HealthKitSyncService 装配；`discreteFixture(days:)` (24) — N 天样本/窗口对
- `HealthSyncTestGate` (325) — 续延门（wait/open）；`HealthSyncFixtureProvider` (342) — 分道分页 fixture 提供者（请求记录/失败注入/oversized 校验）

## Tests/VitaLiberTests/HealthPresentationTests.swift
- `HealthPresentationTests` (8) — SU-M2-F16 / SU-M15-L10N：健康指标展示本地化三语一致性
  - `test_sixHealthTypesAndEverySleepStageHaveVisibleMetricNames()` (9) — 六类 + 睡眠六阶段的 metric.name.* 三语非空、互异、L10n 出口同源
  - `test_aggregationLabelsDistinguishSamplesAveragesTotalsAndDurations()` (44) — 聚合标签四值三语互异
  - `test_unknownMetricsUseALocalizedFallbackInsteadOfStorageKeys()` (65) — 未知指标走本地化兜底、不裸显存储键
  - `test_deviceEvidenceKeepsItsOriginAndLocalizesMetricNames()` (78) — 证据卡保留来源并本地化指标名
  - `test_healthFormatsInterpolateArgumentsWithoutTruncatingCounts()` (96) — 大计数（42 亿级）不截断、占位符全部消费
  - `test_healthKeysAndPrintfContractsMatchAllThreeLanguages()` (125) — 三语键集一致 + printf 契约逐键匹配
- `forEachLanguage(_:)` (173) — 三语循环（切换 L10n + 恢复原语言/原存储）

## Tests/VitaLiberTests/HomeDoseDispositionTests.swift
- `HomeDoseDispositionTests` (10) — SU-M1c-REGRESSION（TC-M1c-09 / BR-004）：时段级动作逐剂落 dose_log
  - `test_timeSlotSkipWritesSkippedPerDoseAndReturnsCount()` (33) — 时段跳过逐剂写 skipped 并返回条数、pending 归零
  - `test_timeSlotSnoozeSchedulesThenRecordsSnoozed()` (44) — 时段稍后：先调度后记 snoozed
  - `test_emptyDoseSetReturnsZero()` (53) — 空剂量集返回 0
- `makeStore()` (11) — 夹具：药品库 + ReminderStore 装配（经 TestStoreFixtures.inMemoryWithMedication）；`pendingDoses(_:_:_:_:)` (21) — 今日 +5 分钟固定时刻未决剂量（临近日界跳过）

## Tests/VitaLiberTests/HomeProfileProgressTests.swift
- `HomeProfileProgressTests` (10) — SU-M1c-REGRESSION（TC-M1c-08 / FR2.1b / FR17.11 / BR-001）：档案进度 8 项与访谈完成元数据
  - `test_unloadedProfileDoesNotInventZeroOfEightProgress()` (34) — 未加载档案不得臆造 0/8
  - `test_whitespaceFieldsDoNotCountAsCompletedInformation()` (40) — 空白字段不计完成
  - `test_legacyUnscopedInterviewFlagsDoNotCompleteOtherMembers()` (50) — 旧无成员身份的访谈旗标不得完成任何成员
  - `test_memberSwitchInvalidatesObservedProgressWithoutReloadingMembers()` (65) — 切成员发布新进度（Perception 追踪）
  - `test_savedInterviewProgressIsMemberScopedAndSurvivesRestart()` (80) — 访谈进度按成员分域、重启保持、重复确认不重复计数
  - `test_failedSaveDoesNotCompleteInterviewAndRetryCanCompleteIt()` (104) — 保存失败不提前计入；重试可完成
  - `test_saveCreditsUpdatedProfileInsteadOfNewlySelectedMember()` (120) — 保存计入被更新档案而非当前选中成员
  - `test_allSavedFieldsCompleteTheProfileWithoutOvercounting()` (134) — 4 字段 + 4 访谈步 = 8/8 不超计
  - `test_clearingDataAlsoClearsInterviewCompletionMetadata()` (149) — 清数据连带清访谈完成元数据，恢复档案不继承
  - `test_interviewAnswerAndProgressStayWithCapturedMember()` (171) — 迟到回调答案归属访谈建立时的成员
  - `test_missingInterviewMemberIsNotReplacedByCurrentMember()` (189) — 访谈成员已删 → 拒绝，不以当前成员顶替
- `makeApp(profiles:defaults:)` (11) / `makeApp(persistor:defaults:)` (16) — AppState 装配（桩识别/合成语音）；`freshDefaults()` (27) — 独立 UserDefaults suite + teardown 清理
- `HomeProfilePersistor` (201) — PatientPersisting 端口替身（计数与观察走生产 AppState，可注入拒绝更新）

## Tests/VitaLiberTests/ImmunizationAcceptanceTests.swift
- `ImmunizationAcceptanceTests` (12) — SU-M2-CARE（FR4.5/FR4.6 疫苗记录落库）
  - `test_provenanceAndConfirmationStatus()` (21) — 手动 = C 级已确认；OCR 派生 = D 级待确认（BR-003）
  - `test_nextDoseSequenceNumberOnlyFactualHint()` (40) — 下一剂次序号只作如实提示，不内置「该打什么」
  - `test_memberIsolation()` (54) — BR-001 跨成员隔离

## Tests/VitaLiberTests/MatchedCardTestSupport.swift
- `extension MatchedCard` (5) — `fullyConfirmed()` (18)：两步确认编排（批量可选字段 + 逐项必填字段），与 UI 确认流程同构；与 CoreKitTests 同名扩展刻意重复（两个 test target 无法共享）

## Tests/VitaLiberTests/MemberAcceptanceTests.swift
- `MemberAcceptanceTests` (11) — SU-M1a-GOLDEN（FR3.7 添加家人落库）
  - `test_memberPersistAndRoundTrip()` (15) — saveOwner + saveMember 两张档案并存、字段往返
  - `test_quotaBoundaryMatchesPersistedState()` (38) — 配额边界与落库计数一致（3 人加 1 不弹、4 人加 1 弹）

## Tests/VitaLiberTests/NotificationCenterStateTests.swift
- `NotificationCenterStateTests` (9) — SU-M1c-REGRESSION（TC-M1c-09 / FR14.8 归档状态合并）
  - `test_loadMergesOnlyRequestedKeys_emptyKeySetDoesNotClear()` (16) — load 只合并请求键；空键集不清空
  - `test_staleLoadDoesNotOverwriteNewerLocalWrites()` (27) — 快照之后的本地写赢过陈旧读
  - `test_archivePersistenceFailureKeepsObservableState()` (37) — 落库失败不得假归档（关库注入 SQLITE_MISUSE）
  - `test_undoMarksReadAndClearsArchivedAt()` (45) — 撤销后为已读且持久层 archived_at 为空

## Tests/VitaLiberTests/OcrCardQueueAcceptanceTests.swift
- `OcrCardQueueAcceptanceTests` (12) — SU-M2-PENDINGCARD / SU-M1c-EXPORT（FR6.1/FR6.9/BR-001/BR-003）：DocumentsState 队列活管线（PDF/图像草稿→提交→待办→恢复）
  - `test_documentPagesArePersistedWithFailedPlaceholder()` (121) — 页持久化含 failed 占位；OCR 结果页索引正确
  - `test_pendingCardCarriesPageAndRows()` (139) — 待办卡按（sourcePage）幂等 upsert、携行与共享字段
  - `test_hospitalSamplesAreWrittenWithPageReference()` (160) — 检验样本带页引用写库；数值/定性分流；参考范围随行
  - `test_backupRoundTripsDocumentPages()` (189) — 文档页往返；旧包无 pages 照常恢复
  - `test_pdfReturnsDraftWithoutSavingAndPreservesFailedAndEmptyIndexes()` (211) — PDF 只出草稿不落库；failed/空页索引保留
  - `test_pdfNeverBorrowsRequiredFieldsFromAnotherPage()` (231) — PDF 不得跨页借必填字段
  - `test_sourceRendererOpensRequestedPDFPageAndRejectsMissingPage()` (240) — 来源渲染器开指定页、拒绝缺页、来源引用解析
  - `test_notificationFailureKeepsSavedPendingCardAndDoesNotReportDeferralSuccess()` (256) — 调度失败：待办卡保留、不得报推迟成功
  - `test_reenteringPendingCardUsesUnwrittenCurrentQueueEdits()` (271) — 重进待办卡用未写盘的当前编辑
  - `test_discardedRowWithoutFactsDoesNotLockSharedCorrections()` (287) — 无事实的行弃置不锁共享修正
  - `test_pdfDuplicateReplacementReturnsReviewedDraftAndDoesNotArchiveEarly()` (307) — PDF 重复替换出已复核草稿、不提前归档
  - `test_documentCorrectionsAndRejectionsFeedMatchingWithoutPromotingFields()` (328) — 文档修正/拒绝喂匹配而不提升字段级确认（BR-003）
  - `test_manualTypeDoesNotExcludeOtherQualifyingCardsOrAutoCreatePrescription()` (348) — 手选类型不排除其它合格卡、不自动建处方
  - `test_lowRecognitionConfidenceSurvivesDeferralAndResume()` (363) — 低置信度经推迟/恢复往返保持
  - `test_allLaterAndResumedLaterPreserveCurrentEditsAndStableRowIdentity()` (379) — 推迟/恢复保留当前编辑与稳定行身份
  - `test_partialSaveKeepsResidualAndRetryDoesNotDuplicateFacts()` (408) — 部分保存留残行、重试不重复事实、会话占用到 onDismiss
  - `test_queueCannotBeReplacedAndResumeCannotChangeItsOwner()` (441) — 队列不可被替换、恢复不得换主人
  - `test_failedOriginalWriteKeepsDraftAndCreatesNoDocument()` (472) — 原件写失败保留草稿、零文档
  - `test_documentLaterRetainsOriginalAndEditedSourceBackedCard()` (484) — 稍后处理保留原件路径与编辑卡
- `Fixture` (23) — 夹具聚合（库/待办/调度/状态/目录）；`fixture(pages:confidence:scheduler:)` (71) — 完整活管线装配；`PageRecognizer` (33) — 按页脚本识别桩（PDF 字节拒绝）；`FailingScheduler` (54) — 恒失败调度桩；`imageDraft` (89) / `pdfURL` (97) / `reviewed` (110) — 草稿/PDF/确认卡便捷

## Tests/VitaLiberTests/OcrCardStoreTests.swift
- `OcrCardStoreTests` (10) — SU-M2-PENDINGCARD / SU-M1c-EXPORT（FR6.1/FR6.9/BR-001/BR-003）：OCRCardStore 落库 + 备份恢复大网（v25 行实体 / v26 临床集 / v27 卡层级）
  - `test_receiptAssociationSurvivesBackupAndAdoptRestoresChangedRelation()` (29) / `test_otherMembersEncounterCannotBeAttached()` (52) / `test_explicitUnlinkedReceiptStaysUnlinkedWhenAnEncounterExists()` (67) — 回执就诊关联：备份 adopt 恢复、跨成员拒绝、显式不挂保持
  - `test_partialSaveRetainsSnapshotAndReplayDoesNotDuplicate()` (91) / `test_unreviewedCardOnlyCreatesDraft()` (116) — 部分保存留快照、重放不重复；未复核卡只建草稿
  - `test_recoveryMetadataCannotBecomeSearchOrAIExcerpt()` (125) — 恢复元数据不进搜索/AI 摘录
  - `test_coexistRemapsPendingOnlySnapshotCardIdentity()` (144) — coexist 只重映射快照卡身份
  - `test_reviewedButUncommittedResidualSurvivesLaterAndResume()` (168) — 已复核未提交残行经恢复续写
  - `test_documentAndInitialPendingCardsStageAtomically()` (192) — 文档 + 首卡原子暂存（触发器回滚）
  - `test_deferringEditedResidualPreservesCommittedRowsWithoutNewFacts()` (208) — 推迟已编辑残行保提交行零新事实
  - `test_restoredReceiptRejectsRematchedCardAndChangedReplay()` (224) — 恢复回执拒绝换身份卡与篡改重放
  - `test_resolutionFailureRollsBackFactsReceiptsAndAudit()` (248) — 解决失败回滚事实/回执/审计
  - `test_wrongOwnerAndMissingPageAreRejected()` (261) / `test_standaloneAuditRejectsWrongOwnerAndUnreviewedField()` (315) — 错主人/缺页/未复核字段拒绝
  - `test_approvedCodeMustMatchStoredConceptIdentity()` (278) — 已批准编码必须匹配存储概念身份（canonical/codingSystem）
  - `test_auditContainsOriginalReviewedValueAndEntityIdentity()` (302) — 审计含原始复核值与实体身份
  - `test_coexistRestoresReceiptAndMetricToNewOwnedPage()` (333) / `test_reattributionWithRetainedOCRFactsIsRefused()` (351) — coexist 恢复回执与指标到新页；保留 OCR 事实时拒绝改属
  - `test_adoptReplacesUnreferencedPagesAndRejectsMalformedPages()` (364) — adopt 替换未引用页、拒绝畸形页索引
  - `test_prescriptionRowsShareEntityAndRoundTripReviewedDateAdvice()` (383) / `test_partialPrescriptionCompletionPreservesOriginalRowOrder()` (418) — 处方行共享表头、复核日期/医嘱往返；部分完成保行序
  - `test_memberDeletionArchivesAndCancelsPendingOCR()` (442) — 删成员归档并取消待办 OCR 调度
  - `test_encountersKeepSeparatePageReceiptsWithoutOverwritingGrouping()` (455) — 就诊分页回执互不覆盖分组
  - `test_legacyOCRPrescriptionDoesNotInventDateOrPagesOnRestore()` (482) — 旧 OCR 处方恢复不臆造日期/页
  - v25 行实体段（MARK 508）：`test_prescriptionCardWritesHeaderAndLinesWithLineReceipts()` (507) / `test_prescriptionReconfirmSamePageIsIdempotent()` (549) / `test_prescriptionCompletionRefusesTamperedCommittedLine()` (563) / `test_legacyFoldedPrescriptionCompletesWithoutRewritingAdvice()` (586) / `test_lineDetailReturnsLineHeaderAndProvenance()` (627) / `test_lineDetailRejectsOtherMember()` (647) / `test_associateZeroRowUpdateThrowsInvalidAssociation()` (668) — 处方行/回执/行详情/零行关联拒绝
  - `test_claimCardWithFeeLinesWritesClaimLinesAndLineReceipts()` (690) / `test_claimCardWithoutFeeLinesKeepsHeaderReceipt()` (725) — 报销卡明细行/表头回执
  - `test_encounterCardPersistsNarrativeColumnsAndOnlyFillsEmptyOnes()` (735) / `test_encounterStoreUpsertPersistsNarrativeFields()` (763) — 就诊叙事列只补空；手工 upsert 全量覆盖
  - `test_medicationPlanFromPrescriptionLineLinksStockLot()` (778) — 处方行建计划挂批次；未知行拒绝
  - v25 备份段（MARK 818）：`test_manualEncounterRoundTripsAllColumns()` (806) / `test_documentTypeKeyAndTitleSourceRoundTrip()` (831) / `test_restoredPrescriptionReconfirmIsIdempotentAndReimportKeepsLineCount()` (847) / `test_coexistRemapsPrescriptionLinesWithTheirHeader()` (875) / `test_claimLinesRoundTripWithLineReceipts()` (902) / `test_backupRejectsCrossMemberOrDanglingPrescriptionLines()` (931) / `test_legacyEnvelopeWithoutV25KeysStillRestores()` (957) — 全列往返、行随表头裁决、跨成员/悬空拒收、旧包兼容
  - v26 临床集段（MARK 1031）：`test_hospitalizationCardCreatesInpatientEncounterAndRowInOneTransaction()` (1045) / `test_hospitalizationSecondOriginalOnlyFillsEmptyColumnsOfTheSameStay()` (1090) / `test_daySurgeryCardDerivesDaySurgeryEncounterKindAndRejectsOtherMembersEncounter()` (1119) — 住院卡同事务建就诊；第二份原件只补空；日间手术类型派生
  - `test_diagnosisCardWritesRowsLinkedToExplicitEncounterAndInheritsItsDate()` (1138) / `test_diagnosisCompletionRefusesTamperedCommittedRow()` (1178) — 诊断行挂就诊并继承日期；篡改行拒绝续写
  - `test_examReportCardWritesReportWithVerbatimFindingsAndImpression()` (1201) — 检查报告原文落库（findings/impression 逐字）
  - `test_labCardSplitsNumericAndQualitativeRowsUnderOneReport()` (1239) / `test_labCardPartialCompletionReusesHeaderAndRefusesTamperedRows()` (1305) — 检验卡数值/定性分流同一表头；部分完成复用表头
  - `test_clinicalEpisodesRoundTripThroughBackupAndReimportIsIdempotent()` (1347) / `test_backupRejectsCrossMemberOrDanglingClinicalRows()` (1417) / `test_legacyEnvelopeWithoutV26KeysStillRestores()` (1450) — 临床集五表备份往返/拒收/旧包
  - v27 卡层级段（MARK 1490）：`test_prescriptionWithNewHubDraftCreatesEncounterInSameTransaction()` (1502) / `test_newHubDraftRefusedWhenFieldsUnconfirmedOrEvidenceStale()` (1549) — 主卡草稿同事务；未确认/证据过期拒绝
  - `test_healthExamCardProjectsOnlyKeyedStrictNumbers()` (1575) — 体检卡只投影有键严格数值（身高/视力原文保留）
  - `test_clinicalConclusionCardUsesHealthExamDraftAsExactlyOneParent()` (1631) — 结论卡恰一父 = 体检；同文档首页卡会合
  - `test_surgeryAndTreatmentCardsLinkToEncounterAndAppearInLinkedCards()` (1705) — 手术/治疗卡挂就诊、原文列、无双计
  - `test_followUpAppointmentAndReminderAppearUnderEncounter()` (1761) — 复诊预约/随访提醒挂就诊；candidates/link 零行拒绝
  - `test_cardHierarchyRoundTripsThroughBackupAndLegacyEnvelopeStillRestores()` (1818) — v27 五数组备份往返、adopt/coexist 不翻倍、FK 完整、旧包恢复
- 卡建造器：`receiptCard(encounter:)` (24) / `card(partial:reviewed:)` (79) / `prescriptionCard(pageIndex:shared:rows:)` (510) / `singleRowCard(kind:pageIndex:shared:encounter:)` (1033) / `hospitalizationCard(pageIndex:kind:encounter:extra:)` (1039) / `labCard(pageIndex:encounter:)` (1046) / `confirmedDraft(_:)` (1492) / `healthExamCard(pageIndex:)` (1498) / `conclusionCard(pageIndex:association:)` (1507)
- `fixture()` (11) — 成员 + 双页文档夹具（经 TestStoreFixtures.inMemoryWithPatient）；`fixtureDocument(_:patient:)` (1711) — 第二份体检文档

## Tests/VitaLiberTests/ProfileSuggestionStoreTests.swift
- `ProfileSuggestionStoreTests` (13) — SU-M2-PENDINGCARD（FR3/FR11.4/FR23/BR-001/BR-003 · 子项目 D D4-2）：资料建议接受流
  - `test_collectReadsConfirmedReceiptsAndWritesNothing()` (54) — collect 只读已确认回执、零写入、来源元数据齐全；他人卡零建议
  - `test_collectNeverSurfacesUnconfirmedRows()` (92) — 未确认卡无回执 → 零建议（BR-003）
  - `test_acceptBloodTypeWritesProfileAndAuditsProvenance()` (105) — 接受血型写档案 + 审计只记留痕不记内容；不复发
  - `test_acceptBloodTypeNeverOverwritesExistingValue()` (131) — 已有值不覆盖（skippedExisting）、无写入无审计
  - `test_acceptChronicConditionCreatesHealthProblemAndBackfillsDiagnosis()` (154) — 慢性病建 health_problem + 回填 diagnosis.health_problem_id；同名不再建议
  - `test_acceptPastHistoryWritesWholePassageAsHealthProblem()` (186) — 既往史整段原文不切分
  - `test_acceptAllergyRequiresUserSeverityAndWritesEvent()` (201) — 过敏严重度只能用户给出；非法枚举拒绝；展示词（中）同口径
  - `test_acceptRejectsCrossMemberProvenance()` (238) — 跨成员/伪造来源表名 → invalidCard 零写入（SQL 注入面）
  - `test_dismissPersistsAndSuppressesResuggestion()` (265) — 忽略持久化、只登记键不写事实不审计、按成员分域
- `fixture()` (14) — 成员 + 文档 + 双页夹具；`encounterCard(past:allergy:page:)` (23) / `labCard(_:page:)` (31) / `diagnosisCard(_:page:)` (38) — 卡建造器（经 fullyConfirmed）；`count(_:_:_:)` (48) — 单表行数

## Tests/VitaLiberTests/ReminderStoreTests.swift
- `ReminderStoreTests` (13) — SU-M1b-REMINDER（App 层 ReminderStore 补覆盖）
  - `test_dueReminderDeliveredNotRescheduled()` (20) — 到期提醒已送达不再重排（delivered 守卫）
  - `test_followUpReminderCarriesObservationDetailDeepLink()` (60) — 随访提醒携带观察详情深链（缺路由降级不 crash）
  - `test_SOS_longPressContract_regularMode06Seconds()` (74) — BR-012 SOS 长按契约 ≥0.6s（常规/关怀模式）
- `makeStore()` (87) — 夹具：成员 + 完整 ReminderStore 装配（经 TestStoreFixtures.inMemoryWithPatient）

## Tests/VitaLiberTests/SchemaRuntimeTests.swift
- `SchemaRuntimeTests` (14) — SU-M0-GOLDEN（TC-M0-06 运行时半场）：§4.3 建库可执行 + 外键运行时执法（GRDB 只在 iOS/macOS 链接，故放此目标）
  - `test_foreignKeysEnabledAtRuntime()` (18) — PRAGMA foreign_keys 运行时真开
  - `test_danglingForeignKeyRejected()` (25) — 悬空外键被拒
  - `test_validForeignKeyWritable()` (42) — 合法外键可写（防「什么都写不进」假象）
  - `test_auditTablesAndIndexesBuildable()` (63) — 审计表与 idx_audit_time 索引可建
  - `test_M0_fullSchemaIncludesFiveDualTrackStockTables()` (85) — §4.3 全量表清单逐一断言（防部分清单假绿）+ 双轨索引

## Tests/VitaLiberTests/SecurityGateAcceptanceTests.swift
- `SecurityGateAcceptanceTests` (19) — SU-M1a-SEC / SU-M1a-BIO / SU-M1a-GOLDEN（TC-M1a-03/04/05 / BR-003 一票否决）：生物识别门禁 + 三卡 ConsentRecord + BR-003 活管线
  - `test_typeFreeCaptureLeavesDocTypeUnresolvedWhenNothingIsJudged()` (72) / `test_judgedTypeResolvesWithoutEntryHint()` (87) — 零命中类型未决引导选择；判定预选不覆盖用户入口类型（<0.75）
  - `test_SU_M1a_BIO_coldStartLockedUntilAuth_authUnlocks()` (133) / `test_SU_M1a_BIO_authFailureDoesNotUnlock()` (156) — FR1.1 冷启动锁、认证成功放行；失败停留锁屏
  - `test_SU_M1a_BIO_firstLaunchThreeCardsThenProfileNoPINStep()` (171) — 三卡后直达建档；旧 PIN 键清除
  - `test_threeCardsConfirmationWritesConsentRecordAndPersists()` (189) — 三卡逐卡确认落 consent_record、重启不重复
  - `test_profileCreationLinksLocalOwner()` (222) — 建档先落库再推进；patient_profile/local_owner 各一行
  - `test_BR003_livePipeline_unconfirmedFieldsExcludedOfficialZone_trailOnlyConfirmed()` (248) — BR-003 活管线：commitDraft 正式区/ocrText/留痕仅含已确认字段
  - `test_legacyReviewWithoutOriginalLeavesDocumentUnconfirmed()` (288) — 无保留原件的旧文档不得盲升
- `makeApp(defaults:gateResult:)` (42) / `makeDocs(container:lines:)` (50) / `ensureOwner(app:container:)` (116) — App 装配、活管线状态仓（每用例独立原件目录 + tearDown 清理）、建档等待；`freshDefaults()` (35) / `tinyPNG` (63, lazy) — 独立 defaults / 32×32 白图

## Tests/VitaLiberTests/SentStatusAcceptanceTests.swift
- `SentStatusAcceptanceTests` (11) — SU-M2-CARE（FR24.2 发送状态落库只记状态不存原文）
  - `test_recordsAndList()` (20) — 记录发送 + 列表可查；表结构无原文列
  - `test_statusTransitionWhitelist()` (35) — 状态迁移白名单：回退被拒
  - `test_memberIsolation()` (56) — BR-001 跨成员隔离
- `makeStore()` (13) — 夹具（经 TestStoreFixtures.inMemoryWithPatient）；`messagesCols()` (63) — sent_message 列名清单

## Tests/VitaLiberTests/SmokeTests.swift
- `SmokeTests` (7) — SU-M0-SMOKE（TC-M0-09 启动冒烟）
  - `test_SU_M0_SMOKE_MainModuleFiveCasesComplete()` (9) — MainModule 五枚举完整
  - `test_MainModule_keysMatchSpec()` (17) — 模块键与 ui-ux §9 一致；SF Symbol 名运行时可解析（拦空 Tab 图标）
  - `test_ObservationKind_eightKindsCompleteWithNonEmptyNames()` (29) — F8 八类观察类型齐全且名称非空

## Tests/VitaLiberTests/StockAcceptanceTests.swift
- `StockAcceptanceTests` (16) — SU-M2-STOCK（TC-M2-01 零确认存活 / FR9.8.5 月报 / 盘点归真）：双轨库存 GRDB 落库半场
  - `test_dailyEquivalentEstimateIncludesSingleDose()` (26) — ADR-009 日当量含单剂剂量（误差偏晚红线）；越界钳制
  - `test_zeroConfirmationSurvives_makeupAdvancesPlanTrackOnly()` (40) — 零确认存活：补账只推安全线、确认线分毫不动、续药档照常触达、幂等
  - `test_makeupIdempotentNoDoubleDeduction()` (99) — 补账幂等不重复扣（user_action IS NULL 守卫）
  - `test_differenceMonthlyReportPureFactsPassesNegativeList()` (137) — 差异月报纯事实（planned 4/confirmed 1/missed 3）过负清单
  - `test_stocktakeRoundTripResetsBothTracks()` (191) — 盘点归真两线重置；差异需确认
  - `test_honestyDaysEstimate()` (213) — 「约剩 N 天」诚实性（daily=1 时 N=剩余安全线）
- `makeStore()` (18) — 夹具（经 TestStoreFixtures.inMemoryWithMedication）

## Tests/VitaLiberTests/StockAppointmentAcceptanceTests.swift
- `StockAppointmentAcceptanceTests` (12) — SU-M1b-STOCK / SU-M1b-APPT（TC-M1b-06/07）：双轨扣减矩阵 + 预约闭环
  - `test_dualTrackDeductionMatrixPersists()` (43) — taken → 两线各扣 + FEFO 分配行；重复确认拒绝；deliveryFacts 可见已服
  - `test_skipExemptsBothTracks()` (98) — 跳过两线均免扣（修正矩阵 (0,0)，BR-004）
  - `test_legacyPlanWindowAnchorsToToday()` (115) — 老计划窗口锚定今天（fromDay 不固定 1）
  - `test_SU_M1b_APPT_appointmentCreationTieredRemindersAndReschedule()` (137) — 预约创建四级提醒、改期重排、未开始不可完成、完成补录就诊、取消清 pending
  - `test_markMissedCancelsTieredRemindersKeepsFollowUp()` (195) — 标记错过取消分级提醒只留跟进（幽灵提醒回归）
  - `test_futureAppointmentMarkMissedRejected()` (213) — 未来预约标错过被商店层拒绝
- `makeStore()` (17) — 夹具（经 TestStoreFixtures.inMemoryWithMedication）+ 调度/预约；`materializedDose(store:meds:patient:med:times:)` (39) — 建计划 + 物化今日窗口取首个剂量 id

## Tests/VitaLiberTests/StockRegressionTests.swift
- `StockRegressionTests` (13) — SU-M2-STOCK（评审修正第二轮回归网）：D3 补录 PK 冲突、D5 物化幂等、FR5.8 归档收藏、定价锚点、v27 稳定键仓契约
  - `test_D5_normalConfirmMissedToTaken_planTrackNotDoubleDeducted()` (40) — 普通确认 missed→taken：计划轨不双扣、确认轨补扣
  - `test_makeupMissedToTaken_noPKConflictNoDoubleDeductionOnPlanTrack()` (79) — 补录转场无 PK 冲突不双扣（±30min 命中既有行）
  - `test_twoHourLateMakeup_wideLinkTransitionNoDuplicateRowsNoDoubleDeduction()` (117) — 晚 2.5h 补录宽关联转场不建新行
  - `test_materializedWindowIdempotent_timezoneReanchorNoDuplicateRows()` (146) — 同窗物化幂等；换时区重锚不重复建行（固定锚点时钟）
  - `test_archiveFavoriteComboStateReversible()` (176) — FR5.8 归档/收藏正交组合态可逆
  - `test_pricingAnchorMatchesSpec()` (216) — Pro 年价 ¥68/月价 ¥12 锚点（comercial §4.3）
  - v27 稳定键段（MARK 240）：`test_ingestWritesStableKey_missingKeyRowsEnterBackfillList()` (246) / `test_setDocTypeKey_memberIsolation_unknownKeyRejected_successLeavesList()` (284) / `test_confirmTypeChangeSyncsStableKey_absentKeyKeepsOriginal()` (316) — 入库写键/缺键进清单/隔离/未知键拒绝/复核改类型同步
  - `test_wrongMemberMakeupRejectedAndStockUntouched()` (343) — 错传成员补录被拒且两线分毫不动
- `makeStore()` (15) — 夹具（经 TestStoreFixtures.inMemoryWithMedication）；`seedMissedDose(store:meds:planId:patient:med:lot:)` (34) — 昨日未决议行 + 补账为 missed；`documentFixture()` (243) — 两成员文档仓

## Tests/VitaLiberTests/TestStoreFixtures.swift
- `extension GRDBStore` (12) — 测试仓夹具单一出口（2026-09-18 收敛十余份逐字重复的 makeStore 种子）
  - `inMemoryWithPatient(_:relation:bloodType:)` (14) — 单成员库（外键目标 ERR#35 前置）
  - `inMemoryWithOwner(_:relation:)` (23) — 本人绑定库（selfProfile JOIN 前提）
  - `inMemoryWithMedication(patientName:relation:medName:spec:unitKind:)` (31) — 药品库（stock_lot 外键目标）
  - `insertPatient(_:relation:bloodType:)` (39) / `insertLocalOwner(_:selfPatient:)` (56) / `insertMedication(patient:name:spec:unitKind:)` (65) — 单行种子
- `tableCounts(_:_:)` (78) — 表行数向量（事务回滚/幂等断言共用）

## Tests/VitaLiberTests/TimelineExpansionStoreTests.swift
- `TimelineExpansionStoreTests` (12) — SU-M1c-REGRESSION（FR11.1/FR11.2/BR-001 · 子项目 J4）：展开记忆 + 主卡投影
  - `test_memory_defaultNil_writableThenReadable_forgetResets()` (21) — 记忆默认 nil、写后可读、forget 回默认
  - `test_LRU_capacity_evictsLeastRecentlyTouchedKey()` (35) — LRU 容量淘汰最久未触碰键
  - `test_viewModel_defaultAllCollapsed_memoryFirst_filterTransientNotMemorized()` (70) — 主卡默认全折叠、记忆优先、筛选态收起只落瞬态
  - `test_viewModel_cursorPagingAppendsDedupes_crossMemberEmpty()` (111) — 游标翻页追加去重；BR-001 他人为空
- `defaults()` (13) — 独立 UserDefaults；`makeStore()` (49) / `seedEncounter(_:patient:at:withPrescription:)` (53) / `makeState(_:defaults:)` (64) — 库/就诊/视图模型装配

## Tests/VitaLiberTests/TimelineHubQueryTests.swift
- `TimelineHubQueryTests` (13) — SU-M1c-REGRESSION（FR11.1/FR11.2/BR-001/BR-003 · 子项目 J round1 V4/V5）：主卡分页 + 子卡批取（hubPage）
  - `test_hubPage_groupsChildrenUnderEncounterAndKeepsLeaves()` (23) — 子卡归组主卡、观察叶子独立、D 级不入子卡、旧平铺查询不变
  - `test_hubPage_labReportUnderBothEncounterAndHealthExam()` (60) — 检验多重归属两处都列；结论聚合一条子卡
  - `test_hubPage_hospitalizationHubAndOrphanChildAsOwnLeaf()` (87) — 住院枢纽；无父历史处方自成叶子
  - `test_hubPage_cursorPagingIsStableAcrossHubsAndLeaves()` (109) — 游标翻页不重不漏、子卡按页主卡批取
- `makeStore()` (15) — 成员库（经 TestStoreFixtures.inMemoryWithPatient）；`encounter(_:patient:at:kind:hospital:)` (19) — 就诊种子

## Tests/VitaLiberTests/TimelineSearchAcceptanceTests.swift
- `TimelineSearchAcceptanceTests` (12) — SU-M1c-REGRESSION / SU-M1c-EXPORT / SU-M1c-SEC（TC-M1c-01/04）：时间轴投影 + 往返 + 搜索双路由
  - `test_SU_M1c_REGRESSION_timelineUnionProjectionAndIsolation()` (37) — F11 联合投影同轴时间倒序、成员隔离
  - `test_SU_M1c_EXPORT_exportImportRoundTripConsistency()` (55) — F13 往返一致性：导出→导入→再导出逐字段相等（含血型/证件/软删成员回归锚点）
  - `test_searchDualRouteHits()` (138) — F12 搜索：trigram/2-gram/1 字 LIKE 三路由命中（FTS 触发器同步）
- `makeStore()` (14) — 成员 + 就诊 + 观察种子（经 insertPatient）
- `AppearanceThemeTests` (172) — SU-M1c-FR14：AppTheme 三态映射 + FR18.16 高对比叠加/关怀回落（与时间轴搜索同文件，两套件共文件）

## Tests/VitaLiberTests/TrendAcceptanceTests.swift
- `TrendAcceptanceTests` (17) — SU-M15-TREND（F7 落库半场）/ SU-M15-VOICE（备份校验）：GRDB 只在 iOS/macOS 链接（ERR#8）
  - `test_manualMetricAddSampleRoundTrip()` (57) / `test_deviceIngestKeyNormalizationAndReplayIdempotent()` (72) — 手输指标落库往返；设备键归一化 + 同窗重放幂等
  - `test_diastolicSeriesProjectedFromSystolicRows()` (99) — FR7.11 舒张压从收缩压行 secondary_value 投影
  - `test_deviceReplayReportsUpdatesAndDoesNotOverwriteManualRows()` (120) — 设备重放报更新、不覆盖手输行
  - `test_threeHospitalGlucoseSameChartReferenceBandsPerSource()` (141) — FR7.2 一票否决：三医院同图三条独立参考带、空心/实心、sourceRef
  - `test_excludedPointSoftDeleteAndRestoreRoundTrip()` (173) — FR7.4 排除点软删对照集可见、恢复往返
  - `test_exclusionOperationMemberIsolation()` (196) — BR-001 排除操作跨成员无效
  - 迁移段（MARK 218）：`test_freshDatabaseLatestVersionWithReferenceRangeColumn()` (210) / `test_oldVersionDatabaseUpgradeBackfillsNewColumns()` (227) / `test_secondAssemblyIdempotent()` (277) / `test_v13_doseLog_rebuildBackfillsFK()` (286) / `test_v15_doseIDBackfillReferenceRowsFollow()` (434) — 最新版本/缺列补齐/二次装配幂等/v13 重建补 FK/v15 剂量 id 引用行跟随
  - `test_backupRoundTripConsistent()` (628) / `test_corruptBackupRejectedWithZeroPartialImport()` (644) — FR13.11 备份往返 + 篡改校验拒绝零部分导入
- `makeStore()` (19) — Owner 绑定库（经 TestStoreFixtures.inMemoryWithOwner）；`insertMetric(_:member:value:origin:dayOffset:...)` (37) — 血糖样本直插；`wholeRange` (58) — 全量时间窗
- `M15LocalizationTests` (680) — SU-M15-L10N：三文件本地化纪律（与趋势同文件）
  - `test_SU_M15_L10N_threeFilesKeySetsMatchNoMissingTranslations()` (684) — 三语键集一致无缺译
  - `test_keyRegistryNotEmpty()` (704) — 登记表非空无重复（ERR#27 原始形态）
  - `test_simplifiedTraditionalTranslationsNotWholeCopies()` (713) — 简繁并非整体复制
  - `test_emergencyNumbersByLanguageRegion()` (734) — BR-012 急救号码按语言（120/119/911）+ 语音指令命中
  - `test_templateSentencesPassBR006WordingNegativeList()` (754) — BR-006：AI 七段句/语音提示/证据卡模板全过措辞负清单

## Tests/VitaLiberTests/TrendEntryStateTests.swift
- `TrendEntryStateTests` (13) — SU-M15-TREND（子项目 C7 round2 H2/H4）：趋势详情查询身份守卫
  - `test_detailSeriesAlwaysMatchesRequestedIdentity()` (32) — 晚到的旧身份结果绝不落槽（身份 = patientId/metric/origin/range）
  - `test_windowEntersIdentityRangeAsCalendarDays()` (54) — 时间窗按日历日进入身份范围
  - `test_unknownMetricKeyClearsIdentityAndSeries()` (65) — 未知指标键清身份与序列、不残留
  - `test_windowIsAnchoredToTodayNotTheNewestReading()` (79) — 窗末锚今天而非最新读数（业主 2026-09-16 第 1 项锚点策略）
  - `test_sleepMetricLoadsIntegratedSeriesFromAllStageKeys()` (105) — 睡眠族载入整合槽（四阶段切片）；宫格折叠六键出一瓦
  - `test_refreshDetailIfCurrentKeepsIdentityAndIgnoresOtherMetric()` (129) — 写后刷新只对同身份生效、身份（含原范围）不变
- `Seed` (14) / `makeSeed()` (20) — 库 + 趋势仓 + owner + 两种子样本（经 TestStoreFixtures.inMemoryWithOwner）

## Tests/VitaLiberTests/TrendQueryIdentityTests.swift
- `TrendQueryIdentityTests` (12) — SU-M15-TREND / SU-M2-F16（round2 H2 + BR-001）：查询身份回传与来源过滤
  - `test_deviceOriginQueryRequiresSelfBindingAndForeignDeviceRowsAreHidden()` (39) — 设备来源只可能归属本人绑定；非本人全来源查询过滤 device 行
  - `test_originFilterReturnsOnlyRequestedOrigin()` (57) — 来源过滤四态（manual/device/全部/hospital 空）
  - `test_originFilterAppliesToBothDiastolicQueries()` (76) — 舒张压双查询（secondary_value + 独立行）都套来源过滤
  - `test_legacySignatureForwardsAsAllOriginsWithIdentity()` (96) — 兼容包装 = 全来源查询且身份回传
  - `test_excludedForeignDeviceRowsAreHiddenToo()` (105) — 排除点集同样按成员过滤
- `Seed` (13) / `makeSeed()` (23) — Owner + Family 两成员（经 TestStoreFixtures.inMemoryWithOwner）；`insertDeviceHeartRate(_:patient:value:at:)` (38) — device 心率行直插

## Tests/VitaLiberTests/VoiceDictationModelTests.swift
- `VoiceDictationModelTests` (9) — SU-M15-VOICE（FR17.1/FR17.15）：VoiceDictationModel 会话编排
  - `test_reverseFinalsAreDeliveredInPressOrderWithoutStaleLocale()` (76) — 逆序完成仍按按压序投递；语言快照不带错
  - `test_hardStopInvalidatesEveryOldSessionAcrossRestart()` (97) — 硬停使全部旧会话失效（跨重启）
  - `test_stopBeforeScheduledStartUsesTheSameRequestID()` (118) — 调度前停止复用同一请求 id
  - `test_sessionContextSnapshotsLanguageVocabularyAndCallback()` (131) — 会话快照语言/词汇/回调；设置变更不影响在途会话
  - `test_oldPartialCannotSuppressIdenticalCurrentPartial()` (152) — 旧会话同文 partial 不得压掉当前会话
  - `test_failedEarlierSessionDoesNotBlockLaterFinal()` (168) — 早会话失败不阻塞后会话 final
  - `test_authorizationWithdrawalRejectsLateTextAndNewStarts()` (183) — 撤销授权拒绝迟到文本与新启动
  - `test_incompleteFinalKeepsTextButNeverKeepsHighConfidence()` (203) — 不完整 final 保文本、置信度恒 0
  - `test_activityRemainsBusyWhileDrainingAndClearsSynchronouslyOnRevoke()` (217) — 排空中保持 busy；撤销同步清活动态
- `ControlledEngine` (11) — TranscriptionEngine 受控桩（请求序列/完成/失败/partial 注入）；`eventually(_:file:line:)` (65) — 有界轮询断言（10s）

## UITests/VitaLiberUITests/CaptureFlowE2ETests.swift
- `CaptureFlowE2ETests` (12) — SU-M1a-E2E / SU-M1a-SEC（TC-M1a-01/02 · test-plan §4.2 端到端切片）：三卡→建档→家人→首页
  - `test_SU_M1a_E2E_endToEndSliceStory_threeCardsFamilyCompleteToHome()` (70) — 三卡→本人建档→跳过家人→首页空态引导卡 + 进度入口；大标题空白区 ≤48pt；无强制拍摄步
  - `test_noCurrentProfileShowsNoProgressOrEmptyTopBlock()` (102) — 无当前档案不显示伪造 0/8 进度、引导卡上收
  - `test_switchMemberReenterSameInterviewRouteResetsOldStep()` (118) — 换成员后重进同一访谈路由重置旧步骤（B 从自检/触屏入口重新开始）
  - `test_SU_M1a_SEC_backgroundForegroundMustSeeLockScreen()` (163) — FR1.4 冷启动/回前台必见锁屏；桩认证成功后遮罩消失
- `launchFresh()` (14) — 启动参数 [-uitest-reset, -uitest-gate-bypass]；`launchAtFamilyStep()` (21) — 三卡确认 + 本人建档（性别/出生年/血型/紧急联系人）到家人步

## UITests/VitaLiberUITests/LaunchUITests.swift
- `LaunchUITests` (4) — SU-M0-SMOKE：冷启五 Tab 可见
  - `test_coldLaunchFiveTabsVisible()` (6) — 五 Tab 本地化标题逐一存在（首页/健康档案/提醒/健康数据/我的）；独立启动参数隔离持久化状态

## UITests/VitaLiberUITests/PerformanceScreeningTests.swift
- `PerformanceScreeningTests` (5) — SU-M0-PERF / SU-M1c-PERF（TC-M0-08 / TC-M1c-05 · tech §8 模拟器初筛口径）
  - `test_SU_M0_PERF_SU_M1c_PERF_coldLaunchBaselineScreening()` (12) — XCTApplicationLaunchMetric 冷启动完成进入前台（不挂不崩；基线归 L2 真机）

