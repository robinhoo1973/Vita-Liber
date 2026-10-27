import Foundation
import Domain
import Infrastructure

/// 批C③（第九轮审查 P4#2）：提醒对账的后台兜底作业（ReminderReconciler 文档
/// 宣称的四层触发之**第四层**——此前 plist 无标识符、全仓无 BG 调用，只做提醒
/// 用途的设备 8 天不开 App 即停提醒）。执行体由装配处注入（与前台同入口
/// refreshTriggered → reconcile，幂等）；运行后按结果重排，BackgroundWorkScheduler
/// 自动续排形成滚动兜底。
///
/// 2026-10-27 审查 P1：旧实现忽略预算与取消——系统到期取消 Task 后仍恒报
/// success+reschedule，且执行体可能卡在会话等待上。现在执行体返回 Bool，
/// 被取消或执行体放弃时如实报失败且不重排。
struct ReminderReconcileJob: BackgroundJob {
    static let identifier = "com.vitaliber.reminders-reconcile"
    let handler: @Sendable () async -> Bool
    let descriptor = BackgroundJobDescriptor(identifier: ReminderReconcileJob.identifier,
                                             kind: .refresh,
                                             minimumInterval: 30 * 60)
    func run(budget: Duration) async -> BackgroundJobOutcome {
        if Task.isCancelled { return BackgroundJobOutcome(success: false, reschedule: false) }
        let ok = await handler()
        if Task.isCancelled { return BackgroundJobOutcome(success: false, reschedule: false) }
        return BackgroundJobOutcome(success: ok, reschedule: ok)
    }
}
