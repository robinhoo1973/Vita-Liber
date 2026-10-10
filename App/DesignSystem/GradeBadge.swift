import SwiftUI

/// BR-003 来源徽章（设计系统 §4.1：每个结构化数据有来源徽章，五态）。
/// A 医院原文 / B 知识库 / C 用户确认 / D 识别未确认 / E AI 解释。
/// D/E 态叠加虚线边框 + 「待确认」角标（§1 原则 3 视觉承诺）；
/// 全仓唯一渲染出口——禁止视图手写 Capsule 徽章变体（V3.72 五态统一）。
///
/// 第九轮审查 D-1（对比度实测，白字 caption2 小字按 WCAG AA 需 ≥4.5:1，
/// 计算式 (1.05)/(L+0.05)，L 为 sRGB 相对亮度）——五态底色全部达标，
/// 数值以 colorset 现行值为准（改色必须同步复算）：
/// - A `grade-a` #0A66C2：5.69（universal）
/// - B `grade-b` #5F6368（亮）/ #6E747A（暗）：6.05 / 4.73
///   （原 B 复染 `brand-primary`——暗色变体 #4A9DE8 白字仅 2.88:1，
///   本次解耦为独立 grade-b token，brand 留给链接/主行动不进徽章）
/// - C `grade-c` #188038：5.02（原 #34A853 仅 3.06）
/// - D/E/未知 `grade-d` #9A6400：5.00（原 #E8A13A 仅 2.19；
///   「待确认」角标 = 白底 85% 上以 fill 着色小字，随底色加深同步达标）
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
        // D-1：独立 token（见顶部对比度表；原用 brand-primary 暗色变体不达标）
        case .b: return Color("grade-b", bundle: .main)
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

/// 中央 grade 字面量（2026-10-03 评审 R1-12）：C=用户已确认事实 / D=机器识别未确认——
/// 硬编码散落 19 处渲染调用点，语义靠字符串巧合；收敛为单一常量（详情页恒出
/// C/D 的「并置可比口径」与时间轴「C 默认事实态不出徽章」的例外语义随常量自明）。
extension GradeBadge {
    static let gradeConfirmed = "C"
    static let gradeMachineUnconfirmed = "D"
}
