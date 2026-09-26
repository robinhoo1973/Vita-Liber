import SwiftUI
import Perception

// MARK: - FR3.3 归属强制确认条（拍摄/导入保存前整屏醒目二次确认）

/// 保存前归属确认条：头像 + 姓名大字 + [更换]——多成员场景下 BR-001
/// 的唯一显式确认点（不得静默用 currentPatientId 保存）。
struct MemberConfirmBar: View {
    let patientName: String
    let relation: String
    let onSwitch: () -> Void

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color("brand-primary", bundle: .main).opacity(0.15))
                    .frame(width: 44, height: 44)
                    .overlay(Text(String(patientName.prefix(1))).font(.headline)
                        .foregroundStyle(Color("brand-primary", bundle: .main)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.memberConfirmBelongsTo)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(patientName)
                        .font(.title3.bold())
                    Text(L10n.memberRelationDisplayName(relation))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.memberConfirmSwitch) { onSwitch() }
                    .font(.subheadline)
                    .frame(minHeight: 44)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14)
                .fill(Color("brand-primary", bundle: .main).opacity(0.06)))
            .accessibilityIdentifier("FR3.3.memberConfirmBar")
        }
    }
}
