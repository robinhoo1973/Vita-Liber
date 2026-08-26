import Foundation

/// ADR-015 / FR21.1：本机数据所有者（LocalOwner）——P0 离线内核的根身份。
/// 与 UserAccount（服务端登录主体，P1/D1）严格分离；本人 PatientProfile 随建。
public struct LocalOwner: Sendable, Equatable, Codable {
    public let id: UUID
    public var displayName: String
    public var selfPatientId: UUID?
    public var createdAt: TimeInterval
    public init(id: UUID = UUID(), displayName: String, selfPatientId: UUID? = nil,
                createdAt: TimeInterval = 0) {
        self.id = id
        self.displayName = displayName
        self.selfPatientId = selfPatientId
        self.createdAt = createdAt
    }
}

/// FR21.9 六步注册向导的 M1a 切片：L1 首启三卡 → LocalOwner → 本人档案。
/// 进度持久化断点续填（onboarding_progress 表语义）。
public struct OnboardingProgress: Sendable, Equatable, Codable {
    public enum Step: String, Sendable, Codable, CaseIterable {
        case disclosureL1, localOwner, selfProfile
    }
    public var completed: Set<Step>
    public var current: Step
    public var finished: Bool
    public init(completed: Set<Step> = [], current: Step = .disclosureL1, finished: Bool = false) {
        self.completed = completed
        self.current = current
        self.finished = finished
    }
    public mutating func complete(_ step: Step) {
        completed.insert(step)
        finished = completed.isSuperset(of: Set(Step.allCases))
    }
}

/// F20 / ADR-014：L1 首启三卡（产品边界说明）与同意落库（ConsentRecord 语义）。
public struct DisclosureCard: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case boundary, scope, disclaimer }
    public let kind: Kind
    public let key: String        // DisclosureRegistry 文案 key
    public let version: String
    public let body: String       // M1a 中文直填；M1c 迁移 L10n 三文件
}

public struct ConsentRecord: Sendable, Equatable, Codable {
    public let id: UUID
    public let key: String
    public let level: Int         // L1
    public let version: String
    public let acceptedAt: TimeInterval
    public init(id: UUID = UUID(), key: String, level: Int = 1, version: String, acceptedAt: TimeInterval) {
        self.id = id
        self.key = key
        self.level = level
        self.version = version
        self.acceptedAt = acceptedAt
    }
}

public enum DisclosureRegistry {
    /// M1a 首启三卡（正文来自 function-spec FR20.3 三卡语义的精简版，M1c 接正式文案与 L10n）
    public static let l1Cards: [DisclosureCard] = [
        .init(kind: .boundary, key: "disclosure.l1.boundary", version: "1.0",
              body: "本 App 是个人医疗资料的归档与提醒工具，不是医疗设备：不下诊断、不给治疗方案建议、不替代医生。紧急情况请直接拨打 120 或前往医院。"),
        .init(kind: .scope, key: "disclosure.l1.scope", version: "1.0",
              body: "你的资料只保存在本机、完全离线。所有上传、分析、分享、备份都是独立开关，关掉即停。"),
        .init(kind: .disclaimer, key: "disclosure.l1.disclaimer", version: "1.0",
              body: "机器识别的药名、剂量、日期都会先请你确认才生效；未确认的内容不会进入正式档案。"),
    ]
}
