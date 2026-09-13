import Foundation

/// 滑动侧别（Domain 自有，不引 SwiftUI）。
public enum SwipeSide: Sendable, Equatable { case leading, trailing }

/// FR2.1⑦ 首页行处置动作（round2 U-N1/N2/N3 按源动作表）。没有任何 case 删除医疗事实：
/// 归档/稍后只写 notification_state；用药三动作只写 dose_log 用户动作（BR-004）。
public enum ReminderDisposition: String, Sendable, Equatable, CaseIterable, Codable {
    case markTaken, snoozeDose, skipDose       // dose_slot（医疗动作，禁全滑）
    case openCabinet                            // refill / stock_backlog
    case snoozeUntilTomorrow                    // 次日键：refill / stock_backlog / ocr 未逾期 / pending_card
    case archive                                // appointment / refill / stock_backlog
    case viewEvidence, view                     // alert L1+ 证据卡 / 逾期高风险 OCR 队列
    case resumePendingCard                      // pending_card（放弃仅经详情确认流）

    public var side: SwipeSide {
        switch self {
        case .markTaken, .openCabinet, .viewEvidence, .view, .resumePendingCard: return .leading
        case .snoozeDose, .skipDose, .snoozeUntilTomorrow, .archive: return .trailing
        }
    }
    /// 医疗事实动作（BR-004）：不得全滑触发。
    public var isMedicalAction: Bool { self == .markTaken || self == .snoozeDose || self == .skipDose }
}

public extension ReminderAggregationCenter {
    /// 按源动作表（顺序即按钮顺序；trailing 首项 = 全滑候选）。
    static func dispositions(for item: AggregatedReminderItem) -> [ReminderDisposition] {
        switch item.id.kind {
        case "dose_slot": return (item.status ?? "pending") == "pending" ? [.markTaken, .snoozeDose, .skipDose] : []
        case "refill", "stock_backlog": return [.openCabinet, .snoozeUntilTomorrow, .archive]
        case "appointment": return [.archive]
        case "alert_event": return item.isPinned ? [.viewEvidence] : []
        case "ocr": return item.isPinned ? [.view] : [.snoozeUntilTomorrow]
        case "pending_card": return [.resumePendingCard, .snoozeUntilTomorrow]
        default: return []   // profile_progress 与未知源：无滑动动作
        }
    }
    /// 全滑仅对纯信息行的 稍后/归档 开放；leading 一律关闭（导航/医疗动作不应被整行拖动触发）。
    static func allowsFullSwipe(for item: AggregatedReminderItem, side: SwipeSide) -> Bool {
        guard side == .trailing, let first = dispositions(for: item).first(where: { $0.side == .trailing }) else { return false }
        return !first.isMedicalAction && (first == .snoozeUntilTomorrow || first == .archive)
    }
}
