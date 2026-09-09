import Foundation

/// tech §5.33 V3.96 统一提醒聚合中心（data-flow §4.5.1 单一事实源）：
/// 首页/通知中心的提醒聚合投影——可丢弃读取投影，不新增或复制医疗事实。
/// `source_kind+source_id` 去重键、时间窗（过去 7 日/未来 14 日）、
/// L1+/高风险 OCR/SOS 绕过窗口与类别过滤置顶、周期性计划压缩。
/// 本文件是 Domain 纯函数投影层，视图零逻辑（V3.87 契约）。

/// 聚合时间窗（AppSettingsStore 持久化键 actionFeedWindow 冻结不改）。
public struct AggregationWindow: Codable, Sendable, Equatable {
    public var pastDays: Int
    public var futureDays: Int
    public init(pastDays: Int = 7, futureDays: Int = 14) {
        self.pastDays = pastDays
        self.futureDays = futureDays
    }
}

/// 聚合类别（data-flow §4.5.1 聚合源映射；pendingCard 为 FR6.9 增）。
public enum AggregationKind: String, Codable, Sendable, Equatable, CaseIterable {
    case medication      // reminder / medication_dose_log（周期计划压缩投影）
    case appointment
    case document        // document_file 待处理
    case ocr             // 未确认高风险 OCR
    case alert           // alert_event L1+
    case pendingCard     // FR6.9 待办卡（仅非敏感摘要，BR-003）
    case family          // 授权家庭 SOS/事件（AccessGrant 三闸门后）
    case sos
    case system          // 系统状态（注册补全、订阅过期等）
}

/// 聚合投影项（V3.96：原 ActionFeedItem 退役，唯一投影形态）。
public struct AggregatedReminderItem: Identifiable, Sendable, Equatable {
    /// 去重键：source_kind + source_id（同一事实只出现一次）。
    public struct SourceKey: Hashable, Sendable, Equatable, Codable {
        public var kind: String
        public var sourceId: String
        public init(kind: String, sourceId: String) {
            self.kind = kind
            self.sourceId = sourceId
        }
    }

    public var id: SourceKey
    public var aggregationKind: AggregationKind
    public var occurredAt: Date
    /// 提醒时效（如 pending_card.created_at + 24h，data-flow §20.1）
    public var dueDate: Date?
    /// 非敏感摘要标题——pending_card 绝不携带未确认医疗值（BR-003）
    public var title: String
    public var patientID: UUID?
    /// 置顶优先级：SOS=3 / 高风险 OCR=2 / L1+=2 / 普通=0（priority desc 再按时间）
    public var priority: Int
    /// 源实体状态透传（pending_card.status 等，仅呈现）
    public var status: String?
    /// 稳定路由键（App 层映射 AppRoute；Domain 不得引用 App 层枚举）
    public var routeKey: String?
    /// 周期计划所属 planID（V3.87 (planID, window) 压缩键；非周期项为 nil）
    public var planID: String?
    /// 周期计划压缩：非 nil 时本项为「最近逾期 + 下一动作」投影，附剩余数
    public var remainingCount: Int?

    public init(id: SourceKey, aggregationKind: AggregationKind, occurredAt: Date,
                dueDate: Date? = nil, title: String, patientID: UUID? = nil,
                priority: Int = 0, status: String? = nil,
                routeKey: String? = nil, planID: String? = nil,
                remainingCount: Int? = nil) {
        self.id = id
        self.aggregationKind = aggregationKind
        self.occurredAt = occurredAt
        self.dueDate = dueDate
        self.title = title
        self.patientID = patientID
        self.priority = priority
        self.status = status
        self.routeKey = routeKey
        self.planID = planID
        self.remainingCount = remainingCount
    }

    /// 是否强制置顶（§4.5.1：L1+、未确认高风险 OCR、SOS 绕过窗口与过滤）。
    public var isPinned: Bool { priority >= 2 }
}

/// 空态上下文（V3.87：与全局无数据混淆区分）。
public struct AggregationEmptyContext: Sendable, Equatable {
    public var kind: AggregationKind?
    public var window: AggregationWindow
    public init(kind: AggregationKind? = nil, window: AggregationWindow = .init()) {
        self.kind = kind
        self.window = window
    }
}

/// 聚合器（V3.96：吸收 TodayAggregator 职责，唯一聚合投影出口）。
/// 纯函数：输入各源投影项 → 去重/窗口/置顶/压缩/排序 → 输出。
public enum ReminderAggregationCenter {
    /// 压缩键：周期计划按 (planID, window) 压缩为「最近逾期 + 下一动作 +
    /// 剩余数」（V3.87 契约）。返回 nil 表示该项不参与压缩（非周期计划）。
    public static func compressKey(_ item: AggregatedReminderItem) -> String? {
        guard item.aggregationKind == .medication, let planID = item.planID else { return nil }
        return "plan-\(planID)"
    }

    /// 聚合入口（data-flow §4.5.1）：
    /// ① 按 source_kind+source_id 去重（后到者丢弃）；
    /// ② 成员过滤（BR-001；置顶项豁免成员过滤——SOS 等跨成员可达）；
    /// ③ 时间窗过滤（置顶项豁免）；
    /// ④ 周期计划压缩（同 plan 保留最近逾期与下一未来项，附 remainingCount）；
    /// ⑤ 排序：priority desc → 时间 desc。
    public static func aggregate(_ items: [AggregatedReminderItem],
                                 window: AggregationWindow = .init(),
                                 now: Date = Date(),
                                 memberId: UUID) -> [AggregatedReminderItem] {
        var seen = Set<AggregatedReminderItem.SourceKey>()
        var deduped: [AggregatedReminderItem] = []
        for item in items {
            guard seen.insert(item.id).inserted else { continue }
            deduped.append(item)
        }

        let filtered = deduped.filter { item in
            if item.isPinned { return true }              // 置顶绕过窗口/成员
            guard item.patientID == nil || item.patientID == memberId else { return false }
            // 审查修复：固定 86400 秒偏移在 DST 切换日（23/25 小时）窗口
            // 边界漂移 ±1 小时——与全仓日历日纪律（DayArithmetic）统一
            let past = DayArithmetic.offset(days: -window.pastDays, from: now)
            let future = DayArithmetic.offset(days: window.futureDays, from: now)
            guard item.occurredAt >= past, item.occurredAt <= future else { return false }
            return true
        }

        // 周期计划压缩：同压缩键保留最近逾期项与最近未来项各一条
        var planGroups: [String: [AggregatedReminderItem]] = [:]
        var rest: [AggregatedReminderItem] = []
        for item in filtered {
            if let key = compressKey(item) {
                planGroups[key, default: []].append(item)
            } else {
                rest.append(item)
            }
        }
        var out = rest
        for (_, group) in planGroups {
            let overdue = group.filter { $0.occurredAt <= now }.max { $0.occurredAt < $1.occurredAt }
            let upcoming = group.filter { $0.occurredAt > now }.min { $0.occurredAt < $1.occurredAt }
            var remaining = group.count
            if overdue != nil { remaining -= 1 }
            if upcoming != nil { remaining -= 1 }
            if let o = overdue {
                var item = o
                item.remainingCount = remaining
                out.append(item)
            }
            if let u = upcoming, u != overdue {
                var item = u
                item.remainingCount = remaining
                out.append(item)
            }
        }

        return out.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.occurredAt > $1.occurredAt
        }
    }

    /// 类别筛选是纯 View 参数（V3.87 契约：不调用写接口）。
    public static func filtered(_ items: [AggregatedReminderItem], kind: AggregationKind?) -> [AggregatedReminderItem] {
        guard let kind else { return items }
        return items.filter { $0.aggregationKind == kind || $0.isPinned }
    }

    /// 待办卡投影（data-flow §20.1）：title=「待补充：{card_kind}」非敏感摘要、
    /// dueDate=created_at+24h、status=pending_card.status 透传。
    public static func pendingCardItem(cardId: String, cardKind: String,
                                       patientId: UUID, createdAt: Date,
                                       status: String) -> AggregatedReminderItem {
        AggregatedReminderItem(
            id: .init(kind: "pending_card", sourceId: cardId),
            aggregationKind: .pendingCard,
            occurredAt: createdAt,
            dueDate: createdAt.addingTimeInterval(24 * 3600),
            title: "待补充：\(cardKind)",
            patientID: patientId,
            priority: 0,
            status: status,
            routeKey: "pendingCardDetail")
    }
}
