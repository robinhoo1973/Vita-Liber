import SwiftUI
import UIKit
import os
import Domain

/// 应用根视图（FR14.4 主题注入 + 门禁/向导/主页三路分支 + 全局生命周期补偿）。
/// 从 VitaLiberApp.body 提取：@Environment 读值需要 View 环境，App 结构体上无法挂
/// .preferredColorScheme（修饰符须落在 WindowGroup 内容上）。环境对象仍由 VitaLiberApp
/// 逐一下发，此处只消费。
struct AppRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(ReminderStore.self) private var reminderStore
    @Environment(AppSettingsStore.self) private var settingsStore
    @Environment(\.scenePhase) private var scenePhase

    /// F16 信源库幂等种子（由 VitaLiberApp 注入 container.guidelines.seedBundled ——
    /// AppContainer 不进环境，闭包传递保持装配根单一）
    let seedBundled: () async throws -> Void

    /// 退后台锁屏状态（FR1.4）：scenePhase 切 background 置位，回前台由门禁遮罩接管。
    /// 评审修正：锁定优先级在向导分支**之前**——门禁一旦建立，向导期间退后台同样锁屏。
    @State private var backgroundLocked = false

    var body: some View {
        Group {
            if backgroundLocked || appState.needsLockScreen {
                LockOverlayView { backgroundLocked = false }
            } else if !appState.onboardingFinished {
                OnboardingFlowView()
            } else {
                RootAdaptiveView()
            }
        }
        // FR14.4 主题注入（tech-spec §5.28.1）：nil = 跟随系统；@Observable 读值即时生效
        .preferredColorScheme(currentTheme.colorScheme)
        // FR14.4 高对比度初始实现 = 环境对比度增强（§5.28.1 记录为偏差：HC Token 集归 L2）
        .contrast(highContrastOn ? 1.25 : 1.0)
        .task {
            await settingsStore.load()   // 主题等设置先于首帧后的首次渲染就位
            await appState.bootstrap()
            // F16 信源库种子幂等入库（离线零网络可用）
            do { try await seedBundled() }
            catch {
                Logger(subsystem: "com.vitaliber", category: "app").error("信源播种失败: \(error)")
            }
            // 四层补偿第 1 层（§5.4 V3.29）：前台启动时对账 + 首启请求通知授权
            if appState.onboardingFinished {
                await reminderStore.requestNotificationAuthorization()
                await reminderStore.refresh(patientId: appState.currentPatientId)
            }
        }
        // 四层补偿第 3 层：时区/时间显著变化 → 立即对账（View 级修饰符）
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.significantTimeChangeNotification)) { _ in
            Task {
                await reminderStore.refresh(patientId: appState.currentPatientId)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive, .background:
                // FR1.4 + FR1.7：退后台即锁。用 .inactive 而非 .background——
                // 任务切换器快照在 inactive 时刻截取（遮罩必须此时已挂载），
                // 且 XCUITest 的 press(.home) 场景下 .background 送达不可靠
                if appState.onboardingFinished { backgroundLocked = true }
            case .active:
                // 四层补偿第 2 层：每次回前台轻量对账
                if appState.onboardingFinished {
                    Task {
                        await reminderStore.refresh(patientId: appState.currentPatientId)
                    }
                }
            default:
                break
            }
        }
    }

    // MARK: - FR14.4 外观与主题

    private var currentTheme: AppTheme {
        AppTheme(rawValue: settingsStore.values[.appearance]
                 ?? AppSettingKey.appearance.defaultValue) ?? .system
    }

    /// FR18.16：手动开关 OR 关怀模式；关怀模式退出自动回落手动选择
    private var highContrastOn: Bool {
        AppearanceRules.highContrastEffective(
            highContrastEnabled: settingsStore.values[.highContrastEnabled] == "true",
            careMode: appState.careMode)
    }
}
