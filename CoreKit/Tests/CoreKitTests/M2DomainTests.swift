import Foundation
import Testing
@testable import Domain

/// M2 P1 第一批 · Domain 层验收用例（dev-pm §3.4 退出准则的 U 半场）
// binds: SU-M2-F16 — TC-M2-04（五段证据卡 + 措辞负清单一票否决）
@Suite("SU-M2-F16 · 设备预警规则引擎（§5.12/F16）")
struct AlertEngineTests {
    let glucoseGuideline = GuidelineEntry(
        title: "中国 2 型糖尿病防治指南", org: "中华医学会糖尿病学分会", year: 2020,
        clauseRef: "表 3 血糖控制目标", citationUrl: "https://example.org/glucose-guideline",
        version: "2020", checkedAt: Date(), metricKey: "glucose", unit: "mmol/L",
        l1Low: 3.9, l1High: 7.0, l2High: 13.9, l3High: 16.7)

    @Test func 四级定级() {
        let normal = MetricReading(metricKey: "glucose", value: 6.0, unit: "mmol/L",
                                   origin: .manual, measuredAt: Date())
        #expect(AlertRuleEngine.severity(for: normal, guideline: glucoseGuideline) == .L0)
        let l1 = MetricReading(metricKey: "glucose", value: 7.5, unit: "mmol/L",
                               origin: .manual, measuredAt: Date())
        #expect(AlertRuleEngine.severity(for: l1, guideline: glucoseGuideline) == .L1)
        let l2 = MetricReading(metricKey: "glucose", value: 14.0, unit: "mmol/L",
                               origin: .manual, measuredAt: Date())
        #expect(AlertRuleEngine.severity(for: l2, guideline: glucoseGuideline) == .L2)
        let l3 = MetricReading(metricKey: "glucose", value: 17.0, unit: "mmol/L",
                               origin: .manual, measuredAt: Date())
        #expect(AlertRuleEngine.severity(for: l3, guideline: glucoseGuideline) == .L3)
    }

    @Test func 报告自带A级范围优先于信源库() {
        let report = ReferenceRange(lower: 4.0, upper: 6.5, grade: .A)
        let reading = MetricReading(metricKey: "glucose", value: 6.8, unit: "mmol/L",
                                    origin: .hospital, measuredAt: Date(), reportRange: report)
        #expect(AlertRuleEngine.severity(for: reading, guideline: glucoseGuideline) == .L1)
        // 报告范围内 → L0（即使信源库 L1 阈值不同）
        let inRange = MetricReading(metricKey: "glucose", value: 6.0, unit: "mmol/L",
                                    origin: .hospital, measuredAt: Date(), reportRange: report)
        #expect(AlertRuleEngine.severity(for: inRange, guideline: glucoseGuideline) == .L0)
    }

    @Test func 连续三次越限触发L1() {
        let readings = (0..<3).map { i in
            MetricReading(metricKey: "glucose", value: 7.8, unit: "mmol/L",
                          origin: .manual, measuredAt: Date(timeIntervalSince1970: TimeInterval(1000 + i * 60)))
        }
        let severity = AlertRuleEngine.escalate(recent: readings, guideline: glucoseGuideline)
        #expect(severity == .L1, "连续 3 次越限必须触发 L1（FR16.2 验收句）")
        // 只有 2 次 → 不触发
        let two = Array(readings.prefix(2))
        #expect(AlertRuleEngine.escalate(recent: two, guideline: glucoseGuideline) == nil)
    }

    // 第七轮全仓审查修复的回归锚点：跨单位拒绝/NaN 拒绝/单位同义标签
    @Test func 跨单位读数拒绝定级() {
        // mg/dL 读数对 mmol/L 信源：拒绝定级（宁可少警不可错警，F25 摩尔桥接未接线）
        let mgdl = MetricReading(metricKey: "glucose", value: 110.0, unit: "mg/dL",
                                 origin: .manual, measuredAt: Date())
        #expect(AlertRuleEngine.severity(for: mgdl, guideline: glucoseGuideline) == nil,
                "110 mg/dL（≈6.1 mmol/L 正常）不得被 13.9 阈值错定 L2")
    }

    @Test func 非有限读数拒绝定级() {
        let nan = MetricReading(metricKey: "glucose", value: .nan, unit: "mmol/L",
                                origin: .manual, measuredAt: Date())
        #expect(AlertRuleEngine.severity(for: nan, guideline: glucoseGuideline) == nil)
        let inf = MetricReading(metricKey: "glucose", value: .infinity, unit: "mmol/L",
                                origin: .manual, measuredAt: Date())
        #expect(AlertRuleEngine.severity(for: inf, guideline: glucoseGuideline) == nil)
    }

    @Test func 同义单位标签正常定级() {
        // 心率信源 'bpm' vs 录入 '次/分'：同一物理单位，不得被守卫误杀（第七轮修复）
        let heartGuideline = GuidelineEntry(
            title: "AHA 心动过速标准", org: "AHA", year: 2020,
            clauseRef: "tachycardia", citationUrl: "https://example.org/hrt",
            version: "2020", checkedAt: Date(), metricKey: "heart_rate", unit: "bpm",
            l1High: 100)
        let reading = MetricReading(metricKey: "heart_rate", value: 112.0, unit: "次/分",
                                    origin: .manual, measuredAt: Date())
        #expect(AlertRuleEngine.severity(for: reading, guideline: heartGuideline) == .L1,
                "112 次/分（=112 bpm）必须命中 AHA L1（>100）")
    }

    @Test func 升级窗口含L0则拒绝升级() {
        // 第七轮修复锚点：窗口内恰 3 次全部越限才升级——混入 L0 不得升级
        let base = Date(timeIntervalSince1970: 2000)
        let readings = [
            MetricReading(metricKey: "glucose", value: 7.8, unit: "mmol/L", origin: .manual, measuredAt: base),
            MetricReading(metricKey: "glucose", value: 5.6, unit: "mmol/L", origin: .manual,
                          measuredAt: base.addingTimeInterval(60)),
            MetricReading(metricKey: "glucose", value: 7.9, unit: "mmol/L", origin: .manual,
                          measuredAt: base.addingTimeInterval(120)),
        ]
        #expect(AlertRuleEngine.escalate(recent: readings, guideline: glucoseGuideline) == nil,
                "窗口内存在 L0（正常值）不得升级——FR16.2「连续 3 次越限」口径")
    }

    @Test func 五段证据卡结构化字段() {
        let reading = MetricReading(metricKey: "glucose", value: 17.0, unit: "mmol/L",
                                    origin: .manual, measuredAt: Date())
        let card = AlertRuleEngine.evidenceCard(for: reading, severity: .L3, guideline: glucoseGuideline)
        #expect(card.severity == .L3)
        // V3.68：事实为类型化数据（App 层经 L10n 渲染句式；措辞负清单在模板层把关）
        #expect(card.metricKey == "glucose")
        #expect(card.value == 17.0)
        #expect(card.unit == "mmol/L")
        #expect(card.sourceTitle?.contains("糖尿病防治指南") == true)
        #expect(card.levelTag == "L3")
    }

    @Test func 措辞负清单一票否决() {
        #expect(WordingBlacklist.violation(in: "血糖 17，可能是糖尿病") != nil)      // 疾病名推断
        #expect(WordingBlacklist.violation(in: "因为没吃药所以血糖高") != nil)       // 因果句
        #expect(WordingBlacklist.violation(in: "建议服用二甲双胍") != nil)           // 治疗建议
        #expect(WordingBlacklist.violation(in: "本次血糖 17.0 mmol/L，超过参考范围") == nil)  // 纯事实
    }
}

// binds: SU-M2-EMERG — 三数据源聚合 · 未确认项不入卡（BR-003）
// binds: SU-M2-STOCK — TC-M2-02（差异月报纯事实句式 + 盘点归真往返）
@Suite("SU-M2-EMERG · 紧急信息卡与差异月报（§5.27/F9.8.3）")
struct EmergencyCardTests {
    @Test func 未确认项不入卡_BR003() {
        let confirmed = EmergencyCardItem(id: UUID(), kind: "allergy", title: "青霉素过敏",
                                          detail: "皮疹", confirmed: true)
        let unconfirmed = EmergencyCardItem(id: UUID(), kind: "allergy", title: "头孢过敏？",
                                            detail: "OCR 识别待确认", confirmed: false)
        let card = EmergencyCardService.assemble(patientId: UUID(),
                                                 allergies: [confirmed, unconfirmed],
                                                 medications: [], healthProblems: [], contacts: [])
        #expect(card.allergies.count == 1)
        #expect(card.allergies[0].title == "青霉素过敏")
    }

    @Test func 差异月报纯事实句式() {
        let report = InventoryReportRules.report(periodStart: Date(), periodEnd: Date(),
                                                 planned: 30, confirmed: 21, skipped: 3, missed: 6)
        // V3.68：句式移出 Domain——数值字段断言；负清单对同形句式（App 层
        // L10n 模板渲染结果）依然一票否决
        #expect(report.plannedDoses == 30)
        #expect(report.confirmedDoses == 21)
        #expect(report.skippedDoses == 3)
        #expect(report.missedDoses == 6)
        #expect(InventoryReportRules.violation(in: "计划 30 次 / 确认 21 次 / 跳过 3 次 / 未确认 6 次") == nil)   // 负清单通过
        #expect(InventoryReportRules.violation(in: "你的依从性差") != nil)      // 一票否决
        #expect(InventoryReportRules.violation(in: "建议你按时吃药") != nil)
    }

    @Test func 盘点归真需确认() {
        let recon = InventoryReconciliation(lotId: UUID(), bookConfirmed: 10,
                                            physicalCount: 8, resolvedAt: Date(), note: nil)
        #expect(recon.difference == -2)
        #expect(recon.needsConfirmation)
        let same = InventoryReconciliation(lotId: UUID(), bookConfirmed: 10,
                                           physicalCount: 10, resolvedAt: Date(), note: nil)
        #expect(!same.needsConfirmation)
    }
}

// binds: SU-M2-CARE — TC-M2-03（SOS 两步可达 + 震颤防抖 + 长按门槛）
@Suite("SU-M2-CARE · 关怀模式与 SOS（§5.15/FR1.8）")
struct CareModeTests {
    @Test func 关怀参数覆盖() {
        #expect(CareModeMetrics.care.touchTarget == 64)
        #expect(CareModeMetrics.care.tremorGuardSeconds == 0.3)
        #expect(CareModeMetrics.care.holdConfirmSeconds == 0.6)
        #expect(CareModeMetrics.standard.touchTarget == 44)
    }

    @Test func 震颤防抖() {
        let now = Date(timeIntervalSince1970: 100)
        #expect(TremorGuard.shouldAccept(lastActionAt: nil, now: now, mode: .care))
        #expect(!TremorGuard.shouldAccept(lastActionAt: now.addingTimeInterval(-0.1),
                                          now: now, mode: .care))
        #expect(TremorGuard.shouldAccept(lastActionAt: now.addingTimeInterval(-0.5),
                                         now: now, mode: .care))
        // 常规模式无防抖
        #expect(TremorGuard.shouldAccept(lastActionAt: now.addingTimeInterval(-0.1),
                                         now: now, mode: .standard))
    }

    @Test func 长按确认门槛() {
        #expect(HoldToConfirm.accepted(holdSeconds: 0.7, mode: .care))
        #expect(!HoldToConfirm.accepted(holdSeconds: 0.3, mode: .care))
        // 常规模式同样 0.6s（build 147 审查修复：0s 即触发 = 口袋误触即进紧急页）
        #expect(!HoldToConfirm.accepted(holdSeconds: 0.1, mode: .standard))
        #expect(HoldToConfirm.accepted(holdSeconds: 0.7, mode: .standard))
    }

    @Test func SOS两步可达且门禁豁免() {
        #expect(SOSRules.isGateExempt("sos"))
        #expect(!SOSRules.isGateExempt("timeline"))
        #expect(SOSRules.requiresHoldConfirm("sos", mode: .standard))
        #expect(SOSRules.requiresHoldConfirm("sos", mode: .care))
    }

    @Test func 挂号深链本地映射() {
        let registry = [HospitalDeepLink(hospitalName: "市一医院", baseURL: "https://sy.example",
                                         template: "https://sy.example/appointment/{bookingNo}")]
        let link = HospitalDeepLinkRegistry.link(for: "市一医院", in: registry)
        #expect(link?.url(bookingNo: "A123") == "https://sy.example/appointment/A123")
        #expect(HospitalDeepLinkRegistry.link(for: "未收录医院", in: registry) == nil)   // 走补录
    }
}

// binds: SU-M2-STOCK — TC-M2-01 零确认存活（M2 一票否决）+ TC-M2-02 月报纯事实
/// **M2 一票否决**：建计划后用户零操作，续药提醒仍须按时分级触达。
///
/// 为什么必须单列一个套件：`applyResolution` 需要 `DoseUserAction` 才扣减，
/// 而「零确认」恰恰意味着永远没有 action 传进来——安全线永不减少、
/// 续药告警永不触发。用户什么都不做时反而收不到「该买药了」，正是这条红线要防的。
@Suite("SU-M2-STOCK · 双轨库存零确认存活与差异月报（FR9.8/ADR-009）")
struct SUM2StockTests {

    private let day: TimeInterval = 86400
    private var epoch: Date { Date(timeIntervalSince1970: 1_700_000_000) }
    private var gregorian: Calendar { Calendar(identifier: .gregorian) }

    /// 一票否决：零确认下三级续药提醒全部触达
    @Test func 零确认存活_三级续药提醒全触达() {
        // 30 天量、每天 1 单位；建计划后一个动作都不做
        let fired = InventoryRules.refillTiersFired(
            initialUnits: 30, dailyPlanUnits: 1,
            from: epoch, to: epoch.addingTimeInterval(35 * day), calendar: gregorian)
        let tiers = fired.map(\.tier)
        #expect(tiers.contains(.t7), "7 天档未触达 —— 零确认存活失败")
        #expect(tiers.contains(.t3), "3 天档未触达 —— 零确认存活失败")
        #expect(tiers.contains(.t0), "当日档未触达 —— 零确认存活失败")
        // 顺序必须由宽到紧，且各档只触发一次（不得重复轰炸）
        #expect(tiers == [.t7, .t3, .t0])
        #expect(Set(tiers).count == tiers.count)
    }

    /// 安全线由排程推进，与用户动作无关
    /// （规则①清死代码：原经零生产调用方的 advancePlanTrack 批量口径——已删；
    ///   同口径改经扣减矩阵 deductPlan，与 materializeMissed 生产路径一致）
    @Test func 安全线按排程自行推进不依赖用户动作() {
        var inv = DualTrackInventory(lotId: UUID(), totalUnits: 30, unitKind: "片")
        inv = InventoryRules.deductPlan(inv, units: 24)
        #expect(inv.remainingPlanUnits == 6, "安全线必须按应服剂次推进")
        #expect(inv.remainingConfirmedUnits == 30, "确认线不得因排程推进而变动（BR-004）")
        #expect(InventoryRules.refillAlertNeeded(inv, dailyPlanUnits: 1, at: epoch),
                "安全线余 6 天必须告警")
    }

    /// 误差方向铁律（ADR-009 不可协商）：告警必须偏**早**，即以安全线而非确认线定级
    @Test func 告警偏早_以安全线定级() {
        var inv = DualTrackInventory(lotId: UUID(), totalUnits: 30, unitKind: "片")
        // 排程推进 25 次，但用户只确认了 5 次
        inv = InventoryRules.deductPlan(inv, units: 25)
        inv = InventoryRules.deductConfirmed(inv, units: 5)
        #expect(inv.remainingPlanUnits == 5)
        #expect(inv.remainingConfirmedUnits == 25)
        // 安全线余 5 天 → 命中 ≤7 档
        #expect(InventoryRules.refillTier(inv, dailyPlanUnits: 1, at: epoch) == .t7,
                "必须按安全线余 5 天定级")
        // 对照：若误用确认线（余 25 天）会判为**完全无需告警**——那就是「告警偏晚」，
        // ADR-009 明令误差必须偏向更早告警，此处即该铁律的可执行形态。
        var confirmedLineView = inv
        confirmedLineView.remainingPlanUnits = inv.remainingConfirmedUnits
        #expect(InventoryRules.refillTier(confirmedLineView, dailyPlanUnits: 1, at: epoch) == nil,
                "确认线视角下不告警——证明用确认线定级会漏报，故必须用安全线")
    }

    /// 过期批次按最紧急档处理
    @Test func 过期批次按最紧急档() {
        var inv = DualTrackInventory(lotId: UUID(), totalUnits: 100, unitKind: "片",
                                     expireAt: epoch.addingTimeInterval(-day))
        inv.remainingPlanUnits = 100
        #expect(InventoryRules.refillTier(inv, dailyPlanUnits: 1, at: epoch) == .t0,
                "已过期即便余量充足也须最紧急档（当日置顶）")
    }

    /// 余量充足时不得告警（反向断言——防「永远告警」的坏秤，ERR#32 同族）
    @Test func 余量充足不告警() {
        let inv = DualTrackInventory(lotId: UUID(), totalUnits: 90, unitKind: "片")
        #expect(InventoryRules.refillTier(inv, dailyPlanUnits: 1, at: epoch) == nil)
        #expect(InventoryRules.refillTiersFired(
            initialUnits: 90, dailyPlanUnits: 1,
            from: epoch, to: epoch.addingTimeInterval(10 * day), calendar: gregorian).isEmpty)
    }

    /// dailyPlanUnits 为 0（计划暂停）不得除零、不得告警
    @Test func 零日用量不告警且不崩() {
        let inv = DualTrackInventory(lotId: UUID(), totalUnits: 30, unitKind: "片")
        #expect(InventoryRules.refillTier(inv, dailyPlanUnits: 0, at: epoch) == nil)
        #expect(InventoryRules.refillTiersFired(initialUnits: 30, dailyPlanUnits: 0,
                                                from: epoch, to: epoch.addingTimeInterval(day),
                                                calendar: gregorian).isEmpty)
    }

    /// TC-M2-02 差异月报纯事实句式（负清单一票否决；V3.68 句式移出 Domain——
    /// 数值字段断言 + 与 App 层 L10n 模板同形的句子过负清单）
    @Test func 差异月报纯事实且过负清单() {
        let report = InventoryReportRules.report(
            periodStart: epoch, periodEnd: epoch.addingTimeInterval(30 * day),
            planned: 30, confirmed: 21, skipped: 5, missed: 4)
        #expect(report.plannedDoses == 30)
        #expect(report.confirmedDoses == 21)
        #expect(report.skippedDoses == 5)
        #expect(report.missedDoses == 4)
        let statement = "计划 30 次 / 确认 21 次 / 跳过 5 次 / 未确认 4 次"
        #expect(InventoryReportRules.violation(in: statement) == nil,
                "月报出现评价/建议句式即一票否决")
    }

    /// 负清单本身必须真的能拦住（防坏秤）
    @Test func 负清单可拦截评价句式() {
        #expect(InventoryReportRules.violation(in: "你的依从性差，建议你按时服药") != nil)
        #expect(InventoryReportRules.violation(in: "计划 30 次 / 确认 21 次") == nil)
    }
}

// binds: SU-M2-CARE — F17 全量文法集（M2）在单一事实源内的覆盖断言
/// F17.1-17.8 全量文法（M2）的覆盖性断言：生产文法表必须覆盖 F7 六类指标 +
/// 血压双值 + 体温（FR7.10 语音录入路径），以及档案访谈全字段。
@Suite("SU-M2-CARE · F17 全量文法集覆盖（VoiceGrammarDefaults 单一事实源）")
struct F17FullGrammarTests {

    @Test func 指标文法覆盖六类与血压双值() {
        let keys = Set(VoiceGrammarDefaults.metricRules.map(\.metricKey))
        for required in ["glucose", "blood_pressure_sys", "blood_pressure_dia",
                         "heart_rate", "weight", "blood_oxygen", "temperature"] {
            #expect(keys.contains(required), "生产文法缺指标 \(required)——FR7.10 语音录入无法覆盖")
        }
    }

    @Test func 血压连读一条话出两个字段() {
        let drafts = VoiceStructuringEngine.extractMetric(
            "血压 148 92 心率 76", rules: VoiceGrammarDefaults.metricRules)
        #expect(drafts.contains { $0.key == "blood_pressure_sys" && $0.value == "148" },
                "收缩压抽取失败")
        #expect(drafts.contains { $0.key == "blood_pressure_dia" && $0.value == "92" },
                "舒张压抽取失败")
        #expect(drafts.contains { $0.key == "heart_rate" && $0.value == "76" })
    }

    @Test func 档案访谈字段全覆盖() {
        let keys = Set(VoiceGrammarDefaults.profileRules.map(\.fieldKey))
        for required in ["allergy", "pastHistory", "currentMeds",
                         "emergencyContact", "surgery", "familyHistory"] {
            #expect(keys.contains(required), "档案访谈缺字段 \(required)")
        }
    }

    @Test func 全量提醒文法覆盖重复规则() {
        let drafts = VoiceStructuringEngine.extractReminder(
            "下周一早上八点提醒我复诊，每周", rules: VoiceGrammarDefaults.reminderRules)
        #expect(!drafts.isEmpty)
        #expect(drafts.contains { $0.key == "repeat" })
    }
}

// binds: SU-M2-CARE — FR12.11 AI 图片输入（P0.5 滞留清偿）的 BR-003 判据
@Suite("SU-M2-CARE · FR12.11 图片识别未确认判据（BR-003）")
struct ImageInputRuleTests {

    @Test func 识别文本恒为D级待确认() {
        let rec = ImageInputRules.Recognition(lines: ["总胆固醇 6.8 mmol/L"], confidence: 0.99)
        let fields = ImageInputRules.draftFields(from: rec)
        #expect(fields.count == 1)
        #expect(fields[0].grade == .ocrUnconfirmed,
                "BR-003：图片识别结果一律『识别未确认』——置信度再高也不得为确定性陈述")
        #expect(ImageInputRules.requiresConfirmation(rec))
    }

    @Test func 纯影像无文字给手输替代() {
        let empty = ImageInputRules.Recognition(lines: ["  "], confidence: 0)
        #expect(empty.isEmpty)
        #expect(!ImageInputRules.requiresConfirmation(empty))
        #expect(ImageInputRules.draftFields(from: empty).isEmpty)
        // 第四轮全仓审查修复：降级文案改 App 层 L10n 渲染（Domain 只出类型化键，
        // 零硬编码中文）；BR-006 措辞负清单对 .strings 值全量校验由
        // VitaLiberTests M15 套件承担（本键已登记 registeredKeys 即被覆盖）
        #expect(ImageInputRules.noTextKey == "image_input.noText",
                "无文字降级键必须稳定——App 层 L10n 契约")
    }

    @Test func 识别结果经统一确认模板() {
        let rec = ImageInputRules.Recognition(lines: ["血糖 6.2"], confidence: 0.95)
        let set = VoiceInputTemplate.confirmationSet(drafts: [
            FieldDraft(key: "image_text", value: rec.text, confidence: rec.confidence)
        ])
        #expect(set.fields.allSatisfy { $0.grade == .ocrUnconfirmed })
        #expect(!set.isUsableInTimeline, "确认前不可作为确定性陈述")
    }
}

// binds: SU-M2-CARE — FR10.6 挂号深链本地映射
@Suite("SU-M2-CARE · FR10.6 挂号深链本地映射表")
struct DeepLinkTests {

    @Test func 精确匹配命中() {
        let link = HospitalDeepLinkRegistry.link(for: "协和医院",
                                                 in: HospitalDeepLinkRegistry.defaults)
        #expect(link != nil)
        #expect(link?.baseURL.contains("guahao") == true)
    }

    @Test func 模糊匹配降级且一字之差不丢入口() {
        let link = HospitalDeepLinkRegistry.fuzzyLink(for: "协和医院（东院）",
                                                      in: HospitalDeepLinkRegistry.defaults)
        #expect(link != nil, "医院全名与表内条目一字之差不得丢深链入口")
    }

    @Test func 不在表内返回nil走手输补录() {
        #expect(HospitalDeepLinkRegistry.link(for: "从未听说的医院",
                                              in: HospitalDeepLinkRegistry.defaults) == nil)
        #expect(HospitalDeepLinkRegistry.fuzzyLink(for: "从未听说的医院",
                                                  in: HospitalDeepLinkRegistry.defaults) == nil)
    }

    @Test func 映射表默认档非空且离线可用() {
        #expect(!HospitalDeepLinkRegistry.defaults.isEmpty,
                "空映射表会让所有复诊提醒失去深链入口——空集不得判过")
        #expect(HospitalDeepLinkRegistry.defaults.allSatisfy { !$0.template.isEmpty })
    }
}

// binds: SU-M2-CARE — FR13.8 配药清单（纯事实 CSV，不伪造医嘱原文）
@Suite("SU-M2-CARE · FR13.8 配药清单导出")
struct DispenseListTests {

    @Test func CSV列结构与纯事实() {
        let rows = [
            DispenseListRules.Row(name: "阿莫西林", spec: "0.25g", unitKind: "tablet",
                                  planUnits: 12, confirmedUnits: 9,
                                  expireAt: Date(timeIntervalSince1970: 1_800_000_000)),
            DispenseListRules.Row(name: "二甲双胍", spec: "0.5g", unitKind: "tablet",
                                  planUnits: 30, confirmedUnits: 30, expireAt: nil),
        ]
        // V3.68：表头由调用方经 L10n 传入（Domain 不硬编码中文表头）
        let headers = ["药品名", "规格", "单位", "当前余量(安全线)", "当前余量(确认线)", "效期"]
        let csv = DispenseListRules.csv(rows: rows, headers: headers)
        #expect(csv.contains("药品名,规格,单位,当前余量(安全线),当前余量(确认线),效期"))
        #expect(csv.contains("阿莫西林"))
        #expect(csv.contains("12"))
        #expect(csv.contains("30"))
        // 无医嘱原文列时不得伪造内容（BR-006 延伸）
        #expect(!csv.contains("遵医嘱"))
    }

    @Test func 空清单不得产出空集假绿() {
        let headers = ["药品名", "规格", "单位", "当前余量(安全线)", "当前余量(确认线)", "效期"]
        let empty = DispenseListRules.csv(rows: [], headers: headers)
        #expect(empty.contains("药品名"), "空清单也必须有表头——空集不得判过")
    }
}

// binds: SU-M2-CARE — FR9.13a 药品求助卡（最小必要：照片默认不含）
@Suite("SU-M2-CARE · FR9.13a 药品求助卡")
struct MedicationHelpCardTests {

    @Test func 卡片默认不含位置照片() {
        let item = MedicationHelpCardRules.Input(
            lotId: UUID(), medicationName: "阿司匹林", spec: "100mg",
            remainingUnits: 8, unitKind: "tablet",
            expireAt: Date(timeIntervalSince1970: 1_800_000_000),
            storageNote: "客厅药箱第二层", includeStoragePhoto: false)
        #expect(!MedicationHelpCardRules.shouldAttachPhoto(item),
                "FR9.13a：位置照片默认不在卡内，须显式勾选")
        var withPhoto = item
        withPhoto.includeStoragePhoto = true
        #expect(MedicationHelpCardRules.shouldAttachPhoto(withPhoto))
    }

    @Test func 卡片文本含必要字段且不含诊断() {
        let item = MedicationHelpCardRules.Input(
            lotId: UUID(), medicationName: "阿司匹林", spec: "100mg",
            remainingUnits: 8, unitKind: "tablet",
            expireAt: Date(timeIntervalSince1970: 1_800_000_000),
            storageNote: "客厅药箱第二层", includeStoragePhoto: false)
        let text = MedicationHelpCardRules.cardText([item]) ?? ""   // 非空输入必非 nil；nil 时下方 contains 全失败（响亮）
        #expect(text.contains("阿司匹林"))
        #expect(text.contains("100mg"))
        #expect(text.contains("客厅药箱第二层"))
        for marker in MedicationHelpCardRules.forbiddenDiagnosisMarkers {
            #expect(!text.contains(marker), "求助卡不得含诊断类信息（FR15.5 分离）")
        }
    }

    @Test func 空选择不产出卡片() {
        // 第八轮修复：空选择返回 nil（FR9.13a 前提「选择一个或多个」）——
        // 原断言 cardText([]) 恒含标题、永不可败，锁定了与规格相反的行为
        #expect(MedicationHelpCardRules.cardText([]) == nil)
    }
}

// binds: SU-M2-CARE — FR24.2 发送状态机（迁移白名单，状态不可伪造）
@Suite("SU-M2-CARE · FR24.2 发送状态迁移白名单")
struct MessageStatusTests {

    @Test func 合法迁移路径() {
        #expect(MessageStatusRules.canTransition(from: .sent, to: .ackPending))
        #expect(MessageStatusRules.canTransition(from: .sent, to: .timeout))
        #expect(MessageStatusRules.canTransition(from: .ackPending, to: .acked))
        #expect(MessageStatusRules.canTransition(from: .ackPending, to: .timeout))
    }

    @Test func 回退与旁路跳变一律拒绝() {
        #expect(!MessageStatusRules.canTransition(from: .acked, to: .sent),
                "已回执不得退回已发送——状态不可伪造")
        #expect(!MessageStatusRules.canTransition(from: .acked, to: .ackPending))
        #expect(!MessageStatusRules.canTransition(from: .sent, to: .acked),
                "无回执不得跳到已回执")
        #expect(!MessageStatusRules.canTransition(from: .timeout, to: .acked),
                "超时后不补回执")
    }
}

@Suite("SU-M2-DOC · 第四轮全仓审查修复回归（PendingOcrRules/OcrConfirmationSet/ImageInputRules）")
struct Round4DomainTests {

    @Test func 超72h置顶判定走日历日单一出口() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // 恰好 72 小时（3 个日历日整）不算超窗——严格大于语义
        let exactly3d = DayArithmetic.offset(days: -3, from: now, calendar: cal)
        #expect(!PendingOcrRules.isOverdue(createdAt: exactly3d, now: now))
        let older = DayArithmetic.offset(days: -4, from: now, calendar: cal)
        #expect(PendingOcrRules.isOverdue(createdAt: older, now: now))
        // 3 天筛选窗：边界内侧命中、外侧不命中
        let within = DayArithmetic.offset(days: -2, from: now, calendar: cal)
        #expect(PendingOcrRules.isWithinLastDays(3, createdAt: within, now: now))
        #expect(!PendingOcrRules.isWithinLastDays(3, createdAt: older, now: now))
    }

    @Test func 全部确认闸门只拦低置信度未确认字段() {
        var set = OcrConfirmationSet(fields: [
            CandidateField(key: "a", displayLabel: "A", rawText: "x", confidence: 0.9),
            CandidateField(key: "b", displayLabel: "B", rawText: "y", confidence: 0.3),
        ])
        #expect(set.hasUnconfirmedLowConfidence, "低置信度未确认 → 全部确认禁用")
        #expect(!set.allConfirmAllowed)
        // 逐条确认低置信字段后闸门放开（§5.30：仅当无红色低置信可全部确认）
        _ = set.fields[1].confirm()
        #expect(set.allConfirmAllowed)
        // 批量确认：已确认字段不动、已拒绝字段不升格
        var set2 = OcrConfirmationSet(fields: [
            CandidateField(key: "a", displayLabel: "A", rawText: "x", confidence: 0.9),
            CandidateField(key: "b", displayLabel: "B", rawText: "y", confidence: 0.9),
        ])
        set2.fields[1].reject()
        let confirmed = set2.confirmAllRemaining()
        #expect(confirmed == 1)
        #expect(set2.fields[0].isConfirmed)
        #expect(set2.fields[1].grade == .rejected, "已拒绝字段不得批量升格（BR-003）")
        // 拒绝可恢复（reenable 状态机补全）
        let reenabled = set2.fields[1].reenable()
        #expect(reenabled)
        #expect(set2.fields[1].grade == .ocrUnconfirmed)
    }

    @Test func 已放弃的低置信字段不得卡死全部确认闸门() {
        var set = OcrConfirmationSet(fields: [
            CandidateField(key: "a", displayLabel: "A", rawText: "x", confidence: 0.9),
            CandidateField(key: "b", displayLabel: "B", rawText: "y", confidence: 0.2),
        ])
        #expect(!set.allConfirmAllowed)
        // ✕ 放弃低置信字段 → 闸门必须放开（rejected 不被批量确认触碰）
        set.fields[1].reject()
        #expect(set.allConfirmAllowed, "已放弃字段不得卡死保存——Phase 3 补漏回归")
        #expect(set.confirmAllRemaining() == 1)
    }

    @Test func MIME字节嗅探与扩展名映射() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(ImageInputRules.sniffMimeType(of: png) == "image/png")
        #expect(ImageInputRules.fileExtension(for: "image/png") == "png")
        let jpg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        #expect(ImageInputRules.sniffMimeType(of: jpg) == "image/jpeg")
        let gif = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])
        #expect(ImageInputRules.sniffMimeType(of: gif) == "image/gif")
        let webp = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50])
        #expect(ImageInputRules.sniffMimeType(of: webp) == "image/webp")
        let heic = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])
        #expect(ImageInputRules.sniffMimeType(of: heic) == "image/heic")
        #expect(ImageInputRules.fileExtension(for: "image/heic") == "heic")
        // 未知字节回落调用方兜底
        #expect(ImageInputRules.sniffMimeType(of: Data([0x01, 0x02]), fallback: "image/jpeg") == "image/jpeg")
    }

    @Test func 处方标签按身份匹配不受本地化影响() {
        let labels = PrescriptionFieldMapper.Labels(
            hospital: "醫院", doctor: "醫師", frequency: "頻次",
            dosage: "劑量", drugName: "藥名", other: "其他")
        let fields = [
            CandidateField(key: "h", displayLabel: labels.hospital, rawText: "XX醫院", confidence: 0.8, grade: .userConfirmed),
            CandidateField(key: "d", displayLabel: labels.doctor, rawText: "王醫師", confidence: 0.8, grade: .userConfirmed),
            CandidateField(key: "o", displayLabel: labels.other, rawText: "說明", confidence: 0.8, grade: .userConfirmed),
        ]
        let (hospital, doctor, advice) = PrescriptionFieldMapper.buildAdviceText(confirmed: fields, labels: labels)
        #expect(hospital == "XX醫院", "zh-Hant 标签按身份匹配——原简体字面量匹配恒 NULL")
        #expect(doctor == "王醫師")
        #expect(advice.contains("醫院"))
        // 繁体原文关键词启发式（guessLabel 经 draftFields 间接验证）
        let drafts = PrescriptionFieldMapper.draftFields(from: ["XX醫院", "每 日三次"], labels: labels)
        #expect(drafts[0].displayLabel == labels.hospital, "繁体「醫院」行不得落「其他」")
        #expect(drafts[1].displayLabel == labels.frequency)
    }
}

/// 第八轮全仓审查修复锚点：单剂剂量解析单一事实源（1/2/半/0.5片 此前
/// 裸 Double 全 nil → NULL dose_plan_units → 安全线 ?? 1 双倍扣账）与
/// 餐锚同义词去重（「早,早餐前」此前生成同一时刻双剂量行）。
@Suite("SU-M2-R8 · 第八轮修复锚点（剂量解析/餐锚去重/紧急词表）")
struct Round8DomainFixTests {

    @Test func 剂量解析覆盖口语形态() {
        #expect(DoseScheduleEngine.DoseInputParser.parse("1") == 1)
        #expect(DoseScheduleEngine.DoseInputParser.parse("0.5") == 0.5)
        #expect(DoseScheduleEngine.DoseInputParser.parse("0.5片") == 0.5)
        #expect(DoseScheduleEngine.DoseInputParser.parse("半") == 0.5)
        #expect(DoseScheduleEngine.DoseInputParser.parse("半片") == 0.5)
        #expect(DoseScheduleEngine.DoseInputParser.parse("1/2") == 0.5)
        #expect(DoseScheduleEngine.DoseInputParser.parse("1/2片") == 0.5)
        #expect(DoseScheduleEngine.DoseInputParser.parse("二") == 2)
        #expect(DoseScheduleEngine.DoseInputParser.parse("abc") == nil)
        #expect(DoseScheduleEngine.DoseInputParser.parse("1/0") == nil)
        #expect(DoseScheduleEngine.DoseInputParser.parse("") == nil)
        #expect(DoseScheduleEngine.DoseInputParser.parse("1/2/3") == nil)
    }

    @Test func 餐锚同义词去重() {
        #expect(DoseScheduleEngine.MealAnchorRules.parse("早,早餐前") == ["beforeBreakfast"])
        #expect(DoseScheduleEngine.MealAnchorRules.parse("空腹,早") == ["beforeBreakfast"])
        #expect(DoseScheduleEngine.MealAnchorRules.parse("早,晚") == ["beforeBreakfast", "beforeDinner"])
        #expect(DoseScheduleEngine.MealAnchorRules.parse("未知词") == [])
    }

    @Test func 紧急词表含语音语义词() {
        // V3.40 三轨定案：F19 语义词并入 F12 单一词表（语音入口紧急前置）
        for word in ["急救", "救命", "救护车", "叫120", "打120", "拨打120", "胸闷"] {
            #expect(EmergencyKeywordRules.match("我\(word)"), "「\(word)」必须命中 BR-012 前置")
        }
        // 严重反应词表 = F12 基础表 + 过敏补充（单一事实源复合）
        for word in EmergencyKeywordRules.keywords {
            #expect(SevereReactionRules.severeKeywords.contains(word),
                    "F12 词「\(word)」必须包含在严重反应词表中")
        }
        #expect(SevereReactionRules.severeKeywords.contains("过敏性休克"))
    }
}


/// FR10.7 标记错过时间门槛（Domain 规则单一出口）——视图与商店共享，
/// 未来预约不可误标错过（错标 = 分级提醒全取消 + 2h 跟进提前武装）。
struct AppointmentRulesTests {
    @Test func 未到开始时间不可标错过() {
        let future = Date().addingTimeInterval(3600)
        #expect(!AppointmentRules.canMarkMissed(startsAt: future),
                "未来预约不得标记错过")
    }

    @Test func 已过开始时间可标错过() {
        let past = Date().addingTimeInterval(-3600)
        #expect(AppointmentRules.canMarkMissed(startsAt: past),
                "已开始/已过预约可标记错过")
    }

    @Test func 边界恰为当前时刻可标错过() {
        let now = Date()
        #expect(AppointmentRules.canMarkMissed(startsAt: now),
                "startsAt == now 时（已开始）可标错过")
    }
}

/// FR9.11 效期状态分类（BatchExpiryRules.status 单一出口）——视图三级
/// 播报与临期提醒共用同一阈值，域外不得自建 7/30 边界。
struct BatchExpiryStatusTests {
    @Test func 已过期归类expired() {
        let now = Date()
        #expect(BatchExpiryRules.status(expireAt: now.addingTimeInterval(-1), now: now) == .expired,
                "expireAt < now 必须归类 expired")
    }

    @Test func 七天内归类within7() {
        let now = Date()
        let d6 = DayArithmetic.offset(days: 6, from: now)
        #expect(BatchExpiryRules.status(expireAt: d6, now: now) == .within7,
                "6 天后到期必须归类 within7")
    }

    @Test func 三十天内归类within30() {
        let now = Date()
        let d8 = DayArithmetic.offset(days: 8, from: now)
        let d30 = DayArithmetic.offset(days: 30, from: now)
        #expect(BatchExpiryRules.status(expireAt: d8, now: now) == .within30,
                "8 天后到期必须归类 within30")
        #expect(BatchExpiryRules.status(expireAt: d30, now: now) == .within30,
                "恰 30 天到期必须含边界（此前视图内 <= 与 > 边界不一致）")
    }

    @Test func 三十天外归类later() {
        let now = Date()
        let d31 = DayArithmetic.offset(days: 31, from: now)
        #expect(BatchExpiryRules.status(expireAt: d31, now: now) == .later,
                "31 天后到期必须归类 later（临期播报不涉及）")
    }
}
