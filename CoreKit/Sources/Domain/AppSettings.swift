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
    case observationDefaultKind    // 观察默认类型（SP-14 步骤1 记忆上次选择，FR8.1）
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
    case appearance                // 外观主题（FR14.4）：light/dark/system
    case highContrastEnabled       // 高对比度增强（FR14.4/FR18.16）
    case language                  // 显示语言（FR14.5）：zh-Hans/zh-Hant，即时生效
    case voiceInputLanguages       // 语音输入语言集（FR17.15）：逗号分隔 locale 列表
    case notificationPreviewMedName // 锁屏通知预览是否显示药名（FR14.7，默认关）
    // FR14.1 分目的授权九开关（撤回即时生效 BR-010；关闭只停后续处理不删数据）
    case authOcr                  // OCR 与图像处理
    case authAI                   // AI 分析
    case authFamilyAccess         // 家庭成员访问
    case authSharing              // 分享
    case authCloudBackup          // 云备份
    case authAnonymizedImprovement // 匿名化改进
    case authHealthRead           // 读取 Apple 健康（F16）
    case authVoiceDictation       // 语音速记识别
    // FR9.18 分通道偏好（§5.58，V3.72）：每类提醒三选一（local 仅通知/
    // persistentRing 通知+响铃直到确认/inApp 静音仅横幅）；remindChannel 为全局缺省
    case remindChannelMeds
    case remindChannelApts
    case remindChannelExam
    case remindChannelExpiry
    case remindChannelAlert
    case remindChannelBackup
    case inAppBannerEnabled        // 应用内横幅总开关（默认开）
    case voiceMixedInput           // FR17.15 混说开关（默认开）
    case gateGraceSeconds          // FR1.4 退后台自动锁定宽限（秒：0/15/60）

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
        case .observationDefaultKind: return "skin"
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
        case .appearance: return "system"
        case .highContrastEnabled: return "false"
        case .language: return "zh-Hans"
        case .voiceInputLanguages: return "zh-Hans-CN"
        case .notificationPreviewMedName: return "false"
        case .authOcr, .authAI, .authFamilyAccess, .authSharing,
             .authCloudBackup, .authAnonymizedImprovement,
             .authHealthRead, .authVoiceDictation:
            return "true"
        case .remindChannelMeds, .remindChannelApts, .remindChannelExam,
             .remindChannelExpiry, .remindChannelAlert, .remindChannelBackup:
            return "local"
        case .inAppBannerEnabled: return "true"
        case .voiceMixedInput: return "true"
        case .gateGraceSeconds: return "0"
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
    /// FR7.8 每种指标上次录入单位的记忆键（UserDefaults 直存；键构造单一
    /// 事实源——第八轮全仓审查修复：此前键在视图层内联拼装，与 app_settings
    /// 诊断/恢复通道完全脱钩；键构造收敛此处，后续迁入 AppSettingsStore
    /// 家庭键（restoreDefaults 可重置）时只改本函数）。
    public static func rememberedUnitKey(for metricRawValue: String) -> String {
        "metric.unit.\(metricRawValue)"
    }

    /// FR7.5 上次选择指标的记忆键（与 rememberedUnitKey 同族——键构造单一
    /// 事实源，此前视图层内联 "metric.lastSelected" 字面量，AppSettingsStore
    /// 诊断/恢复通道看不到该键）。
    public static var lastSelectedMetricKey: String { "metric.lastSelected" }

    /// FR14.7/FR17.15 语音输入首选 locale：单一选择 = 该语言；多选 = 取第一个
    /// （引擎内再按能力回落）。解析规则与设置页存储格式同源（逗号分隔）。
    public static func preferredVoiceLocale(_ stored: String?) -> String? {
        (stored ?? AppSettingKey.voiceInputLanguages.defaultValue)
            .split(separator: ",").first.map(String.init)
    }
    /// 未设置 → 默认值（读路径语义；存储层只存非默认覆盖）
    public static func resolved(_ stored: String?, key: AppSettingKey) -> String {
        stored ?? key.defaultValue
    }

    /// 日期格式 tag ↔ 存储值（FR14.7/§5.19）：tag 供 UI 选择器（无本地化格式串
    /// 进入视图层），值存 app_settings；单一映射维护（V3.72）
    public static func dateFormatTag(of value: String) -> String {
        switch value {
        case "yyyy年M月d日": return "ymd"
        case "M月d日": return "md"
        default: return "iso"
        }
    }

    public static func dateFormatValue(of tag: String) -> String {
        switch tag {
        case "ymd": return "yyyy年M月d日"
        case "md": return "M月d日"
        default: return "yyyy-MM-dd"
        }
    }

    /// 追溯语义（FR14.7）：默认类设置只影响新建项——修改默认值不回溯既有数据
    public static func appliesToExisting(_ key: AppSettingKey) -> Bool {
        switch key {
        case .defaultMemberId, .defaultDocKind, .observationDefaultKind, .remindAdvanceMinutes,
             .snoozeMinutes, .missGraceMinutes, .dateFormat, .weekStartsOn,
             .unitSystem, .homeSort:
            return false   // 仅影响新建
        default:
            return true
        }
    }
}
