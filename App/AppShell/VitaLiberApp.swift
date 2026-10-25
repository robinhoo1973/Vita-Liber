import Foundation
import SwiftUI
import os
import Domain
import Infrastructure
import Protocols
import Perception

/// 薄壳：首帧前只做语言恢复与随包定标，数据库探测/迁移在启动门后台执行。
/// 初始化未完成前只渲染 `DatabaseInitializationView`，不创建任何 store。
@main
@MainActor
struct VitaLiberApp: App {
    @StateObject private var boot = DatabaseBootModel()
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
        // FR14.5 启动语言恢复（评审修正）：同步执行、首帧前完成——
        // 消除非默认语言用户首帧 zh-Hans 闪烁；不广播（重渲染由
        // settingsStore.values[.language] 观察驱动，见 AppRootView）。
        L10n.restoreLanguage()
        // G17（2026-10-18）：B1 随包脚本定标——60 条脚本金样 → voiceDeterministicEnabled。
        // 缺件/不达标保持关闭（release 入口随默认隐藏）；B2 500 真人门独立。
        VoiceCalibrationBundled.apply()
        // BGTaskScheduler 要求所有标识符在 App 启动完成前注册；数据库启动门
        // 异步完成，故在此先登记作业（执行体等待 AppSessionHolder 就绪）。
        BackgroundWorkScheduler.shared.addContinued(
            identifier: BackgroundWorkScheduler.asrInstallContinuedIdentifier)
        BackgroundWorkScheduler.shared.add(ReminderReconcileJob {
            guard let session = await AppSessionHolder.shared.wait() else { return }
            let member = await MainActor.run { session.appState.currentPatientId }
            await session.reminderStore.refreshTriggered(patientId: member, force: true)
        })
        HealthKitSyncService.registerBackgroundTask()
        _ = BackgroundWorkScheduler.shared.submit(ReminderReconcileJob.identifier)
    }

    var body: some Scene {
        WindowGroup {
            WithPerceptionTracking {
                if let container = boot.container {
                    ReadyAppRoot(container: container, router: router, notificationDelegate: notificationDelegate)
                } else {
                    DatabaseInitializationView(model: boot)
                        .task { await boot.start() }
                }
            }
        }
    }
}
