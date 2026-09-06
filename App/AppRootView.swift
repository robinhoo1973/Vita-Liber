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
    @Environment(ObservationStoreState.self) private var observationState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var systemDynamicType

    /// F16 信源库幂等种子（由 VitaLiberApp 注入 container.guidelines.seedBundled ——
    /// AppContainer 不进环境，闭包传递保持装配根单一）
    let seedBundled: () async throws -> Void

    /// 退后台锁屏状态（FR1.4）：scenePhase 切 background 置位，回前台由门禁遮罩接管。
    /// 评审修正：锁定优先级在向导分支**之前**——门禁一旦建立，向导期间退后台同样锁屏。
    @State private var backgroundLocked = false
    /// FR9.6 时区变化提示：重排是数据层义务、提示核对是 UI 义务——
    /// 此前只做了「重排」半句，用户跨时区后按错误墙钟时刻服药（V3.72 补全）
    @State private var lastTimeZoneId = TimeZone.current.identifier
    @State private var timezoneChanged = false
    /// FR1.4 宽限锁任务（V3.72 接线：0/15/60 秒可配置；此前键死、立即锁无宽限）
    @State private var graceLockTask: Task<Void, Never>?
    /// FR14.5 语言切换即时生效：L10n.setLanguage 发通知，递增计数器强制视图重建
    @State private var languageVersion = 0

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
        // FR14.5 语言切换即时生效：L10n 变更后强制重建整个视图树
        .id(languageVersion)
        // FR14.4 主题注入（tech-spec §5.28.1）：nil = 跟随系统；@Observable 读值即时生效
        .preferredColorScheme(currentTheme.colorScheme)
        // FR14.4 高对比度初始实现 = 环境对比度增强（§5.28.1 记录为偏差：HC Token 集归 L2）
        .contrast(highContrastOn ? 1.25 : 1.0)
        // FR18.9 感官强化：关怀模式在**用户系统字号基础上**放大（≥accessibility1
        // 且再高一档，上限 accessibility5）。
        // 审查修复：原实现两态都钉死固定档——常规模式强制 .large（AX2 用户被
        // 压回大字号），关怀模式钉死 .accessibility1（不随用户设置），
        // Dynamic Type 全局承诺对两组用户都失效
        .dynamicTypeSize(effectiveDynamicTypeSize)
        .task {
            await settingsStore.load()   // 主题等设置先于首帧后的首次渲染就位
            // FR14.5 语言即时切换：以持久化偏好初始化显示语言（无需重启）
            L10n.setLanguage(settingsStore.values[.language]
                             ?? AppSettingKey.language.defaultValue)
            await appState.bootstrap()
            // F16 信源库种子幂等入库（离线零网络可用）
            do { try await seedBundled() }
            catch {
                Logger(subsystem: "com.vitaliber", category: "app").error("信源播种失败: \(error)")
            }
            // 敏感媒体孤儿对账（评审修正）：崩溃/失败写入的残留照片启动时清除
            await observationState.reconcileAssets()
            // 四层补偿第 1 层（§5.4 V3.29）：前台启动时对账。
            // FR20.2 授权时序：通知权限严禁启动即索权——请求时机移到
            // 「完成第一个提醒计划创建后」（价值先行，ReminderStore.createPlan/createAppointment）。
            if appState.onboardingFinished {
                await reminderStore.refresh(patientId: appState.currentPatientId)
                // FR13.10 定期备份提醒（默认 30 天；只引导，不自动建包；联动 F22.4）
                await reminderStore.scheduleBackupReminderIfNeeded(lastBackupAt: appState.lastBackupAt)
            }
        }
        // FR14.5 语言切换即时生效：监听 L10n 通知，递增版本号强制视图重建
        .onReceive(NotificationCenter.default.publisher(
            for: L10n.languageDidChange)) { _ in
            languageVersion += 1
        }
        // 四层补偿第 3 层：时区/时间显著变化 → 立即对账（View 级修饰符）
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.significantTimeChangeNotification)) { _ in
            let newId = TimeZone.current.identifier
            if newId != lastTimeZoneId {
                lastTimeZoneId = newId
                timezoneChanged = true   // FR9.6：时区变化必须提示核对（不静默重排）
            }
            Task {
                await reminderStore.refresh(patientId: appState.currentPatientId)
            }
        }
        .alert(L10n.timezoneChangedTitle, isPresented: $timezoneChanged) {
            Button(L10n.onboard_gotIt, role: .cancel) {}
        } message: {
            Text(L10n.timezoneChangedBody)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive, .background:
                // FR1.4 + FR1.7：退后台即锁。用 .inactive 而非 .background——
                // 任务切换器快照在 inactive 时刻截取（遮罩必须此时已挂载），
                // 且 XCUITest 的 press(.home) 场景下 .background 送达不可靠。
                // 审查修复：应用自身的系统认证浮层（Face ID）同样令场景短暂
                // inactive——豁免在途认证，否则导出向导/备份等动作被锁屏覆盖
                // 层销毁状态并二次弹认证
                if appState.onboardingFinished && !appState.authPromptInFlight {
                    let grace = Double(Int(settingsStore.values[.gateGraceSeconds] ?? "0") ?? 0)
                    if grace > 0 {
                        // 宽限窗口内回前台即取消（切换任务器快照在 inactive 已挂遮罩，
                        // 宽限只影响正式锁定时刻）
                        graceLockTask = Task {
                            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))   // try?-ok: 宽限计时取消即停
                            guard !Task.isCancelled else { return }
                            backgroundLocked = true
                        }
                    } else {
                        backgroundLocked = true
                    }
                }
            case .active:
                graceLockTask?.cancel()
                graceLockTask = nil
                // 四层补偿第 2 层：每次回前台轻量对账
                if appState.onboardingFinished {
                    Task {
                        await reminderStore.refresh(patientId: appState.currentPatientId)
                        // 时间轴镜像随前台刷新（资料库入库的文档进入待确认计数）
                        await appState.refreshTimeline()
                    }
                }
            default:
                break
            }
        }
    }

    // MARK: - FR14.4 外观与主题

    /// 常规模式 = 系统字号原样；关怀模式 = 系统字号基础上再放大一档
    ///（至少 accessibility1，上限 accessibility5）
    private static let dynamicTypeSizes = DynamicTypeSize.allCases   // 静态缓存：allCases 数组避免每次 body 求值重分配

    private var effectiveDynamicTypeSize: DynamicTypeSize {
        guard appState.careMode else { return systemDynamicType }
        let sizes = Self.dynamicTypeSizes
        let floor: DynamicTypeSize = .accessibility1
        let base = systemDynamicType >= floor ? systemDynamicType : floor
        guard let idx = sizes.firstIndex(of: base), idx + 1 < sizes.count else { return base }
        return sizes[idx + 1]
    }

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
