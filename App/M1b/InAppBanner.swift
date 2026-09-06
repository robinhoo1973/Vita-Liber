import SwiftUI
import Domain

/// §4.22 InAppBanner（FR9.18/§5.58 · V3.72 点亮）：前台到期用药横幅——
/// [确认] 直连确认服药（BR-004：只有用户显式动作才算）、[稍后] 15 分钟静默、
/// 5 秒自动收起；总开关 = AppSettingKey.inAppBannerEnabled。
/// 挂在 RootAdaptiveView 顶层 overlay，跨 Tab 可见。
struct InAppBannerHost: View {
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminders
    @Environment(AppSettingsStore.self) private var settings

    @State private var dismissedUntil: Date = .distantPast
    @State private var autoDismiss: Task<Void, Never>?

    var body: some View {
        Group {
            if let banner = currentBanner {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.bannerDoseDue).font(.subheadline.bold())
                    Text(banner.displayLabel)
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button(L10n.bannerConfirm) {
                            Task {
                                _ = await reminders.confirmTaken(patientId: app.currentPatientId,
                                                                 dose: banner.dose)
                                hide()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button(L10n.bannerLater) {
                            dismissedUntil = Date().addingTimeInterval(15 * 60)
                            hide()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .frame(minHeight: 44)   // 触点 ≥44pt
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14)
                    .fill(.regularMaterial))
                .shadow(radius: 6)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("SP-04.inAppBanner")
            }
        }
        .animation(.easeInOut(duration: 0.25), value: currentBanner?.id)
        .task(id: currentBanner?.id) {
            // 5 秒自动收起（§4.22）；新横幅出现时重置计时
            guard currentBanner != nil else { return }
            autoDismiss?.cancel()
            autoDismiss = Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)   // try?-ok: 自动收起计时取消即停
                guard !Task.isCancelled else { return }
                withAnimation { hide() }
            }
        }
    }

    /// 横幅触发条件：开关开启 + 当前成员存在到期未处理剂量 + 未被稍后静默
    private var currentBanner: DoseRecord? {
        guard settings.values[.inAppBannerEnabled] != "false" else { return nil }
        guard Date() >= dismissedUntil else { return nil }
        let now = Date()
        // 2 小时窗口内到期且未处理的剂量（早于窗口视为历史遗留，交提醒 Tab 处理）
        return reminders.todaySlots
            .flatMap(\.records)
            .filter { $0.action == nil && $0.dose.dueAt <= now && $0.dose.dueAt > now.addingTimeInterval(-2 * 3600) }
            .sorted { $0.dose.dueAt < $1.dose.dueAt }
            .first
    }

    private func hide() {
        autoDismiss?.cancel()
        autoDismiss = nil
    }
}
