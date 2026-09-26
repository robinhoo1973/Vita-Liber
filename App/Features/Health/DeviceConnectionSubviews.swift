import SwiftUI
import Domain
import Protocols
import Perception

// MARK: - SP-29 健康设备接入渲染原子（2026-09-26 原子结构轮第三批：自
// DeviceConnectionView 迁出）
//
// 业主组合纪律（2026-09-16）：复杂类必须由专注小类组合。DeviceConnectionView
// 的 9 个 section 原为同一结构体上的私有计算属性（代码搬移而非组合）——
// 本文件承接特征候选区与写回区两个真正独立的叶视图（值 + 闭包），
// 与 SyncStatusSectionView 同族。

/// 业主 2026-09-17 定：Apple 健康特征型 → 档案候选（D 级候选、
/// 用户显式确认才写入；已有值只呈现对照不覆盖——Domain 规则单一事实源）。
struct HealthCharacteristicCandidateSectionView: View {
    let candidates: [HealthCharacteristicImport.Candidate]
    let adoptingField: HealthCharacteristicImport.Field?
    let fieldLabel: (HealthCharacteristicImport.Field) -> String
    let onAdopt: (HealthCharacteristicImport.Candidate) -> Void

    var body: some View {
        Section {
            ForEach(candidates) { candidate in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fieldLabel(candidate.field))
                        if let existing = candidate.existing {
                            Text(L10n.healthCandidateExisting(existing))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if candidate.isAdoptable {
                        Button(L10n.healthCandidateAdopt) { onAdopt(candidate) }
                            .buttonStyle(.bordered)
                            .disabled(adoptingField == candidate.field)
                            .accessibilityIdentifier("SP-29.health.candidate.adopt.\(candidate.field.rawValue)")
                    } else {
                        Text(candidate.proposed).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("SP-29.health.candidate.\(candidate.field.rawValue)")
            }
        } header: { Text(L10n.healthCandidateSection) } footer: { Text(L10n.healthCandidateHint) }
    }
}

/// 业主 2026-09-17 定：写回区（独立于读取开关——分享授权是独立系统授权单）。
/// V4.06（业主 2026-09-23 实测修复）：写回是 opt-in——状态三态行与摘要只在
/// 「开关开启」或「当页刚发生开启尝试未获准并如实回退」的现场态渲染
///（`showsStatus`）；此前 `.denied` 恒显：只读用户误以为读授权故障。
struct HealthWriteBackSectionView: View {
    let writeAuthState: HealthWriteAuthStatus
    let summary: F16DeviceState.WriteSummary?
    let toggle: Binding<Bool>
    let showsStatus: Bool
    let onRetryAuth: () -> Void

    var body: some View {
        Section {
            Toggle(L10n.healthWriteBackLabel, isOn: toggle)
                .accessibilityIdentifier("SP-29.health.writeBack.toggle")
            if showsStatus {
                switch writeAuthState {
                case .granted:
                    Label(L10n.healthWriteBackGranted, systemImage: "checkmark.shield")
                        .accessibilityIdentifier("SP-29.health.writeBack.granted")
                case .denied:
                    Label(L10n.healthWriteBackDenied, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color("semantic-warning", bundle: .main))
                        .accessibilityIdentifier("SP-29.health.writeBack.denied")
                case .notDetermined:
                    VStack(alignment: .leading, spacing: 4) {
                        Label(L10n.healthWriteBackNeedAuth, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color("semantic-warning", bundle: .main))
                        Button(L10n.healthWriteBackRetryAuth) { onRetryAuth() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("SP-29.health.writeBack.retryAuth")
                    }
                }
                if let summary {
                    Text(summary.failed
                         ? L10n.healthWriteBackFailed
                         : L10n.healthWriteBackLast(summary.written, summary.skipped))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("SP-29.health.writeBack.summary")
                }
            }
        } header: { Text(L10n.healthWriteBackSection) } footer: { Text(L10n.healthWriteBackHint) }
    }
}
