import Foundation

/// F9 处方实体（FR9.2 字段全集）+ 用药计划草稿 + 初始批次草稿。
/// BR-003：处方关键字段**全部确认**后 confirmed 才为 true——
/// 未确认处方不得生成正式用药计划（PlanGate 语义在 Domain 纯函数）。

/// 处方来源五通道（FR9.1）：拍纸质处方（OCR 确认流）/ 电子处方面板 / 手工录入 /
/// 从就诊事件带入 / 历史复制
public enum PrescriptionSource: String, Sendable, Codable, Equatable {
    case ocr, electronic, manual, encounter, history
}

/// FR9.2 处方字段全集。`confirmedFields` 记录字段级确认态（FR6.4 语义延伸：
/// 修改时原识别值永久保留并生成修订历史——修订历史由 UI 层收集、随
/// `revisionHistory` 落库，Domain 只承载数据）。
public struct Prescription: Sendable, Equatable, Codable {
    public var id: UUID
    public var patientId: UUID
    public var encounterId: UUID?
    public var documentFileId: UUID?
    public var source: PrescriptionSource
    // 药名（通用名/商品名）
    public var genericName: String
    public var brandName: String?
    // 剂型规格 / 单次剂量 / 每日次数
    public var spec: String
    public var dosePerTake: String?
    public var timesPerDay: Int?
    // 给药方式 / 服用时间与餐食关系
    public var route: String?
    public var timingMeal: String?
    // 疗程起止 / 处方医院医生
    public var durationStart: Date?
    public var durationEnd: Date?
    public var hospital: String?
    public var doctor: String?
    // 医嘱原文（不可编辑，A/C 来源徽章）
    public var adviceText: String
    // 长期/按需标识
    public var isLongTerm: Bool
    public var isAsNeeded: Bool
    // 来源与确认状态（BR-003）
    public var confirmedFields: Set<String>
    public var revisionHistory: [String]
    public var createdAt: TimeInterval

    public init(id: UUID = UUID(), patientId: UUID, encounterId: UUID? = nil,
                documentFileId: UUID? = nil, source: PrescriptionSource,
                genericName: String, brandName: String? = nil, spec: String,
                dosePerTake: String? = nil, timesPerDay: Int? = nil,
                route: String? = nil, timingMeal: String? = nil,
                durationStart: Date? = nil, durationEnd: Date? = nil,
                hospital: String? = nil, doctor: String? = nil,
                adviceText: String = "", isLongTerm: Bool = true,
                isAsNeeded: Bool = false, confirmedFields: Set<String> = [],
                revisionHistory: [String] = [], createdAt: TimeInterval = Date().timeIntervalSince1970) {
        self.id = id; self.patientId = patientId; self.encounterId = encounterId
        self.documentFileId = documentFileId; self.source = source
        self.genericName = genericName; self.brandName = brandName; self.spec = spec
        self.dosePerTake = dosePerTake; self.timesPerDay = timesPerDay
        self.route = route; self.timingMeal = timingMeal
        self.durationStart = durationStart; self.durationEnd = durationEnd
        self.hospital = hospital; self.doctor = doctor; self.adviceText = adviceText
        self.isLongTerm = isLongTerm; self.isAsNeeded = isAsNeeded
        self.confirmedFields = confirmedFields; self.revisionHistory = revisionHistory
        self.createdAt = createdAt
    }
}

/// BR-003 处方确认判定（Domain 纯函数）：关键字段 = 药名 + 剂量相关字段。
/// 手工录入/电子处方（有明确人/系统来源）默认字段全确认；OCR 来源必须逐字段确认。
public enum PrescriptionConfirmation {
    /// 生成正式用药计划必须确认的字段 key
    public static let criticalFieldKeys: Set<String> = [
        "genericName", "spec", "dosePerTake", "timesPerDay",
    ]

    /// 关键字段是否全部确认（未确认处方不得生成正式计划，FR9.3）
    public static func isFullyConfirmed(_ rx: Prescription) -> Bool {
        criticalFieldKeys.isSubset(of: rx.confirmedFields)
    }

    /// 手工/电子来源默认确认（人有明确来源）；OCR 来源从空集起步
    public static func initialConfirmedFields(source: PrescriptionSource) -> Set<String> {
        switch source {
        case .ocr, .history:
            return []   // BR-003：识别/复制来源必须逐字段确认
        case .electronic, .manual, .encounter:
            return criticalFieldKeys   // 电子处方/手输/就诊带入 = 明确来源
        }
    }
}

/// 用药计划草稿（FR9.4/§5.4）：schedule 按 §5.4 schema 编码
public struct MedicationPlanDraft: Sendable, Equatable {
    public var schedule: MedicationSchedule
    public var startDate: Date
    public var endDate: Date?
    public var status: PlanStatus
    public init(schedule: MedicationSchedule, startDate: Date,
                endDate: Date? = nil, status: PlanStatus = .active) {
        self.schedule = schedule; self.startDate = startDate
        self.endDate = endDate; self.status = status
    }
}

/// 初始库存批次草稿（FR9.10：录入时必询失效日期与存储位置——
/// 未知/稍后补填进待办队列，不阻塞保存）
public struct StockLotDraft: Sendable, Equatable {
    public var totalUnits: Double
    public var unitKind: String          // tablet/capsule/patch/vial
    public var expireAt: Date?           // nil = 未知（进待办队列）
    public var storageNote: String?      // nil/空 = 未知（进待办队列）
    public var openedAt: Date?
    public init(totalUnits: Double, unitKind: String, expireAt: Date? = nil,
                storageNote: String? = nil, openedAt: Date? = nil) {
        self.totalUnits = totalUnits; self.unitKind = unitKind
        self.expireAt = expireAt; self.storageNote = storageNote
        self.openedAt = openedAt
    }

    /// FR9.10 待办判定：效期或存储位置缺失 → 进入批次补录待办（FR2.1）
    public var missingRequiredInfo: Bool {
        expireAt == nil || (storageNote ?? "").isEmpty
    }
}

/// FR9.15 计划生命周期事件（历史时间轴记录：开始/调整/暂停/恢复/结束）
public struct PlanLifecycleEvent: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case started, edited, paused, resumed, ended
    }
    public var id: UUID
    public var planId: UUID
    public var kind: Kind
    public var at: Date
    public var note: String?
    public init(id: UUID = UUID(), planId: UUID, kind: Kind, at: Date = Date(),
                note: String? = nil) {
        self.id = id; self.planId = planId; self.kind = kind; self.at = at; self.note = note
    }
}

/// FR9.15 结束原因选择（用户显式操作，系统不自动停药、不提供建议性措辞）
public enum PlanEndReason: String, Sendable, Equatable, Codable, CaseIterable {
    case doctorInstruction   // 遵医嘱停止
    case courseCompleted     // 疗程结束
    case adverseReaction     // 不适/不良反应
    case noLongerNeeded      // 不需要了
    case other               // 其他
}
