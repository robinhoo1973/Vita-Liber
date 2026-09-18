import SwiftUI

/// BR-003 来源徽章（设计系统 §4.1：每个结构化数据有来源徽章，五态）。
/// A 医院原文 / B 知识库 / C 用户确认 / D 识别未确认 / E AI 解释。
/// D/E 态叠加虚线边框 + 「待确认」角标（§1 原则 3 视觉承诺）；
/// 全仓唯一渲染出口——禁止视图手写 Capsule 徽章变体（V3.72 五态统一）。
struct GradeBadge: View {
    let grade: String

    /// 一次解析（原 fill/shortText/isUnconfirmed/accessibilityText 四次各自
    /// switch 原始字符串，isUnconfirmed 还每帧分配数组字面量——收敛为单次
    /// 解析，行为零变化）。
    private enum Parsed {
        case a, b, c, d, e, unknown
        init(_ raw: String) {
            switch raw {
            case "A": self = .a
            case "B": self = .b
            case "C": self = .c
            case "D": self = .d
            case "E": self = .e
            default: self = .unknown
            }
        }
    }

    private var parsed: Parsed { Parsed(grade) }

    private var fill: Color {
        switch parsed {
        case .a: return Color("grade-a", bundle: .main)
        case .b: return Color("brand-primary", bundle: .main)
        case .c: return Color("grade-c", bundle: .main)
        case .d, .e: return Color("grade-d", bundle: .main)
        // 审查修复（BR-003 来源语义）：未知/空来源此前按 C（用户确认）着色——
        // 无来源数据被冒充为用户确认事实。未知一律按「未确认」视觉呈现。
        case .unknown: return Color("grade-d", bundle: .main)
        }
    }

    private var shortText: String {
        switch parsed {
        case .a: return L10n.gradeBadgeA
        case .b: return L10n.gradeBadgeB
        case .c: return L10n.gradeBadgeC
        case .d: return L10n.gradeBadgeD
        case .e: return L10n.gradeBadgeE
        case .unknown: return grade
        }
    }

    private var isUnconfirmed: Bool {
        switch parsed {
        case .d, .e, .unknown: return true
        case .a, .b, .c: return false
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(grade)
                .font(.caption2).bold()
            Text(shortText)
                .font(.caption2)
            if isUnconfirmed {
                Text(L10n.gradeBadgePending)
                    .font(.caption2)
                    .padding(.horizontal, 3)
                    .background(Capsule().fill(.white.opacity(0.85)))
                    .foregroundStyle(fill)
            }
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Capsule().fill(fill))
        .foregroundStyle(.white)
        .overlay {
            if isUnconfirmed {
                Capsule()
                    .strokeBorder(.white.opacity(0.8),
                                  style: StrokeStyle(lineWidth: 1, dash: [3]))
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    /// 朗读文本（2026-09-15 实测修复）：原实现把 A/B/C 一律朗读为「已确认」——
    /// A 级医院原文、B 级信源库都不是用户确认来的，被读成「已确认」是来源语义
    /// 反演（BR-003 同族）。只有 C 才是用户确认态；A/B 朗读自身字母+短文案，
    /// D/E/未知仍朗读「未确认」。
    private var accessibilityText: String {
        switch parsed {
        case .a, .b, .c: return "\(grade) \(shortText)"
        case .d, .e, .unknown: return L10n.docGradeUnconfirmed
        }
    }
}
