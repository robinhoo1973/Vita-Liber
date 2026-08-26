import Foundation

/// F14 偏好设置（§5.28）：AppSettingKey 键枚举 = 单一事实源；
/// 每个键必须声明 defaultValue，新增键必须登记（评审 round17 覆盖审计）。
/// 默认类设置仅影响新建项（FR14.7 追溯语义：不改写既有数据）。
public enum AppSettingKey: String, Sendable, CaseIterable, Codable {
    case careModeEnable            // 关怀模式
    case remindChannel             // 提醒通道偏好（FR9.18）
    case readBackOptIn             // 无耳机回读偏好：never/ask/alwaysInCareMode
    case gateGraceMinutes          // 门禁宽限（分钟）
    case voiceEntryVisible         // 语音入口可见性
    case dataRetentionDays         // 数据保留天数
    case privacyShowGuide          // 隐私引导已读
    case defaultMemberId           // 默认家庭成员
    case defaultDocKind            // 默认资料类型
    case remindAdvanceMinutes      // 提醒提前量
    case snoozeMinutes             // 稍后时长
    case missGraceMinutes          // miss 宽限
    case quietHoursStart           // 安静时段开始（"HH:mm"）
    case quietHoursEnd             // 安静时段结束
    case dateFormat                // 日期格式
    case weekStartsOn              // 周起始日
    case unitSystem                // 单位制
    case reduceMotion              // 减弱动效
    case homeSort                  // 首页排序偏好

    /// 键默认值（单一事实源：新增键必须补 default，禁止 UserDefaults 直读兜底）
    public var defaultValue: String {
        switch self {
        case .careModeEnable: return "false"
        case .remindChannel: return "local"
        case .readBackOptIn: return "ask"
        case .gateGraceMinutes: return "1"
        case .voiceEntryVisible: return "true"
        case .dataRetentionDays: return "0"          // 0=永久
        case .privacyShowGuide: return "false"
        case .defaultMemberId: return ""
        case .defaultDocKind: return "record"
        case .remindAdvanceMinutes: return "10"
        case .snoozeMinutes: return "15"
        case .missGraceMinutes: return "60"
        case .quietHoursStart: return "22:00"
        case .quietHoursEnd: return "07:00"
        case .dateFormat: return "yyyy年M月d日"
        case .weekStartsOn: return "1"               // 周一
        case .unitSystem: return "metric"
        case .reduceMotion: return "false"
        case .homeSort: return "time"
        }
    }
}

/// 设置读写端口（生产实现 AppSettingsStore：GRDB app_settings 表 + 审计；
/// 测试注入内存实现）
public protocol SettingsStoring: Sendable {
    func value(for key: AppSettingKey) async throws -> String
    func set(_ value: String, for key: AppSettingKey) async throws
    func restoreDefaults() async throws
}

/// 设置语义规则（Domain 纯函数）
public enum SettingsRules {
    /// 未设置 → 默认值（读路径语义；存储层只存非默认覆盖）
    public static func resolved(_ stored: String?, key: AppSettingKey) -> String {
        stored ?? key.defaultValue
    }

    /// 追溯语义（FR14.7）：默认类设置只影响新建项——修改默认值不回溯既有数据
    public static func appliesToExisting(_ key: AppSettingKey) -> Bool {
        switch key {
        case .defaultMemberId, .defaultDocKind, .remindAdvanceMinutes,
             .snoozeMinutes, .missGraceMinutes, .dateFormat, .weekStartsOn,
             .unitSystem, .homeSort:
            return false   // 仅影响新建
        default:
            return true
        }
    }
}
