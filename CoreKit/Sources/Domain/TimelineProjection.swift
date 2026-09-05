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
    /// FR6.4 修订历史（新→旧）——确认态字段被修改时逐条入史
    public var revisionHistory: [String]
    /// 确认集字段内容（详情/导出用）。评审修正：此前 meta_json 只存计数与标题，
    /// 处方样张「可打开」无内容可看——自 V3.58 起随投影一并持久化。
    /// Optional：旧行 meta_json 无此键，decodeIfPresent 兼容（不迁移）。
    public var fields: [CandidateField]?

    public init(id: UUID = UUID(), patientId: UUID, title: String, occurredAt: TimeInterval,
                confirmedFieldCount: Int, totalFieldCount: Int, state: State,
                revisionHistory: [String] = [], fields: [CandidateField]? = nil) {
        self.id = id
        self.patientId = patientId
        self.title = title
        self.occurredAt = occurredAt
        self.confirmedFieldCount = confirmedFieldCount
        self.totalFieldCount = totalFieldCount
        self.state = state
        self.revisionHistory = revisionHistory
        self.fields = fields
    }
}

/// 投影规则（Domain 纯函数）：正式区 = 全部字段确认；待确认区 = 其余。
public enum TimelineProjection {
    public static func entries(from docs: [OcrConfirmationSet], patientId: UUID,
                               occurredAt: TimeInterval) -> [TimelineDocumentEntry] {
        docs.map { set in
            // 保持字段序 + 各字段历史新→旧（flatMap 天然保序，不 sort）
            let history = set.fields.flatMap { $0.revisionHistory }
            return TimelineDocumentEntry(
                id: set.documentId,
                patientId: patientId,
                title: set.fields.first(where: { $0.key == "title" })?.value ?? "",
                occurredAt: occurredAt,
                confirmedFieldCount: set.confirmedFields.count,
                totalFieldCount: set.fields.count,
                state: set.isUsableInTimeline ? .confirmed : .pending,
                revisionHistory: history,
                fields: set.fields)
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
