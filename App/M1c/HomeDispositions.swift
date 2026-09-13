import SwiftUI
import Domain

/// FR2.1⑦ 首页按源滑动处置（round2 U-N1/N2/N3）——动作 → 文案/图标/色的**纯呈现**映射。
/// 语义（哪个源有哪些动作、能否全滑、写哪个键）全部在 Domain
/// （`ReminderDisposition` / `ReminderAggregationCenter.dispositions(for:)` / `NotificationItemKey`），
/// 本文件不做任何业务判定；用药三动作复用提醒页既有键（`reminder.taken/snooze15/skip`）。
extension ReminderDisposition {
    var title: String {
        switch self {
        case .markTaken: return L10n.reminder_taken
        case .snoozeDose: return L10n.reminder_snooze15
        case .skipDose: return L10n.reminder_skip
        case .openCabinet: return L10n.homeSwipeOpenCabinet
        case .snoozeUntilTomorrow: return L10n.homeSwipeSnoozeTomorrow
        case .archive: return L10n.homeSwipeArchive
        case .viewEvidence: return L10n.homeSwipeViewEvidence
        case .view: return L10n.homeSwipeView
        case .resumePendingCard: return L10n.pendingCardResume
        }
    }

    var systemImage: String {
        switch self {
        case .markTaken: return "checkmark.circle.fill"
        case .snoozeDose, .snoozeUntilTomorrow: return "clock.arrow.circlepath"
        case .skipDose: return "forward.end"
        case .openCabinet: return "pills"
        case .archive: return "archivebox"
        case .viewEvidence, .view: return "doc.text.magnifyingglass"
        case .resumePendingCard: return "checkmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .markTaken, .resumePendingCard, .openCabinet: return Color("brand-primary", bundle: .main)
        case .snoozeDose, .snoozeUntilTomorrow: return .indigo
        case .skipDose: return .gray
        case .archive: return .orange
        case .viewEvidence: return Color("semantic-danger", bundle: .main)
        case .view: return Color("semantic-warning", bundle: .main)
        }
    }
}

/// 首页底部条载荷：撤销（归档/稍后写成功）或重试（写失败，行保留）。
/// `id` 即动作代次——自动消失计时与撤销回调都以它判「仍是同一条」，
/// 新动作换条后旧计时器/旧撤销不得清掉新条（round2 U3 Undo 竞态）。
struct HomeActionToast: Identifiable {
    enum Kind {
        case undo(key: String)
        case failed(retry: () -> Void)
    }
    let id = UUID()
    let title: String
    let kind: Kind
    /// 失败条给更长停留（用户需读到「操作失败」并决定是否重试）。
    var autoDismissSeconds: Double {
        if case .failed = kind { return 8 }
        return 5
    }
}
