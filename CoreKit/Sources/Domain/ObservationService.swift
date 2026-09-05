import Foundation

/// FR8.1 八类观察类型的规范枚举（单一事实源，评审修正：模型直接持类型，
/// rawValue 只存在于 SQL 边界——既有行兼容不变）。显示名映射在 L10n
/// （`L10n.observationKindName`），图标映射在 App 层 VLIcon（Domain 不持 Image）。
public enum ObservationKind: String, CaseIterable, Sendable, Codable {
    case stool, urine, skin, eye, secretion, swelling, generic, custom
}

/// F8 观察事件聚合（§5.36）：按 group_id 聚合观察记录；就诊展示模式
/// （DoctorShowcaseSession）会话式解锁 + 超时自动重锁 + scope 过滤（BR-007/008）。
public struct ObservationGroup: Sendable, Equatable, Identifiable {
    public var groupId: UUID
    public var kind: ObservationKind
    public var occurrences: [ObservationEvent]
    public var id: UUID { groupId }
    public init(groupId: UUID, kind: ObservationKind, occurrences: [ObservationEvent]) {
        self.groupId = groupId; self.kind = kind; self.occurrences = occurrences
    }
    public var latest: ObservationEvent? { occurrences.max { $0.occurredAt < $1.occurredAt } }
    public var selfMark: String? { occurrences.compactMap(\.selfMark).last }
}

public struct ObservationEvent: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var groupId: UUID?             // 观察事件聚合（§5.36 group_id）
    public var kind: ObservationKind
    public var occurredAt: Date
    public var capturedAt: Date?          // 拍摄时间（FR8.2）
    public var description: String?
    public var selfMark: String?          // improved/unchanged/worsened
    public var memberId: UUID
    /// F8.4/§5.10 敏感媒体资产 id 列表（asset 表 + 敏感目录，BR-007/008）。
    /// 列表/时间轴只可渲染模糊缩略图，原图必须经敏感容器解锁。
    public var mediaAssetIds: [String]
    /// FR8.2 扩展字段（V3.65 全量投影）：详情页为唯一完整呈现面，
    /// 备份往返必须携带（FR13.5 V3.28 补强，缺失即数据丢失）。
    public var bodyPart: String?
    public var durationMin: Int?
    public var frequency: String?
    public var isFirst: Bool?
    public var trigger: String?
    public var accompanying: String?
    public var painScore: Int?
    public var medsDiet: String?
    public var consultedDoctor: Bool
    public var encounterId: UUID?
    public var healthProblemId: UUID?
    public init(id: UUID, groupId: UUID? = nil, kind: ObservationKind, occurredAt: Date,
                capturedAt: Date? = nil, description: String?, selfMark: String?,
                memberId: UUID, mediaAssetIds: [String] = [],
                bodyPart: String? = nil, durationMin: Int? = nil, frequency: String? = nil,
                isFirst: Bool? = nil, trigger: String? = nil, accompanying: String? = nil,
                painScore: Int? = nil, medsDiet: String? = nil, consultedDoctor: Bool = false,
                encounterId: UUID? = nil, healthProblemId: UUID? = nil) {
        self.id = id; self.groupId = groupId; self.kind = kind; self.occurredAt = occurredAt
        self.capturedAt = capturedAt; self.description = description; self.selfMark = selfMark
        self.memberId = memberId; self.mediaAssetIds = mediaAssetIds
        self.bodyPart = bodyPart; self.durationMin = durationMin; self.frequency = frequency
        self.isFirst = isFirst; self.trigger = trigger; self.accompanying = accompanying
        self.painScore = painScore; self.medsDiet = medsDiet; self.consultedDoctor = consultedDoctor
        self.encounterId = encounterId; self.healthProblemId = healthProblemId
    }
}

public enum ObservationGroupService {
    /// 聚合：同 group_id 归组（无 group_id 的独立事件各成一组）；
    /// 组内按时间升序；成员隔离（BR-001）
    public static func groups(_ events: [ObservationEvent], member: UUID) -> [ObservationGroup] {
        let scoped = events.filter { $0.memberId == member }
        var byGroup: [UUID: [ObservationEvent]] = [:]
        var order: [UUID] = []
        for e in scoped {
            let key = e.groupId ?? e.id
            if byGroup[key] == nil { order.append(key) }
            byGroup[key, default: []].append(e)
        }
        return order.map { key in
            let occurrences = (byGroup[key] ?? []).sorted { $0.occurredAt < $1.occurredAt }
            let kind = occurrences.first?.kind ?? .custom
            return ObservationGroup(groupId: key, kind: kind, occurrences: occurrences)
        }
    }
}

/// 就诊展示模式（§5.36 DoctorShowcaseSession）：会话式解锁、超时自动重锁、
/// scope 过滤（只展示当前就诊相关观察）。敏感内容默认不展示（BR-007/008）。
public struct DoctorShowcaseSession: Sendable, Equatable {
    public var patientId: UUID
    public var unlockedAt: Date
    public var timeoutSeconds: TimeInterval
    public var scopeKind: ObservationKind?   // 限定展示的观察类别

    public init(patientId: UUID, unlockedAt: Date, timeoutSeconds: TimeInterval = 300, scopeKind: ObservationKind? = nil) {
        self.patientId = patientId
        self.unlockedAt = unlockedAt
        self.timeoutSeconds = timeoutSeconds
        self.scopeKind = scopeKind
    }

    /// 超时自动重锁：会话过期即返回 nil（下次进入重新解锁）
    public func isActive(at now: Date) -> Bool {
        now.timeIntervalSince(unlockedAt) <= timeoutSeconds
    }

    /// scope 过滤：只展示会话范围内的观察；无 scope 时全部
    public func includes(_ event: ObservationEvent) -> Bool {
        event.memberId == patientId && (scopeKind == nil || event.kind == scopeKind)
    }
}

/// 会话内可见事件（超时即空——展示模式水印 + 自动重锁的 Domain 语义）
public enum DoctorShowcaseRules {
    public static func visibleEvents(_ events: [ObservationEvent], session: DoctorShowcaseSession, now: Date) -> [ObservationEvent] {
        guard session.isActive(at: now) else { return [] }   // 超时自动重锁
        return events.filter(session.includes)
    }
}
