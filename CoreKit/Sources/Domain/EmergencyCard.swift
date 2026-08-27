import Foundation

/// F15 紧急信息卡（§5.27）：三数据源聚合——过敏（F23）/ 用药（F9）/
/// 健康问题（F11.4）/ 紧急联系人（F3）。
/// BR-003：未确认项不入卡（D 级 OCR 数据绝不呈现为急救事实）。
public struct EmergencyCardItem: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: String            // allergy/medication/healthProblem/contact
    public var title: String
    public var detail: String
    public var confirmed: Bool         // 仅 confirmed=true 入卡
    public init(id: UUID, kind: String, title: String, detail: String, confirmed: Bool) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.confirmed = confirmed
    }
}

public struct EmergencyCard: Sendable, Equatable {
    public var patientId: UUID
    public var allergies: [EmergencyCardItem]
    public var medications: [EmergencyCardItem]
    public var healthProblems: [EmergencyCardItem]
    public var contacts: [EmergencyCardItem]
    public init(patientId: UUID, allergies: [EmergencyCardItem] = [],
                medications: [EmergencyCardItem] = [], healthProblems: [EmergencyCardItem] = [],
                contacts: [EmergencyCardItem] = []) {
        self.patientId = patientId
        self.allergies = allergies
        self.medications = medications
        self.healthProblems = healthProblems
        self.contacts = contacts
    }
}

public enum EmergencyCardService {
    /// 聚合入口：三源 + 联系人；**未确认项一律不入卡**（BR-003）
    public static func assemble(patientId: UUID,
                                allergies: [EmergencyCardItem],
                                medications: [EmergencyCardItem],
                                healthProblems: [EmergencyCardItem],
                                contacts: [EmergencyCardItem]) -> EmergencyCard {
        EmergencyCard(
            patientId: patientId,
            allergies: allergies.filter(\.confirmed),
            medications: medications.filter(\.confirmed),
            healthProblems: healthProblems.filter(\.confirmed),
            contacts: contacts.filter(\.confirmed))
    }

    /// 系统医疗急救卡引导（Medical ID）：只做引导跳转，绝不静默写入
    /// （FR4.5/§5.27——用户显式操作才触发）
    public static func medicalIDGuideNeeded(card: EmergencyCard) -> Bool {
        card.allergies.isEmpty && card.medications.isEmpty
            && card.healthProblems.isEmpty && card.contacts.isEmpty
    }
}

/// F9.8.3 差异月报：纯事实句式（「计划 30 次 / 确认 21 次」），
/// 不做评分、不推断病因（BR-004 延伸）；措辞负清单适用。
public struct InventoryMonthlyReport: Sendable, Equatable {
    public var periodStart: Date
    public var periodEnd: Date
    public var plannedDoses: Int
    public var confirmedDoses: Int
    public var skippedDoses: Int
    public var missedDoses: Int

    /// 唯一允许的月报句式（纯事实，禁止任何评价词）
    public var statement: String {
        "计划 \(plannedDoses) 次 / 确认 \(confirmedDoses) 次 / 跳过 \(skippedDoses) 次 / 未确认 \(missedDoses) 次"
    }
}

public enum InventoryReportRules {
    /// 负清单（一票否决）：月报不得出现评分/推断/建议句式
    static let forbiddenPatterns = [
        "依从性好", "依从性差", "不按时", "不听话", "应该", "建议你", "需要加强",
    ]
    public static func violation(in text: String) -> String? {
        forbiddenPatterns.first { text.contains($0) }
    }

    /// 组装月报（纯事实）
    public static func report(periodStart: Date, periodEnd: Date,
                              planned: Int, confirmed: Int, skipped: Int, missed: Int) -> InventoryMonthlyReport {
        InventoryMonthlyReport(periodStart: periodStart, periodEnd: periodEnd,
                               plannedDoses: planned, confirmedDoses: confirmed,
                               skippedDoses: skipped, missedDoses: missed)
    }
}

/// 盘点归真（FR9.8.5 往返）：账面余量 vs 实物清点 → 差异处理（归真写入 +
/// 审计），禁止静默覆盖。
public struct InventoryReconciliation: Sendable, Equatable {
    public var lotId: UUID
    public var bookConfirmed: Double      // 确认线账面
    public var physicalCount: Double      // 实物清点
    public var resolvedAt: Date
    public var note: String?

    public var difference: Double { physicalCount - bookConfirmed }

    /// 归真结果必须经用户确认才写回（FR9.8.5 验收）
    public var needsConfirmation: Bool { abs(difference) > 0.001 }
}
