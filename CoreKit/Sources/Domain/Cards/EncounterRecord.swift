// P9 信封储备（2026-09-16 委员会评审核实 + 业主裁定保留）：
// 本类型是 `InformationCard` 协议族的一员，**当前零生产引用**（仅测试维持；
// 生产落库形状是 `MatchedCard` + `FieldDraft` + 各 Store 行类型）。保留理由：
// 纯值类型、零框架依赖、承载 P9 溯源字段（rawText/source/confidence），
// 作为新卡类模块（如 `HealthMetricCard`——协议族唯一在用者）的现成信封形态。
// 新增卡类优先复用本族协议，勿另起第二套。勿按「无引用」当死代码清理。

import Foundation

public struct EncounterRecord: InformationCard {
    public static let cardType = "encounter"

    public var cardId: String = UUID().uuidString
    public var patientId: String?
    public var source: DataSource = .manual
    public var confidence: Double = 1.0
    public var fieldConfidence: [String: Double] = [:]
    public var rawText: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var visitType: VisitType = .firstVisit
    public var visitDate: Date = Date()
    public var department: String?
    public var doctorName: String?
    public var chiefComplaint: String?
    public var diagnosis: String?
    public var treatmentPlan: String?

    public init() {}
}
