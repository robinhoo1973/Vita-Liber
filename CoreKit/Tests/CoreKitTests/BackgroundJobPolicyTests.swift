import Foundation
import Testing
@testable import Domain

/// round5 Q2（业主 2026-09-20 第 2 项：Apple 健康同步仍少、后台不稳）：后台吞吐此前结构性受限——只用 30 秒级
/// `BGAppRefreshTask`、每次唤醒每类只排 1 页；`processing` 模式声明了却没用。`BackgroundJobPolicy` 是调度门面的
/// 纯策略层：作业种类/系统要求/预算与「是否值得申请一次处理任务」全部可测；OS 原语调用在 Infrastructure。
@Suite("SU-M2-HEALTHSYNC · 后台作业策略")
struct BackgroundJobPolicyTests {
    @Test func jobKindsMapToPlatformRequirements() {
        let refresh = BackgroundJobDescriptor(identifier: "x.refresh", kind: .refresh, minimumInterval: 15 * 60)
        #expect(refresh.kind.requiresNetwork == false && refresh.kind.requiresExternalPower == false)
        let processing = BackgroundJobDescriptor(identifier: "x.backfill",
                                                 kind: .processing(requiresNetwork: false, requiresExternalPower: true),
                                                 minimumInterval: 60 * 60)
        #expect(processing.kind.requiresExternalPower && !processing.kind.requiresNetwork)
    }

    @Test func nextEarliestBeginIsNowPlusMinimumInterval() {
        let job = BackgroundJobDescriptor(identifier: "x", kind: .refresh, minimumInterval: 900)
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(job.earliestBeginDate(from: now) == Date(timeIntervalSince1970: 1_900))
    }

    @Test func runBudgetLeavesCompletionMargin() {
        // 系统给到期时间 → 作业预算 = 到期 − 现在 − 完成余量（落盘/回报需时），且不为负
        let now = Date(timeIntervalSince1970: 0)
        let expiry = now.addingTimeInterval(290)
        #expect(BackgroundJobPolicy.runBudget(now: now, expiresAt: expiry) == .seconds(290 - BackgroundJobPolicy.completionMarginSeconds))
        #expect(BackgroundJobPolicy.runBudget(now: now, expiresAt: now.addingTimeInterval(3)) == .seconds(0))
        // 无到期信息（系统未给）→ 保守默认（processing 类实测 ≈5 分钟上限）
        #expect(BackgroundJobPolicy.runBudget(now: now, expiresAt: nil) == BackgroundJobPolicy.defaultProcessingBudget)
    }

    // MARK: HealthKit 回填：何时申请处理任务、每轮多少页

    @Test func backlogRequestsProcessingOnlyWhenWindowsRemain() {
        #expect(HealthSyncBacklogPolicy.shouldRequestProcessing(remainingWindows: 0, hasMore: false) == false)
        #expect(HealthSyncBacklogPolicy.shouldRequestProcessing(remainingWindows: 12, hasMore: false) == true)
        #expect(HealthSyncBacklogPolicy.shouldRequestProcessing(remainingWindows: 0, hasMore: true) == true)
        #expect(HealthSyncBacklogPolicy.shouldRequestProcessing(remainingWindows: nil, hasMore: false) == false)
    }

    @Test func backlogRoundsScaleWithBudgetButStayBounded() {
        // 每轮（每类 1 页 + ≤32 窗）经验 ≈1.5s：5 分钟预算 → 200 轮上限封顶；30 秒 → 20
        #expect(HealthSyncBacklogPolicy.maxRounds(for: .seconds(300)) == HealthSyncBacklogPolicy.roundsCap)
        #expect(HealthSyncBacklogPolicy.maxRounds(for: .seconds(30)) == 20)
        #expect(HealthSyncBacklogPolicy.maxRounds(for: .seconds(0)) == 1)
    }

    @Test func foregroundActiveRoundsAreSmallButMoreThanOne() {
        // 回前台轻量对账：此前 1 轮（每类 1 页）；改 3 轮——仍有界（30s 预算内），但不再「每次回前台只前进一页」
        #expect(HealthSyncBacklogPolicy.foregroundActiveRounds == 3)
    }
}
