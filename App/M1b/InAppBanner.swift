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
    /// 第七轮修复：「稍后」15 分钟后的复现唤醒——dismissedUntil 到期时
    /// 无任何 @State/@Observable 变化触发重渲染（用户在前台静置时横幅
    /// 永不复发，注释「15 分钟后自然复现」落空）。到点把静默截止回拨
    /// 到 distantPast，currentBanner 重算即复现。
    @State private var reappearWake: Task<Void, Never>?
    /// 5 秒自动收起标记——按**剂量 id 集合**记忆（第七轮全仓审查修复：
    /// 原会话级布尔在首次自动收起后恒 true，currentBanner 永返 nil 而复位代码
    /// 又被 `guard currentBanner != nil` 挡死——当天的后续到期剂量全部静默，
    /// FR9.18 横幅通道整会话失效）。集合语义：已自动收起的剂量本会话不复发
    /// （待办仍在提醒 Tab），候选选取自动跳过它们、按到期序取下一条未收起剂量。
    @State private var autoHiddenIds: Set<String> = []

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
                            let until = Date().addingTimeInterval(15 * 60)
                            dismissedUntil = until
                            hide()
                            // 15 分钟到点唤醒重渲染（第七轮修复：无此唤醒则
                            // 横幅在前台静置期间永不复发）
                            reappearWake?.cancel()
                            reappearWake = Task {
                                let wait = until.timeIntervalSinceNow + 0.1
                                try? await Task.sleep(nanoseconds: UInt64(max(wait, 0.1) * 1_000_000_000))   // try?-ok: 睡眠取消即停（新稍后/确认会取消本任务）
                                guard !Task.isCancelled else { return }
                                dismissedUntil = .distantPast
                            }
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
            // 5 秒自动收起（§4.22）；新横幅（id 变化）出现时重置计时。
            // 取消必须先于 guard（审查修复）：currentBanner 变 nil（开关关闭/
            // 成员切换）时旧计时任务必须作废——原 guard 先行 return，取消分支
            // 不可达；5 秒后旧任务把用户从未见过的剂量 id 写入 autoHiddenIds，
            // currentBanner 过滤恒排除该剂量 → 本会话横幅永久不复发（FR9.18）。
            autoDismiss?.cancel()
            guard let banner = currentBanner else { return }
            autoDismiss = Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)   // try?-ok: 自动收起计时取消即停
                guard !Task.isCancelled else { return }
                // 第六轮全仓审查修复：原 hide() 只取消计时任务、不改任何
                // currentBanner 读取的状态——5 秒后横幅纹丝不动，永久遮挡
                // 内容。自动收起必须写入被 currentBanner 判读的开关；
                // 「稍后」路径仍走 dismissedUntil（15 分钟后自然复现）
                _ = withAnimation { autoHiddenIds.insert(banner.id) }
            }
        }
    }

    /// 横幅触发条件：开关开启 + 当前成员存在到期未处理剂量 + 未被稍后静默/自动收起
    private var currentBanner: DoseRecord? {
        guard settings.values[.inAppBannerEnabled] != "false" else { return nil }
        guard Date() >= dismissedUntil else { return nil }
        let now = Date()
        // 2 小时窗口内到期且未处理的剂量（早于窗口视为历史遗留，交提醒 Tab 处理）；
        // 已自动收起的剂量跳过（第七轮修复：不再压住后续到期剂量的横幅）
        return reminders.todaySlots
            .flatMap(\.records)
            .filter { $0.action == nil
                && $0.dose.dueAt <= now
                && $0.dose.dueAt > now.addingTimeInterval(-2 * 3600)
                && !autoHiddenIds.contains($0.id) }
            .sorted { $0.dose.dueAt < $1.dose.dueAt }
            .first
    }

    private func hide() {
        autoDismiss?.cancel()
        autoDismiss = nil
        reappearWake?.cancel()
        reappearWake = nil
    }
}
