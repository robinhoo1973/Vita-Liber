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

    var body: some View {
        // FR14.5 语言切换即时生效（评审修正）：此前 .id(languageVersion) 全树
        // 身份重置实现「重建」——销毁所有子孙 @State（草稿/弹窗/滚动）、重跑
        // 各 Tab 的 .task，且从语言页（自身是 push 路由）切换时深栈重挂载，
        // 与 build-147 崩溃同类（EnvironmentValues 断言）。正确机制 = 本行
        // 读 settingsStore.values[.language]：@Observable 读值注册观察，
        // 设置页 await settings.set(...) 变更即触发重渲染，L10n.t() 按新语言
        // 解析——视图身份不变、零状态丢失（与 currentTheme 同一模式）。
        let _ = currentLanguage
        Group {
            if backgroundLocked || appState.needsLockScreen {
                LockOverlayView { backgroundLocked = false }
            } else if !appState.onboardingFinished {
                OnboardingFlowView()
            } else {
                RootAdaptiveView()
            }
        }
        // 第七轮全仓审查修复（FR1.7/BR-007 任务切换器快照）：宽限 >0 时遮罩
        // 未在 .inactive 快照时刻挂载——切换器快照拍到解锁态的病历界面。
        // privacySensitive 让系统在非 active 相位对快照做隐私遮罩（redact），
        // 与宽限锁独立：不改变宽限锁的正式锁定时刻，只遮快照。
        .privacySensitive(scenePhase != .active)
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
            // 语言初始化已移至 VitaLiberApp.init（L10n.restoreLanguage 同步恢复，
            // 首帧即正确语言，无闪烁）；但 restoreLanguage 只读 vl.language 镜像，
            // 设置库（DB，随备份迁移）才是权威事实源——备份恢复到新设备时二者
            // 可能分叉（L10n 渲染 zh-Hans、设置页却选中 zh-Hant）。加载完成后
            // 以 DB 值对账一次（setLanguage 相等性守卫保证幂等、不误广播）。
            if let dbLang = settingsStore.values[.language] {
                L10n.setLanguage(dbLang)
            }
            await appState.bootstrap()
            appState.restoreBackupMark()   // 上次备份时刻镜像就位（FR13.10 观察联动）
            // 第八轮全仓审查修复（启动串行链并行化）：信源播种（DB 写）、
            // 敏感媒体孤儿对账（文件系统扫描）、提醒链（物化+对账+备份提醒）
            // 三链互不依赖，此前严格串行 = 三者延迟之和拖慢提醒数据就位。
            // 并发执行（同一 actor 的内部串行由 actor 语义保证；各链失败
            // 上报，互不阻断）。
            do {
                // F16 信源库种子幂等入库（离线零网络可用）
                async let seed: Void = seedBundled()
                // 敏感媒体孤儿对账（评审修正）：崩溃/失败写入的残留照片启动时清除
                async let reconcile: Void = observationState.reconcileAssets()
                // 四层补偿第 1 层（§5.4 V3.29）：前台启动时对账。
                // FR20.2 授权时序：通知权限严禁启动即索权——请求时机移到
                // 「完成第一个提醒计划创建后」（价值先行）。
                if appState.onboardingFinished {
                    async let refresh: Void = reminderStore.refreshTriggered(patientId: appState.currentPatientId)
                    // FR13.10 定期备份提醒（默认 30 天；只引导，不自动建包）
                    async let backup: Void = reminderStore.scheduleBackupReminderIfNeeded(lastBackupAt: appState.lastBackupAt)
                    _ = try await (seed, reconcile, refresh, backup)
                } else {
                    _ = try await (seed, reconcile)
                }
            } catch {
                Logger(subsystem: "com.vitaliber", category: "app").error("启动预载失败: \(error)")
            }
        }
        // FR14.5 语言切换的非视图副作用：已排程通知的标题/正文在排程时固化，
        // 语言变化后须以新语言重写待投递请求（相同 identifier 的 add 即替换）。
        // 视图重渲染不依赖本通知（由 settingsStore.values[.language] 观察驱动）。
        .onReceive(NotificationCenter.default.publisher(
            for: L10n.languageDidChange)) { _ in
            Task {
                await reminderStore.reloadLocalizedScheduledContent()
            }
        }
        // 评审修正第二轮（FR13.10 周期再武装）：backup-reminder 的已送达记录是
        // 「本周期已提醒」标记——完成一次备份即开启新周期，必须清除，否则
        // 提醒送达一次后永久静默。lastBackupAt 变化 = 备份完成信号。
        .onChange(of: appState.lastBackupAt) { oldValue, newValue in
            guard newValue != nil, newValue != oldValue else { return }
            Task { await reminderStore.clearBackupReminderDelivered() }
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
                // FR9.6 第 3 层：时区变化即时对账不得被 500ms 去抖吞掉（force）
                await reminderStore.refreshTriggered(patientId: appState.currentPatientId, force: true)
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
                        // 宽限窗口内回前台即取消（宽限只影响正式锁定时刻）
                        // 第七轮全仓审查修复：回前台同样经过 .inactive（active→
                        // inactive→background→inactive→active），本分支会再跑一次
                        // 并**覆盖** graceLockTask——旧任务未取消，其宽限期满后
                        // 在用户正使用中置 backgroundLocked，使用中突然被锁屏
                        // （FR1.4 语义破坏）。覆盖前必须先取消旧任务。
                        graceLockTask?.cancel()
                        graceLockTask = Task {
                            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))   // try?-ok: 宽限计时取消即停
                            guard !Task.isCancelled else { return }
                            backgroundLocked = true
                        }
                    } else {
                        graceLockTask?.cancel()
                        graceLockTask = nil
                        backgroundLocked = true
                    }
                }
            case .active:
                graceLockTask?.cancel()
                graceLockTask = nil
                // 四层补偿第 2 层：每次回前台轻量对账
                if appState.onboardingFinished {
                    Task {
                        await reminderStore.refreshTriggered(patientId: appState.currentPatientId)
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

    /// FR14.5 当前显示语言：body 顶层读值注册 @Observable 观察，
    /// 设置页 `settings.set(_, for: .language)` 变更即整树重渲染。
    private var currentLanguage: String {
        settingsStore.values[.language] ?? AppSettingKey.language.defaultValue
    }

    /// FR18.16：手动开关 OR 关怀模式；关怀模式退出自动回落手动选择
    private var highContrastOn: Bool {
        AppearanceRules.highContrastEffective(
            highContrastEnabled: settingsStore.values[.highContrastEnabled] == "true",
            careMode: appState.careMode)
    }
}
