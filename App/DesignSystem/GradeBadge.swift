import SwiftUI

/// BR-003 来源徽章（设计系统：每个结构化数据有来源徽章）。
/// C = 用户确认（grade-c 语义色）；D = 机器识别未确认（grade-d，
/// 不进入检索/AI 事实链）。全仓唯一渲染出口——时间轴行与资料库行
/// 共用本组件，避免各视图手写 Capsule 徽章产生分歧变体。
struct GradeBadge: View {
    let grade: String

    var body: some View {
        Text(grade)
            .font(.caption2).bold()
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(
                grade == "D" ? Color("grade-d", bundle: .main)
                             : Color("grade-c", bundle: .main)))
            .foregroundStyle(.white)
            .accessibilityLabel(grade == "D" ? L10n.docGradeUnconfirmed : L10n.timelineGradeConfirmed)
    }
}
