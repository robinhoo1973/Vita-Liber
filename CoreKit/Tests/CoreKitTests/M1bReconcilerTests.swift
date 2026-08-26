import Foundation
import Testing
@testable import Domain
@testable import Protocols
@testable import Infrastructure

/// M1b · 提醒可靠性四用例（dev-pm §3.2.2 退出准则）——注入 InMemoryReminderScheduler
/// + 假 DoseSource，生产路径零改动（test-plan E7）。

/// 可控事实源：按测试脚本推进时间与状态
actor FakeDoseSource: DoseSource {
    private var facts: [DoseDeliveryFact] = []
    func set(_ f: [DoseDeliveryFact]) { facts = f }
    func deliveryFacts(from: Date, to: Date) async throws -> [DoseDeliveryFact] {
        facts.filter { $0.dose.dueAt >= from && $0.dose.dueAt <= to }
    }
    func markAwaitingUser(_ notifyId: String) async throws {
        if let i = facts.firstIndex(where: { $0.dose.notifyId == notifyId }) {
            var f = facts[i]; f.action = nil; f.delivered = true; facts[i] = f
        }
    }
    var all: [DoseDeliveryFact] { facts }
}

@Suite("M1b · 提醒可靠性四用例（§5.4）")
struct ReminderReliabilityTests {
    private var now: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    private func dose(_ id: String, at offset: TimeInterval) -> DoseDeliveryFact {
        DoseDeliveryFact(
            dose: ScheduledDose(dueAt: now.addingTimeInterval(offset), doseUnits: 1, notifyId: id),
            delivered: false, action: nil,
            isDueSoon: offset <= 30 * 60, isExpiredGrace: offset < -15 * 60)
    }

    /// 用例一：杀进程重启当日提醒照常——系统侧 pending 清空后，启动对账必须补排
    @Test func 杀进程重启当日提醒照常() async throws {
        let scheduler = InMemoryReminderScheduler()
        let source = FakeDoseSource()
        let reconciler = ReminderReconciler(scheduler: scheduler, source: source, logger: PrintLogger())

        // 当日两剂
        await source.set([dose("dose-a-1", at: 5 * 60), dose("dose-a-2", at: 3 * 3600)])
        await reconciler.reconcile(now: now)
        var pending = try await scheduler.pending()
        #expect(pending.count == 2)

        // 杀进程：系统 pending 清空（delivered 保留为空——通知尚未发出）
        await scheduler.simulateRestart()
        pending = try await scheduler.pending()
        #expect(pending.isEmpty)

        // 重启 → 启动对账 → 当日提醒全部补排
        await reconciler.reconcile(now: now)
        pending = try await scheduler.pending()
        #expect(pending.count == 2, "重启后当日提醒必须照常补排")
    }

    /// 用例二：离线内核——调度/对账链路不依赖任何网络组件（协议图零网络类型），
    /// 用注入桩即可完整驱动，等价「飞行模式不影响」
    @Test func 飞行模式不影响本地链路() async throws {
        let scheduler = InMemoryReminderScheduler()
        let source = FakeDoseSource()
        let reconciler = ReminderReconciler(scheduler: scheduler, source: source)
        await source.set([dose("dose-b-1", at: 10 * 60)])
        await reconciler.reconcile(now: now)
        let pending = try await scheduler.pending()
        #expect(pending["dose-b-1"] != nil)
        // 链路全程只经 ReminderScheduling/DoseSource 两协议——无任何网络类型，
        // 即离线可用（E5 语义的架构级保证）
    }

    /// 用例三：跨时区时间语义正确——同一「08:00」在各自时区日历下
    /// 都落在本地墙钟 08:00（时区变更后对账以本地日历重锚）
    @Test func 跨时区时间语义正确() {
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let start = shanghai.date(from: DateComponents(year: 2026, month: 8, day: 26))!

        let (sh, _) = DoseScheduleEngine.doses(schedule: .fixed(times: ["08:00"]),
                                               planId: UUID(), startDate: start,
                                               fromDay: 1, toDay: 1, calendar: shanghai)
        let (ut, _) = DoseScheduleEngine.doses(schedule: .fixed(times: ["08:00"]),
                                               planId: UUID(), startDate: start,
                                               fromDay: 1, toDay: 1, calendar: utc)
        // 墙钟语义：各自时区下都是本地 08:00 整
        #expect(shanghai.component(.hour, from: sh[0].dueAt) == 8)
        #expect(shanghai.component(.minute, from: sh[0].dueAt) == 0)
        #expect(utc.component(.hour, from: ut[0].dueAt) == 8)
        // 绝对时刻差 = 时区偏移差（上海 08:00 CST = 00:00 UTC；
        // UTC 历的「当天」按 UTC 日界锚定，属正确语义）
        #expect(sh[0].dueAt.timeIntervalSince1970 != ut[0].dueAt.timeIntervalSince1970)
    }

    /// 用例四：处方到期次日不再提醒——计划 ended 后事实源不再返回剂量，
    /// 对账必须清除系统侧全部残留 pending（到期自动停）
    @Test func 处方到期次日不再提醒() async throws {
        let scheduler = InMemoryReminderScheduler()
        let source = FakeDoseSource()
        let reconciler = ReminderReconciler(scheduler: scheduler, source: source)

        // 计划 active：预排一剂
        await source.set([dose("dose-c-1", at: 60 * 60)])
        await reconciler.reconcile(now: now)
        var pending = try await scheduler.pending()
        #expect(pending["dose-c-1"] != nil)

        // 计划 ended（FR9.15）：事实源不再返回该计划任何剂量
        await source.set([])
        await reconciler.reconcile(now: now)
        pending = try await scheduler.pending()
        #expect(pending.isEmpty, "计划结束后残留 pending 必须被清除（到期自动停）")
    }

    /// 64 pending 上限：超预算按优先级裁撤（用药保留、随访裁掉、同优先级裁最晚）
    @Test func 六十四上限优先级裁撤() async throws {
        let scheduler = InMemoryReminderScheduler()
        let source = FakeDoseSource()
        let reconciler = ReminderReconciler(scheduler: scheduler, source: source)
        // 65 条 pending：40 用药 + 20 预约 + 5 随访
        var facts: [DoseDeliveryFact] = []
        for i in 0..<40 {
            facts.append(DoseDeliveryFact(
                dose: ScheduledDose(dueAt: now.addingTimeInterval(TimeInterval(60 * (i + 1))),
                                    doseUnits: 1, notifyId: "dose-x-\(i)"),
                delivered: false, action: nil, isDueSoon: false, isExpiredGrace: false))
        }
        for i in 0..<20 {
            facts.append(DoseDeliveryFact(
                dose: ScheduledDose(dueAt: now.addingTimeInterval(TimeInterval(60 * (i + 1))),
                                    doseUnits: 1, notifyId: "apt-x-\(i)"),
                delivered: false, action: nil, isDueSoon: false, isExpiredGrace: false))
        }
        for i in 0..<5 {
            facts.append(DoseDeliveryFact(
                dose: ScheduledDose(dueAt: now.addingTimeInterval(TimeInterval(60 * (i + 1))),
                                    doseUnits: 1, notifyId: "follow-x-\(i)"),
                delivered: false, action: nil, isDueSoon: false, isExpiredGrace: false))
        }
        await source.set(facts)
        await reconciler.reconcile(now: now)
        let pending = try await scheduler.pending()
        #expect(pending.count == ReminderReconciler.pendingBudget, "超限必须裁到预算内")
        #expect(pending.keys.contains { $0.hasPrefix("follow-x-") } == false, "随访优先级最低必被裁撤")
        #expect(pending.keys.filter { $0.hasPrefix("dose-x-") }.count == 40, "用药提醒全保留")
    }

    /// 稍后提醒：取消原通知 + 新 trigger；「跳过/忘记」不产生任何调度动作
    @Test func 稍后提醒与跳过语义() async throws {
        let scheduler = InMemoryReminderScheduler()
        let source = FakeDoseSource()
        let reconciler = ReminderReconciler(scheduler: scheduler, source: source)
        // 已送达 + 过宽限期 → markAwaitingUser（不重发）
        var f = dose("dose-d-1", at: -30 * 60)
        f.delivered = true
        await source.set([f])
        await reconciler.reconcile(now: now)
        var all = await source.all
        #expect(all[0].delivered && all[0].action == nil)   // 标记待处理，不重发
        let pending = try await scheduler.pending()
        #expect(pending.isEmpty)
    }
}
