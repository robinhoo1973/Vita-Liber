import Foundation

/// v27（子项目 J · discussions/2026-09-14-card-hierarchy-round1 §D/§E.3）：记录页时间轴「主卡 + 折叠子卡」的纯 Domain 投影。
/// Infrastructure（`TimelineQueryStore.hubs(for:)`）只负责取主卡页与按主卡 id 批取子卡；分组 / 子卡序 / 计数 / 筛选 /
/// 展开集全部在此。旧平铺投影（`TimelineEntry` / `TimelineProjectionRules` / `entries(for:)`）语义不变，本文件只追加。
///
/// 纪律：计数只数传入的子卡（store 已过滤 `confirmed = 1`，D 级不入）；同一子卡可归属多张主卡（检验表头既挂就诊又挂体检）；
/// 子卡日期不参与主卡游标（未来的复诊预约不推走主卡）。

/// 主卡枢纽三类（round1 §D）：门诊/急诊就诊、住院期（encounter + hospitalization）、体检。
public enum RecordHub: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case encounter, hospitalization, healthExam = "health_exam"
}

/// 子卡类（round1 §D 主从关系表）→ 时间轴条目类型 / 已确认卡详情卡类（nil = 专用路由）。
public enum RecordChildKind: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case hospitalization, diagnosis, prescription, labReport, examReport, claim, immunization
    case surgery, treatmentRecord, clinicalConclusion, appointment, reminder, document

    /// 时间轴条目类型（immunization → 既有 .vaccination，其余同名）。
    public var timelineKind: TimelineEntryKind {
        self == .immunization ? .vaccination : TimelineEntryKind(rawValue: rawValue) ?? .document
    }

    /// `AppRoute.medicalCard(kind:)` 卡类字符串（= 事实表名）；预约/提醒/原件走专用路由 → nil。
    public var cardKind: String? {
        switch self {
        case .hospitalization: return "hospitalization"
        case .diagnosis: return "diagnosis"
        case .prescription: return "prescription"
        case .labReport: return "lab_report"
        case .examReport: return "exam_report"
        case .claim: return "claim_item"
        case .immunization: return "immunization"
        case .surgery: return "surgery"
        case .treatmentRecord: return "treatment_record"
        case .clinicalConclusion: return "clinical_conclusion"
        case .appointment, .reminder, .document: return nil
        }
    }
}

/// 主卡页的一行：主卡（hub 非 nil）或无枢纽叶子。
public struct TimelineHubRow: Sendable, Equatable {
    public var entry: TimelineEntry
    /// nil = 无枢纽叶子（观察 / 用药计划 / 速记 / 健康问题 / 过敏 / 自测点 / 历史孤儿子卡）。
    public var hub: RecordHub?
    public init(entry: TimelineEntry, hub: RecordHub?) { self.entry = entry; self.hub = hub }
}

/// 子卡行：`hubId` = 所属主卡 refID（同一子卡可出现在多个 hubId 下 = 多重归属）。
public struct TimelineChildRow: Sendable, Equatable {
    public var hubId: UUID
    public var entry: TimelineEntry
    public init(hubId: UUID, entry: TimelineEntry) { self.hubId = hubId; self.entry = entry }
}

/// 分组后的一条时间轴项：主卡带已排序子卡与按类型计数；叶子 `hub == nil`、无子卡。
public struct TimelineHubEntry: Sendable, Equatable, Identifiable {
    public var hub: RecordHub?
    public var entry: TimelineEntry
    public var children: [TimelineEntry]
    public var counts: [TimelineEntryKind: Int]
    public var isHub: Bool { hub != nil }
    /// 展开记忆键与列表身份：`<hub|leaf>-<kind>-<refID>`。
    public var id: String { (hub?.rawValue ?? "leaf") + "-" + entry.id }
    public init(hub: RecordHub?, entry: TimelineEntry, children: [TimelineEntry], counts: [TimelineEntryKind: Int]) {
        self.hub = hub; self.entry = entry; self.children = children; self.counts = counts
    }
}

/// 主卡分页结果（游标沿主卡/叶子的 date DESC, id DESC——与 `TimelinePage` 同纪律）。
public struct TimelineHubPage: Sendable, Equatable {
    public var entries: [TimelineHubEntry]
    public var nextCursor: TimelineCursor?
    public init(entries: [TimelineHubEntry], nextCursor: TimelineCursor?) { self.entries = entries; self.nextCursor = nextCursor }
}

/// round1 §E.3：分组 / 子卡序 / 筛选 / 展开集——纯函数；计数只数传入的已确认子卡（store 已过滤 confirmed = 1，D 级不入）。
public enum TimelineHierarchyRules {
    /// 子卡类型序（同日期内）：住院期 → 诊断 → 处方 → 检验 → 检查 → 手术 → 治疗 → 费用 → 疫苗 → 结论 → 预约 → 提醒 → 原件。
    public static let childKindOrder: [TimelineEntryKind] = [
        .hospitalization, .diagnosis, .prescription, .labReport, .examReport, .surgery, .treatmentRecord,
        .claim, .vaccination, .clinicalConclusion, .appointment, .reminder, .document,
    ]

    /// 分组：主卡按输入顺序（游标序）保留；子卡按 `hubId` 归入本页主卡（不在本页的主卡 → 子卡丢弃，由其所在页呈现）；
    /// 同一主卡内同一子卡只出现一次（多条来源查询命中同一行）；叶子无子卡、计数空。
    public static func group(rows: [TimelineHubRow], children: [TimelineChildRow]) -> [TimelineHubEntry] {
        var byHub: [UUID: [TimelineEntry]] = [:]
        for child in children { byHub[child.hubId, default: []].append(child.entry) }
        return rows.map { row in
            guard let hub = row.hub else { return TimelineHubEntry(hub: nil, entry: row.entry, children: [], counts: [:]) }
            var seen = Set<String>()
            let kids = (byHub[row.entry.refID] ?? []).filter { seen.insert($0.id).inserted }.sorted(by: childOrder)
            var counts: [TimelineEntryKind: Int] = [:]
            for kid in kids { counts[kid.kind, default: 0] += 1 }
            return TimelineHubEntry(hub: hub, entry: row.entry, children: kids, counts: counts)
        }
    }

    /// 子卡序：日期倒序 → 类型序（`childKindOrder`，未登记类型排末）→ refID 倒序（与 §5.30 游标序同向、稳定）。
    public static func childOrder(_ a: TimelineEntry, _ b: TimelineEntry) -> Bool {
        if a.date != b.date { return a.date > b.date }
        let ra = childKindOrder.firstIndex(of: a.kind) ?? Int.max, rb = childKindOrder.firstIndex(of: b.kind) ?? Int.max
        if ra != rb { return ra < rb }
        return a.refID.uuidString > b.refID.uuidString
    }

    /// 筛选：主卡类型命中 → 整卡保留；否则只留命中子卡（计数同步收窄）、无命中即隐藏；叶子按自身类型。
    public static func visible(_ entries: [TimelineHubEntry], filter: TimelineFilter) -> [TimelineHubEntry] {
        guard case .kinds(let kinds) = filter else { return entries }
        return entries.compactMap { item in
            guard item.isHub else { return kinds.contains(item.entry.kind) ? item : nil }
            if kinds.contains(item.entry.kind) { return item }
            var narrowed = item
            narrowed.children = item.children.filter { kinds.contains($0.kind) }
            narrowed.counts = item.counts.filter { kinds.contains($0.key) }
            return narrowed.children.isEmpty ? nil : narrowed
        }
    }

    /// 展开集：筛选态 = 有命中子卡（或主卡类型自身命中）的主卡全部展开（瞬态，不写记忆）——入参可为 `visible` 收窄前后任一形态；
    /// 无筛选 = 记忆值 ?? （序列中第一张主卡 true、其余 false）。
    /// `remembered(id)`：nil = 无记忆（交给默认），true/false = 用户上次的展开状态（J4 `TimelineExpansionStore`）。
    public static func expanded(_ entries: [TimelineHubEntry], filter: TimelineFilter, remembered: (String) -> Bool?) -> Set<String> {
        if case .kinds(let kinds) = filter {
            return Set(entries.filter { item in
                item.isHub && !item.children.isEmpty && (kinds.contains(item.entry.kind) || item.children.contains { kinds.contains($0.kind) })
            }.map(\.id))
        }
        var result = Set<String>()
        var newestSeen = false
        for item in entries where item.isHub {
            let open = remembered(item.id) ?? !newestSeen
            newestSeen = true
            if open { result.insert(item.id) }
        }
        return result
    }
}
