import Foundation
import Domain
import Infrastructure

/// 批C③（第九轮审查 P4#2）：提醒对账的后台兜底作业（ReminderReconciler 文档
/// 宣称的四层触发之**第四层**——此前 plist 无标识符、全仓无 BG 调用，只做提醒
/// 用途的设备 8 天不开 App 即停提醒）。执行体由装配处注入（与前台同入口
/// refreshTriggered → reconcile，幂等）；运行后恒重排（reschedule: true），
/// BackgroundWorkScheduler 自动续排形成滚动兜底。预算取系统给的 refresh 预算，
/// 对账本身为轻量 DB 读 + 系统 IPC。
struct ReminderReconcileJob: BackgroundJob {
    static let identifier = "com.vitaliber.reminders-reconcile"
    let handler: @Sendable () async -> Void
    let descriptor = BackgroundJobDescriptor(identifier: ReminderReconcileJob.identifier,
                                             kind: .refresh,
                                             minimumInterval: 30 * 60)
    func run(budget: Duration) async -> BackgroundJobOutcome {
        await handler()
        // refreshTriggered 按纪律内部吞错记日志（任一层成功即满足正确性）；
        // 对账幂等 → 作业恒报 success + 重排
        return BackgroundJobOutcome(success: true, reschedule: true)
    }
}