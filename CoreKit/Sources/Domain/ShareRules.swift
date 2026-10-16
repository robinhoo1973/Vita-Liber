import Foundation

/// 分级分享包四级（FR13.13 / function V4.22；discussions/2026-10-16-backup-sync-share-design.md §5.5）：
/// 通知级（默认，成员+时段+确认态，不含药名/剂量/病名——FR24.4 同源）→ 摘要级（指标区间、
/// 用药时段；药名三档逐项勾选）→ 卡片级（选定信息卡整体）→ 原件级（逐件显式勾选+水印 BR-009）。
public enum ShareTier: String, Sendable, Codable, Equatable, CaseIterable {
    case notification
    case summary
    case card
    case original

    /// 敏感度升序（阶梯选择器顺序）
    public var sensitivityRank: Int {
        switch self {
        case .notification: return 0
        case .summary: return 1
        case .card: return 2
        case .original: return 3
        }
    }
}

/// 摘要级药名三档（V4.20 裁决：逐项勾选替代级别硬编码；病名恒不在本级——进卡片级）
public enum MedicationNameLevel: String, Sendable, Codable, Equatable, CaseIterable {
    case timeAndStatusOnly     // 默认：仅时段+确认态
    case withNames             // 含药名
    case withNamesAndDosage    // 含药名+剂量
}

/// 分享选择（发起方逐项勾选；最小必要原则）
public struct ShareSelection: Sendable, Equatable, Codable {
    public var tier: ShareTier
    public var medicationNameLevel: MedicationNameLevel
    public var expiry: Date
    /// 卡片级：选定的卡 id；原件级：逐件勾选的文档 id（水印+二次确认 BR-009 由 UI 层强制）
    public var selectedCardIds: Set<UUID>
    public var selectedDocumentIds: Set<UUID>
    public init(tier: ShareTier = .notification,
                medicationNameLevel: MedicationNameLevel = .timeAndStatusOnly,
                expiry: Date = Date().addingTimeInterval(90 * 24 * 3600),
                selectedCardIds: Set<UUID> = [],
                selectedDocumentIds: Set<UUID> = []) {
        self.tier = tier
        self.medicationNameLevel = medicationNameLevel
        self.expiry = expiry
        self.selectedCardIds = selectedCardIds
        self.selectedDocumentIds = selectedDocumentIds
    }
}

/// 分享有效期规则（function V4.22：通知/摘要级默认 90 天、上限 365；卡片/原件级默认 7 天、上限 90；
/// 到期前 24h 提醒分享方；接收端打开过期包明示「已过期」）
public enum ShareExpiryRules {
    public static func defaultExpiry(tier: ShareTier, now: Date = Date()) -> Date {
        switch tier {
        case .notification, .summary: return now.addingTimeInterval(90 * 24 * 3600)
        case .card, .original: return now.addingTimeInterval(7 * 24 * 3600)
        }
    }

    /// 档位上限 = **当下 + 上限天数**（design §5.5 裁决 C2：上限是「自发起起的天数」，
    /// 不是绝对日期）。评审修复：原实现以 1970 纪元起算（1971-01-01/1970-04-01），
    /// clamped 后一切分享有效期塌到 1970/1971 年——isExpired 恒真，分享包发出即过期。
    public static func maxExpiry(tier: ShareTier, now: Date = Date()) -> Date {
        switch tier {
        case .notification, .summary: return now.addingTimeInterval(365 * 24 * 3600)
        case .card, .original: return now.addingTimeInterval(90 * 24 * 3600)
        }
    }

    /// 越界钳制到档位上限（发起方 UI 的 DatePicker 域）
    public static func clamped(_ expiry: Date, tier: ShareTier, now: Date = Date()) -> Date {
        min(max(expiry, now), maxExpiry(tier: tier, now: now))
    }

    public static func isExpired(_ expiry: Date, now: Date = Date()) -> Bool {
        now >= expiry
    }
}

/// 分享纪律规则（BR-003/007/008/009 在分享包的显式条款，function V4.22）：
/// D 级草稿/未确认字段不参与分享（BR-003）；敏感媒体默认排除、原件级逐件勾选+水印（BR-007/008/009）；
/// HealthKit 来源数据恒不在信封（5.1.3(ii)，导出链既有白名单排除）。本枚举为 Domain 层判定面，
/// 裁剪执行在 Infrastructure ShareEnvelopeBuilder（Envelope 平台守卫层）。
public enum ShareRules {

    /// 通知级是否允许携带字段（FR24.4 口径：仅成员+时段+确认态）
    public static func notificationAllowsTitle(_ title: String?) -> Bool { false }
    public static func notificationAllowsMedicationNames(_ level: MedicationNameLevel) -> Bool { false }

    /// 药名三档按级放行（摘要级专用）
    public static func summaryAllowsMedicationNames(_ level: MedicationNameLevel) -> Bool {
        level != .timeAndStatusOnly
    }
    public static func summaryAllowsDosage(_ level: MedicationNameLevel) -> Bool {
        level == .withNamesAndDosage
    }

    /// D 级（机器识别未确认）文档绝不参与分享——BR-003 显式条款
    public static func excludesUnconfirmed(grade: String) -> Bool {
        grade == "D"
    }
}
