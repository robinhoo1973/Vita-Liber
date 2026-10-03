import SwiftUI
import Domain
import Perception

/// 健康导入类型行共享组件（2026-10-03 呈现评审 T3；ui-ux V4.13 后续注记）。
///
/// HealthTabView 与 DeviceConnectionView 曾**逐字复制**同一行布局（连图标
/// `.frame(width: 26)` 都相同），违背 ADR-021「单一内容视图」精神——提取为
/// 共享组件，两处只传差异参数：
/// - 同步进度条仅健康 Tab 展示（业主 2026-09-19 类别卡进度诉求的落点）；
/// - a11y 前缀各自保持（`SP-29.health.home.data.*` / `SP-29.health.data.*`）。
struct HealthImportedTypeRow: View {
    @Environment(F16DeviceState.self) private var deviceState

    let type: HealthImportRow
    let patientId: String
    let accessibilityPrefix: String
    /// 同步进度条的 a11y 前缀（健康 Tab 契约 `SP-29.health.home.progress.*`，
    /// 与行前缀 `…home.data.*` 不同——保持既有 XCUITest 契约不变）
    var syncProgressPrefix: String?
    var showsSyncProgress: Bool = false

    var body: some View {
        WithPerceptionTracking {
            // 类型安全路由（§5.45）：身份由 patientId（= 本人绑定）经载荷下传——
            // 绝不回落当前成员（BR-001）。
            NavigationLink(value: AppRoute.healthImportedData(kind: type.kind,
                                                              patientId: patientId)) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        // 审查修复（指标图标）：经 CardKindIcon.spec(metric:) 单一出口
                        // 渲染指标符号（与时间轴/SP-29 同符号）
                        Image(systemName: CardKindIcon.spec(metric: type.kind.primaryMetric).symbol)
                            .font(.title3)
                            .foregroundStyle(CardKindIcon.tint(metric: type.kind.primaryMetric))
                            .frame(width: 26)
                        Text(L10n.metricName(type.kind.primaryMetric))
                        Spacer()
                        Text(L10n.healthImportedPointCount(type.rowCount))
                            .foregroundStyle(.secondary)
                    }
                    if let latest = type.latestAt {
                        Text(latest.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // 2026-09-19 审查修复（业主诉求：类别卡导入进度条）：同步进行中
                    // 该类别卡显示确定性排空进度（基线 = 本轮同步首见剩余窗口数）。
                    if showsSyncProgress, deviceState.isSyncing,
                       let fraction = deviceState.kindProgress[type.kind.rawValue] {
                        ProgressView(value: fraction)
                            .accessibilityIdentifier("\(syncProgressPrefix ?? accessibilityPrefix).\(type.kind.rawValue)")
                    }
                }
                .frame(minHeight: 44)
            }
            .accessibilityIdentifier("\(accessibilityPrefix).\(type.kind.rawValue)")
        }
    }
}
