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

/// FR20.3 L2-L4 场景须知条目
public struct SceneDisclosure: Sendable, Equatable, Codable {
    public let key: String
    public let scene: String
    public let level: Int         // L2=2, L3=3, L4=4
    public let title: String
    public let body: String
    public let version: String
}

public struct ConsentRecord: Sendable, Equatable, Codable {
    public let id: UUID
    public let key: String
    public let level: Int         // L1-L4
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

    /// FR20.3 L2 场景首用须知（一次性确认）
    public static let l2Disclosures: [SceneDisclosure] = [
        .init(key: "disclosure.l2.ai", scene: "ai_assistant", level: 2,
              title: "AI 助手使用须知",
              body: "AI 助手基于本地检索提供参考信息，不是医疗建议。所有回答仅供参考，不构成诊断或治疗方案。如有疑问请咨询医生。",
              version: "1.0"),
        .init(key: "disclosure.l2.trends", scene: "trends", level: 2,
              title: "趋势图表使用须知",
              body: "趋势图表基于你记录的数据生成，仅供参考。数值变化可能受多种因素影响，不构成医疗判断依据。",
              version: "1.0"),
        .init(key: "disclosure.l2.observation", scene: "observation", level: 2,
              title: "观察记录须知",
              body: "观察记录用于辅助你与医生沟通，不是诊断依据。AI 分析结果仅供参考，请以医生诊断为准。",
              version: "1.0"),
        .init(key: "disclosure.l2.voice", scene: "voice_session", level: 2,
              title: "语音会话须知",
              body: "语音识别在本机完成，音频不会上传或存储。识别结果仅供参考，请确认后保存。",
              version: "1.0"),
        .init(key: "disclosure.l2.showcase", scene: "doctor_showcase", level: 2,
              title: "就诊展示模式须知",
              body: "展示模式下显示的资料仅供就诊时参考，医生应结合检查结果综合判断。退出展示模式后自动锁定。",
              version: "1.0"),
    ]

    /// FR20.3 L3 常驻微文案（持续暴露）
    public static let l3Disclosures: [SceneDisclosure] = [
        .init(key: "disclosure.l3.ai_banner", scene: "ai_input", level: 3,
              title: "", body: "AI 回答仅供参考，不构成医疗建议",
              version: "1.0"),
        .init(key: "disclosure.l3.trends_footer", scene: "trends_footer", level: 3,
              title: "", body: "数据变化可能受多种因素影响，请以医生诊断为准",
              version: "1.0"),
        .init(key: "disclosure.l3.evidence_card", scene: "evidence_card", level: 3,
              title: "", body: "引用来源仅供参考，不代表医疗建议",
              version: "1.0"),
        .init(key: "disclosure.l3.showcase_watermark", scene: "showcase_watermark", level: 3,
              title: "", body: "仅供参考·请以医生诊断为准",
              version: "1.0"),
    ]

    /// FR20.3 L4 操作前确认
    public static let l4Disclosures: [SceneDisclosure] = [
        .init(key: "disclosure.l4.export", scene: "export", level: 4,
              title: "导出数据提醒",
              body: "导出的文件包含你的医疗资料，请妥善保管。分享前请确认接收人身份，避免敏感信息泄露。",
              version: "1.0"),
        .init(key: "disclosure.l4.sensitive_share", scene: "sensitive_share", level: 4,
              title: "敏感分享确认",
              body: "即将分享的内容包含敏感医疗信息。请确认你信任接收方，并了解分享后无法撤回。",
              version: "1.0"),
        .init(key: "disclosure.l4.help_card_send", scene: "help_card_send", level: 4,
              title: "求助卡发送确认",
              body: "求助卡将发送给指定接收人，包含你的用药信息。发送后接收人可查看，但不会自动同步更新。",
              version: "1.0"),
    ]

    /// 检查某个场景是否已确认（L2/L4 一次性确认）
    public static func isConfirmed(scene: String, consents: [ConsentRecord]) -> Bool {
        consents.contains { $0.key.contains(scene) }
    }
}
