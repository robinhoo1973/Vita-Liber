import Foundation

/// F11 时间轴统一投影（§5.30）：八类事件 + 健康问题/过敏按「入时间轴开关」参与。
/// Domain 持有投影语义（合并/排序/过滤/游标），Infrastructure 提供 GRDB 联合查询。
public enum TimelineEntryKind: String, Sendable, Equatable, Codable, CaseIterable {
    case encounter, medication, observation, lab, selfMeasured, vaccination, allergy, voiceNote, healthProblem
}

public struct TimelineEntry: Sendable, Equatable, Identifiable {
    public var kind: TimelineEntryKind
    public var date: Date
    public var title: String
    public var summary: String?
    public var refID: UUID
    /// BR-001 成员隔离：投影条目必须携带所属成员
    public var memberId: UUID
    public var id: String { "\(kind.rawValue)-\(refID.uuidString)" }
    public init(kind: TimelineEntryKind, date: Date, title: String, summary: String?, refID: UUID, memberId: UUID) {
        self.kind = kind; self.date = date; self.title = title; self.summary = summary
        self.refID = refID; self.memberId = memberId
    }
}

public enum TimelineFilter: Sendable, Equatable {
    case all
    case kinds(Set<TimelineEntryKind>)
}

/// 游标分页（§5.30：date DESC, id DESC——跨页稳定，插入不重不漏）
public struct TimelineCursor: Sendable, Equatable {
    public var date: Date
    public var refID: UUID
    public init(date: Date, refID: UUID) { self.date = date; self.refID = refID }
}

public struct TimelinePage: Sendable, Equatable {
    public var entries: [TimelineEntry]
    public var nextCursor: TimelineCursor?
    public init(entries: [TimelineEntry], nextCursor: TimelineCursor?) {
        self.entries = entries; self.nextCursor = nextCursor
    }
}

public enum TimelineProjectionRules {
    /// 稳定排序：date DESC，同时刻按 refID DESC（与游标条件一致）
    public static func sort(_ entries: [TimelineEntry]) -> [TimelineEntry] {
        entries.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.refID.uuidString > $1.refID.uuidString
        }
    }

    /// 游标过滤：date < cursor.date 或（同刻且 refID < cursor.refID）
    public static func after(_ entries: [TimelineEntry], cursor: TimelineCursor) -> [TimelineEntry] {
        entries.filter { e in
            if e.date != cursor.date { return e.date < cursor.date }
            return e.refID.uuidString < cursor.refID.uuidString
        }
    }

    /// 页切取 + 下一页游标（满页时以末条为游标）
    public static func page(_ entries: [TimelineEntry], limit: Int) -> TimelinePage {
        guard entries.count > limit else {
            return TimelinePage(entries: entries, nextCursor: nil)
        }
        let pageEntries = Array(entries.prefix(limit))
        let last = entries[limit - 1]
        return TimelinePage(entries: pageEntries,
                            nextCursor: TimelineCursor(date: last.date, refID: last.refID))
    }

    /// 成员隔离（BR-001）：投影条目必须携带所属成员，跨成员查询即空
    public static func scoped(_ entries: [TimelineEntry], member: UUID) -> [TimelineEntry] {
        entries.filter { $0.memberId == member }
    }
}
