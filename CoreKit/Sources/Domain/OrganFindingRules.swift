import Foundation

/// FR11.5 脏器陈述抽取（V4.05）：病历/检查/检验文本 → 器官条目草稿（纯函数，Linux 可单测）。
///
/// 纪律（BR-003 / BR-006）：
/// - 恒为 **D 级候选**——仅提议，用户确认后才归档 `organ_entry`；
/// - `statement` 原文保真：不改写、不解释、不评级（措辞负清单）；
/// - 无器官命中即不生成（**绝不猜**）；日期缺失不猜（nil 透传）；
/// - 来源恒为来源信息卡（`sourceKind` + `sourceId`，归档时回填引用）。
public enum OrganFindingRules {
    /// 输入陈述（生产者：OCR 确认流的诊断行/报告叙事行；本层只承载数据，不做 IO）。
    public struct FindingStatement: Sendable, Equatable {
        public var text: String
        /// 卡片/行日期（nil = 未知不猜）。
        public var occurredAt: Date?
        /// 来源信息卡类型（如 diagnosis / examReport / labReport）。
        public var sourceKind: String
        /// 来源行 id（归档回填 `organ_entry.source_id`）。
        public var sourceId: UUID
        public init(text: String, occurredAt: Date? = nil, sourceKind: String, sourceId: UUID) {
            self.text = text; self.occurredAt = occurredAt
            self.sourceKind = sourceKind; self.sourceId = sourceId
        }
    }

    /// 器官条目草稿（D 级；确认后写入 `organ_entry`，随实现批 v33）。
    public struct OrganFindingDraft: Sendable, Equatable {
        public var organ: OrganSite
        public var statement: String
        public var occurredAt: Date?
        public var sourceKind: String
        public var sourceId: UUID
        public init(organ: OrganSite, statement: String, occurredAt: Date?,
                    sourceKind: String, sourceId: UUID) {
            self.organ = organ; self.statement = statement; self.occurredAt = occurredAt
            self.sourceKind = sourceKind; self.sourceId = sourceId
        }
    }

    /// 器官命中：按目录顺序、任意关键词命中即归属（同一句可命中多器官——各自成条目）。
    public static func organHits(in text: String) -> [OrganSite] {
        guard !text.isEmpty else { return [] }
        return OrganSite.allCases.filter { organ in
            organ.matchTerms.contains { text.contains($0) }
        }
    }

    /// 逐条陈述 → 草稿：每条命中几个器官就产几份；空陈述/无命中跳过；
    /// 去重键 = 器官 + 来源类型 + 来源行 + 原文（同源重复行不重复建档）。
    public static func drafts(from statements: [FindingStatement]) -> [OrganFindingDraft] {
        var seen = Set<String>()
        var out: [OrganFindingDraft] = []
        for statement in statements {
            let trimmed = statement.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            for organ in organHits(in: trimmed) {
                let key = "\(organ.rawValue)|\(statement.sourceKind)|\(statement.sourceId.uuidString)|\(trimmed)"
                guard seen.insert(key).inserted else { continue }
                out.append(OrganFindingDraft(organ: organ, statement: trimmed,
                                             occurredAt: statement.occurredAt,
                                             sourceKind: statement.sourceKind,
                                             sourceId: statement.sourceId))
            }
        }
        return out
    }
}
