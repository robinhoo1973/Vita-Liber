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

    @Test func 五段证据卡与固定免责() {
        let reading = MetricReading(metricKey: "glucose", value: 17.0, unit: "mmol/L",
                                    origin: .manual, measuredAt: Date())
        let card = AlertRuleEngine.evidenceCard(for: reading, severity: .L3, guideline: glucoseGuideline)
        #expect(card.severity == .L3)
        #expect(card.facts.contains("17.0"))
        #expect(card.sourceRef?.contains("糖尿病防治指南") == true)
        #expect(card.disclaimer.contains("不是诊断"))
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
        #expect(report.statement == "计划 30 次 / 确认 21 次 / 跳过 3 次 / 未确认 6 次")
        #expect(InventoryReportRules.violation(in: report.statement) == nil)   // 负清单通过
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
        #expect(HoldToConfirm.accepted(holdSeconds: 0.1, mode: .standard))   // 常规模式不强制
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
        #expect(tiers.contains(.t14), "14 天档未触达 —— 零确认存活失败")
        #expect(tiers.contains(.t7), "7 天档未触达 —— 零确认存活失败")
        #expect(tiers.contains(.t3), "3 天档未触达 —— 零确认存活失败")
        // 顺序必须由宽到紧，且各档只触发一次（不得重复轰炸）
        #expect(tiers == [.t14, .t7, .t3])
        #expect(Set(tiers).count == tiers.count)
    }

    /// 安全线由排程推进，与用户动作无关
    @Test func 安全线按排程自行推进不依赖用户动作() {
        var inv = DualTrackInventory(lotId: UUID(), totalUnits: 30, unitKind: "片")
        inv = InventoryRules.advancePlanTrack(inv, elapsedScheduledDoses: 24, unitsPerDose: 1)
        #expect(inv.remainingPlanUnits == 6, "安全线必须按应服剂次推进")
        #expect(inv.remainingConfirmedUnits == 30, "确认线不得因排程推进而变动（BR-004）")
        #expect(InventoryRules.refillAlertNeeded(inv, dailyPlanUnits: 1, at: epoch),
                "安全线余 6 天必须告警")
    }

    /// 误差方向铁律（ADR-009 不可协商）：告警必须偏**早**，即以安全线而非确认线定级
    @Test func 告警偏早_以安全线定级() {
        var inv = DualTrackInventory(lotId: UUID(), totalUnits: 30, unitKind: "片")
        // 排程推进 25 次，但用户只确认了 5 次
        inv = InventoryRules.advancePlanTrack(inv, elapsedScheduledDoses: 25, unitsPerDose: 1)
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
        #expect(InventoryRules.refillTier(inv, dailyPlanUnits: 1, at: epoch) == .t3,
                "已过期即便余量充足也须最紧急档")
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

    /// TC-M2-02 差异月报纯事实句式（负清单一票否决）
    @Test func 差异月报纯事实且过负清单() {
        let report = InventoryReportRules.report(
            periodStart: epoch, periodEnd: epoch.addingTimeInterval(30 * day),
            planned: 30, confirmed: 21, skipped: 5, missed: 4)
        #expect(report.statement.contains("计划 30 次"))
        #expect(report.statement.contains("确认 21 次"))
        #expect(InventoryReportRules.violation(in: report.statement) == nil,
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
        // 降级文案过 BR-006 负清单（不出现建议/应该等判断词）
        #expect(WordingBlacklist.violation(in: ImageInputRules.noTextMessage) == nil,
                "无文字降级文案也必须过措辞负清单")
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
        let csv = DispenseListRules.csv(rows: rows)
        #expect(csv.contains("药品名,规格,单位,当前余量(安全线),当前余量(确认线),效期"))
        #expect(csv.contains("阿莫西林"))
        #expect(csv.contains("12"))
        #expect(csv.contains("30"))
        // 无医嘱原文列时不得伪造内容（BR-006 延伸）
        #expect(!csv.contains("遵医嘱"))
    }

    @Test func 空清单不得产出空集假绿() {
        #expect(!DispenseListRules.headers.isEmpty)
        let empty = DispenseListRules.csv(rows: [])
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
        let text = MedicationHelpCardRules.cardText([item])
        #expect(text.contains("阿司匹林"))
        #expect(text.contains("100mg"))
        #expect(text.contains("客厅药箱第二层"))
        for marker in MedicationHelpCardRules.forbiddenDiagnosisMarkers {
            #expect(!text.contains(marker), "求助卡不得含诊断类信息（FR15.5 分离）")
        }
    }

    @Test func 空选择不产出卡片() {
        #expect(MedicationHelpCardRules.cardText([]).contains("药品求助卡"))
    }
}
