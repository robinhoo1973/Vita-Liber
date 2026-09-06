import SwiftUI

/// BR-003 来源徽章（设计系统 §4.1：每个结构化数据有来源徽章，五态）。
/// A 医院原文 / B 知识库 / C 用户确认 / D 识别未确认 / E AI 解释。
/// D/E 态叠加虚线边框 + 「待确认」角标（§1 原则 3 视觉承诺）；
/// 全仓唯一渲染出口——禁止视图手写 Capsule 徽章变体（V3.72 五态统一）。
struct GradeBadge: View {
    let grade: String

    private var fill: Color {
        switch grade {
        case "A": return Color("grade-a", bundle: .main)
        case "B": return Color("brand-primary", bundle: .main)
        case "C": return Color("grade-c", bundle: .main)
        case "D": return Color("grade-d", bundle: .main)
        case "E": return Color("grade-e", bundle: .main)
        default: return Color("grade-c", bundle: .main)
        }
    }

    private var shortText: String {
        switch grade {
        case "A": return L10n.gradeBadgeA
        case "B": return L10n.gradeBadgeB
        case "C": return L10n.gradeBadgeC
        case "D": return L10n.gradeBadgeD
        case "E": return L10n.gradeBadgeE
        default: return grade
        }
    }

    private var isUnconfirmed: Bool { grade == "D" || grade == "E" }

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
        .accessibilityLabel(isUnconfirmed ? L10n.docGradeUnconfirmed : L10n.timelineGradeConfirmed)
    }
}
