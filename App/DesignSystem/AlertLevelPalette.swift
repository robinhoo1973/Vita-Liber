import SwiftUI
import Domain

/// 警报级别色板单源（第九轮审查 D-4，ui-ux §3.1/§4.12）。
///
/// 收敛三处实现漂移：历史页 SeverityTag 曾 L1=brand-primary、L2 复用
/// `grade-d`（OCR 未确认橙——来源色编码警报级别的跨语义复用）；Home 紧凑行
/// 曾对全部 L1+ 一律 `semantic-danger` 满红（级别表达被抹平）；§4.12 要求的
/// 证据卡左缘级别色条此前完全没有渲染。全部改走本类型。
///
/// token 值按白字 ≥4.5:1（WCAG AA 小字）选定，实测（计算式 1.05/(L+0.05)）：
/// - L1 `alert-l1` #8F5C00 / 暗 #9E6600：5.68 / 4.81
/// - L2 `alert-l2` #C25400：4.60（原 spec 值 #E8730C 白字仅 3.05，按 D-1
///   同口径加深——单一 token 供徽章白字与色条共用）
/// - L3 `alert-l3` #D93025：4.77（原用 semantic-danger 暗色变体 #E86A5C
///   白字仅 3.16）
/// - L0 `text-tertiary`：软提示观记录级，非警报（保持既有中性呈现）
enum AlertLevelPalette {
    static func color(for severity: AlertSeverity) -> Color {
        switch severity {
        case .L0: return Color("text-tertiary", bundle: .main)
        case .L1: return Color("alert-l1", bundle: .main)
        case .L2: return Color("alert-l2", bundle: .main)
        case .L3: return Color("alert-l3", bundle: .main)
        }
    }

    /// 聚合项 status 透传的原始级别串（"L0".."L3"）→ 色。
    /// 未知值按 L2 保守呈现（调用方仅在 kind == "alert_event" 且非 L0 时渲染）。
    static func color(forRawLevel raw: String) -> Color {
        switch raw {
        case "L0": return color(for: .L0)
        case "L1": return color(for: .L1)
        case "L3": return color(for: .L3)
        default: return color(for: .L2)
        }
    }
}
