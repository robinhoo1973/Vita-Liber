import Foundation
import SwiftUI
import os
import Domain
import Infrastructure
import Protocols
import Perception

/// 薄壳：首帧前只做语言恢复与随包定标；数据库探测/迁移在启动门后台执行。
/// 初始化未完成前只渲染 `DatabaseInitializationView`，不创建任何 store。
///
/// 启动门在 `init` 即启动（不等首帧）：后台冷启动没有 UI 首帧，若只在视图
/// `.task` 里启动，BGTask 永远等不到会话（2026-10-27 审查 P1）。
@main
@MainActor
struct VitaLiberApp: App {
    @StateObject private var boot: DatabaseBootModel
    /// 通知 delegate 必须在启动早期挂上（系统在冷启动完成前可能投递点击）；
    /// 数据库启动门异步，故由 App 壳持有并注入会话。
    private let router: AppRouter
    private let notificationDelegate: AppNotificationDelegate

    init() {
        let router = AppRouter()
        let notificationDelegate = AppNotificationDelegate(router: router)
        self.router = router
        self.notificationDelegate = notificationDelegate
        UNUserNotificationCenter.current().delegate = notificationDelegate
        let boot = DatabaseBootModel { container, catalogSlicesState in
            AppSession(container: container, router: router,
                       notificationDelegate: notificationDelegate,
                       catalogSlicesState: catalogSlicesState)
        }
        _boot = StateObject(wrappedValue: boot)
        // FR14.5 启动语言恢复（评审修正）：同步执行、首帧前完成——
        // 消除非默认语言用户首帧 zh-Hans 闪烁；不广播（重渲染由
        // settingsStore.values[.language] 观察驱动，见 AppRootView）。
        L10n.restoreLanguage()
        // G17（2026-10-18）：B1 随包脚本定标——60 条脚本金样 → voiceDeterministicEnabled。
        // 缺件/不达标保持关闭（release 入口随默认隐藏）；B2 500 真人门独立。
        VoiceCalibrationBundled.apply()
        // BGTaskScheduler 要求所有标识符在 App 启动完成前注册；执行体等待
        // AppSessionHolder（启动门负责创建会话；等待有界且可取消）。
        BackgroundWorkScheduler.shared.addContinued(
            identifier: BackgroundWorkScheduler.asrInstallContinuedIdentifier)
        BackgroundWorkScheduler.shared.add(ReminderReconcileJob {
            guard let session = await AppSessionHolder.shared.wait() else { return false }
            let member = await MainActor.run { session.appState.currentPatientId }
            await session.reminderStore.refreshTriggered(patientId: member, force: true)
            return !Task.isCancelled
        })
        HealthKitSyncService.registerBackgroundTask()
        _ = BackgroundWorkScheduler.shared.submit(ReminderReconcileJob.identifier)
        #if DEBUG
        // 两段式钩子（2026-10-29）：必须同步删库于 boot.start 之前——
        // 启动门在 init 尾部即开跑，晚于本调用的删除会撞已被打开的库。
        if ProcessInfo.processInfo.arguments.contains("-uitest-boot-fresh-db") {
            AppContainer.debugErasePatientDatabaseForUITest()
        }
        #endif
        // headless 启动：后台唤起也能把数据库门走完。
        Task { await boot.start() }
    }

    /// 样张图库直达（仅 DEBUG；2026-10-29 样张图库批）：
    /// 模拟器以 `-uitest-samples` 启动即进 Sample Gallery，不进产品导航。
    private var isShowingSamples: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-uitest-samples")
        #else
        return false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            WithPerceptionTracking {
                if isShowingSamples {
                    SamplesRootView()
                }
                // U-批 B2 交接门：容器就绪但自检页未放行时继续展示启动页
                // （session 已在页下创建；用户永远看不到未建 session 的主界面）。
                else if boot.isShowingReadOnly, let readOnly = boot.readOnlyContainer {
                    // 只读降级壳（B2）：显式入口进入；不建会话、零写零联网。
                    ReadOnlyAppRoot(container: readOnly)
                } else if let container = boot.container, !boot.isShowingBootScreen {
                    ReadyAppRoot(container: container, router: router, notificationDelegate: notificationDelegate)
                } else {
                    DatabaseInitializationView(model: boot)
                        // 幂等：init 已启动，视图再次触发由 isRunning/container 守卫吸收。
                        .task { await boot.start() }
                }
            }
        }
    }
}
