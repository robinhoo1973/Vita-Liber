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
    /// FR20.3 L1 三卡种类：产品定位与非目标 / 数据本地存储承诺 / 可跳过项说明。
    /// 机器识别确认免责不属于 L1（评审修正：原实现混入，移入 OCR 页 L3 微文案）。
    public enum Kind: String, Sendable, Codable { case boundary, storage, skipInfo }
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
    /// M1a 首启三卡（对齐 FR20.3 L1：产品定位与非目标 / 数据本地存储承诺 / 可跳过项说明）
    public static let l1Cards: [DisclosureCard] = [
        .init(kind: .boundary, key: "disclosure.l1.boundary", version: "1.1",
              body: "本 App 是个人医疗资料的归档与提醒工具，不是医疗设备：不下诊断、不给治疗方案建议、不替代医生。紧急情况请直接拨打 120 或前往医院。"),
        .init(kind: .storage, key: "disclosure.l1.storage", version: "1.1",
              body: "你的资料只保存在本机、功能完全离线。所有上传、分析、分享、备份都是独立开关，关掉即停。更换设备前请用导出功能备份（资料不会自动上传云端）。"),
        .init(kind: .skipInfo, key: "disclosure.l1.skipInfo", version: "1.1",
              body: "建档信息可以稍后补充；添加家人、云账户注册都是可选项，全部可以之后在设置里完成，不影响你正常使用归档与提醒功能。"),
    ]
}
