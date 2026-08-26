import Foundation

/// F11 时间轴最小投影（M1a 只含「文档」一类；观察类随 M1c F8 加入）。
/// BR-003 在投影层强制：未确认的 OCR 文档只存在于待确认队列，绝不进入正式区。
public struct TimelineDocumentEntry: Sendable, Equatable, Codable, Identifiable {
    public enum State: String, Sendable, Codable { case pending, confirmed }
    public let id: UUID
    public var patientId: UUID
    public var title: String
    public var occurredAt: TimeInterval
    public var confirmedFieldCount: Int
    public var totalFieldCount: Int
    public var state: State

    public init(id: UUID = UUID(), patientId: UUID, title: String, occurredAt: TimeInterval,
                confirmedFieldCount: Int, totalFieldCount: Int, state: State) {
        self.id = id
        self.patientId = patientId
        self.title = title
        self.occurredAt = occurredAt
        self.confirmedFieldCount = confirmedFieldCount
        self.totalFieldCount = totalFieldCount
        self.state = state
    }
}

/// 投影规则（Domain 纯函数）：正式区 = 全部字段确认；待确认区 = 其余。
public enum TimelineProjection {
    public static func entries(from docs: [OcrConfirmationSet], patientId: UUID,
                               occurredAt: TimeInterval) -> [TimelineDocumentEntry] {
        docs.map { set in
            TimelineDocumentEntry(
                id: set.documentId,
                patientId: patientId,
                title: set.fields.first(where: { $0.key == "title" })?.value ?? "未命名资料",
                occurredAt: occurredAt,
                confirmedFieldCount: set.confirmedFields.count,
                totalFieldCount: set.fields.count,
                state: set.isUsableInTimeline ? .confirmed : .pending)
        }
    }

    /// 正式区查询（BR-003）：未确认绝不出现
    public static func officialTimeline(from entries: [TimelineDocumentEntry]) -> [TimelineDocumentEntry] {
        entries.filter { $0.state == .confirmed }
    }

    public static func pendingQueue(from entries: [TimelineDocumentEntry]) -> [TimelineDocumentEntry] {
        entries.filter { $0.state == .pending }
    }
}
