import Foundation

/// F2 首页今日聚合（§5.33）：八个异构数据源合并为单一值类型快照，视图零逻辑。
/// 成员隔离 BR-001：所有来源条目必须带 memberId，聚合按当前成员过滤。
public struct TodaySnapshot: Sendable, Equatable {
    public var memberId: UUID
    public var todoItems: [TodoItem]
    public var pendingOCRCount: Int
    public var expiringSoon: [ExpiryItem]
    public var refill: [RefillItem]
    public var alertSummary: [AlertRef]
    public var recentObservations: [ObsRef]
    public var quickCapture: [CaptureKind]

    public init(memberId: UUID, todoItems: [TodoItem] = [], pendingOCRCount: Int = 0,
                expiringSoon: [ExpiryItem] = [], refill: [RefillItem] = [],
                alertSummary: [AlertRef] = [], recentObservations: [ObsRef] = [],
                quickCapture: [CaptureKind] = []) {
        self.memberId = memberId
        self.todoItems = todoItems
        self.pendingOCRCount = pendingOCRCount
        self.expiringSoon = expiringSoon
        self.refill = refill
        self.alertSummary = alertSummary
        self.recentObservations = recentObservations
        self.quickCapture = quickCapture
    }

    public static let empty = TodaySnapshot(memberId: UUID())
}

public struct TodoItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable { case doseSlot, appointment, examPrep, stockBacklog, question, followUp }
    public var kind: Kind
    public var at: Date
    public var title: String
    public var memberId: UUID
    public var id: String { "\(kind.rawValue)-\(title)-\(at.timeIntervalSince1970)" }
    public init(kind: Kind, at: Date, title: String, memberId: UUID) {
        self.kind = kind; self.at = at; self.title = title; self.memberId = memberId
    }
}

public struct ExpiryItem: Sendable, Equatable, Identifiable {
    public var title: String
    public var date: Date
    public var memberId: UUID
    public var id: String { "exp-\(title)-\(date.timeIntervalSince1970)" }
    public init(title: String, date: Date, memberId: UUID) {
        self.title = title; self.date = date; self.memberId = memberId
    }
}

public struct RefillItem: Sendable, Equatable, Identifiable {
    public var medicationName: String
    public var remainingPlanUnits: Double
    public var memberId: UUID
    /// 批次 ID——审查修复：id 原为 "refill-药名"，同一药品多个活跃批次
    /// （双轨库存 + FEFO 正是为此设计）时 SwiftUI ForEach id 碰撞，
    /// 行丢失/未定义行为。纳入 lotId 保证唯一。
    public var lotId: String
    public var id: String { "refill-\(lotId)" }
    public init(medicationName: String, remainingPlanUnits: Double, memberId: UUID,
                lotId: String) {
        self.medicationName = medicationName; self.remainingPlanUnits = remainingPlanUnits
        self.lotId = lotId
        self.memberId = memberId
    }
}

public struct AlertRef: Sendable, Equatable, Identifiable {
    public var severity: String          // L1/L2/L3（仅 L1+ 证据卡入首页）
    public var title: String
    public var memberId: UUID
    public var id: String { "alert-\(severity)-\(title)" }
    public init(severity: String, title: String, memberId: UUID) {
        self.severity = severity; self.title = title; self.memberId = memberId
    }
}

public struct ObsRef: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: String
    public var occurredAt: Date
    public var memberId: UUID
    public init(id: UUID, kind: String, occurredAt: Date, memberId: UUID) {
        self.id = id; self.kind = kind; self.occurredAt = occurredAt; self.memberId = memberId
    }
}

/// 快速拍摄类别（今日快照 + AppRoute.scanCapture 共用单一事实源；
/// Codable/Hashable 为路由编码与 NavigationStack path 所需，
/// Identifiable 供 sheet(item:) 呈现）
public enum CaptureKind: String, Sendable, Equatable, Codable, Hashable, CaseIterable, Identifiable {
    case record, report, prescription, symptom
    public var id: String { rawValue }
}

public enum TodayAggregator {
    /// 聚合入口：成员隔离 → 待办合并排序（时间升序）→ 七卡组装
    public static func snapshot(
        member: UUID,
        todos: [TodoItem],
        pendingOCRCount: Int,
        expiring: [ExpiryItem],
        refills: [RefillItem],
        alerts: [AlertRef],
        observations: [ObsRef]
    ) -> TodaySnapshot {
        let myTodos = todos.filter { $0.memberId == member }.sorted { $0.at < $1.at }
        return TodaySnapshot(
            memberId: member,
            todoItems: myTodos,
            pendingOCRCount: pendingOCRCount,
            expiringSoon: expiring.filter { $0.memberId == member }.sorted { $0.date < $1.date },
            refill: refills.filter { $0.memberId == member },
            alertSummary: alerts.filter { $0.memberId == member && $0.severity != "L0" },
            recentObservations: observations.filter { $0.memberId == member }
                .sorted { $0.occurredAt > $1.occurredAt }
                .prefix(3).map { $0 },
            quickCapture: CaptureKind.allCases)
    }
}
