import Foundation
import SwiftUI
import os
import Domain
import Infrastructure
import Protocols

/// SP-61 权益状态仓（@Observable）：桥接 Infrastructure 的 EntitlementStore actor。
/// 生产 StoreKit 2 接线为 L2 部署项（App Store Connect 配置后注入 Transaction.updates），
/// M1c 以 InMemoryStorefront 桩承载全部逻辑路径，可全量单测。
@MainActor
@Observable
final class AppEntitlementStore {
    private(set) var owned: Set<ProductID> = []
    private(set) var aiMonthlyUsed = 0
    private(set) var lastShownAt: [PaywallTrigger: Date] = [:]
    private let store: EntitlementStore
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.vitaliber", category: "entitlement")

    init(store: EntitlementStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        restoreShownAt()
    }

    func load() async {
        do {
            let state = try await store.state()
            owned = state.ownedProducts
            aiMonthlyUsed = state.aiMonthlyUsed
        } catch {
            logger.error("权益加载失败: \(error)")
        }
    }

    /// 免费档 AI 额度是否用尽（comercial §2.3：免费 20 次/月）
    var aiQuotaExhausted: Bool {
        !owned.contains(.proBase) && aiMonthlyUsed >= FreeQuota().aiMonthlyUses
    }

    // MARK: - 24h 频控持久化（comercial §3：跨启动频控不得失效）

    private func restoreShownAt() {
        guard let data = defaults.data(forKey: "vl.paywall.lastShownAt") else { return }
        guard let dict = try? JSONDecoder().decode([String: Double].self, from: data) else { // try?-ok: 历史版本解码失败 → 频控归零（宁可多提示一次，不静默阻断付费入口）
            return
        }
        var out: [PaywallTrigger: Date] = [:]
        for (key, ts) in dict {
            if let trigger = PaywallTrigger(rawValue: key) {
                out[trigger] = Date(timeIntervalSince1970: ts)
            }
        }
        lastShownAt = out
    }

    private func persistShownAt() {
        let dict = lastShownAt.mapValues { $0.timeIntervalSince1970 }
        guard let data = try? JSONEncoder().encode(dict) else { return }   // try?-ok: 编码失败=本次频控不持久化，不阻断弹墙
        defaults.set(data, forKey: "vl.paywall.lastShownAt")
    }

    func purchase(_ product: ProductID) async -> Bool {
        do {
            let ok = try await store.purchase(product)
            if ok { owned.insert(product) }
            return ok
        } catch {
            logger.error("购买失败: \(error)")
            return false
        }
    }

    func restore() async {
        do {
            owned = try await store.restore()
        } catch {
            logger.error("恢复购买失败: \(error)")
        }
    }

    /// 五时机弹墙调度（comercial §3）：价值触发 + 24h 频控 + 反向约束
    func shouldShowPaywall(trigger: PaywallTrigger, now: Date = Date()) -> Bool {
        PaywallRules.shouldShow(trigger: trigger,
                                entitlementUnlocked: owned.contains(.proBase),
                                lastShownAt: lastShownAt[trigger], now: now)
    }

    func markShown(trigger: PaywallTrigger, at: Date = Date()) {
        lastShownAt[trigger] = at
        persistShownAt()
    }

    func recordAIUse() async {
        do {
            try await store.recordAIUse()
            aiMonthlyUsed += 1
        } catch {
            logger.error("AI 额度计数失败: \(error)")
        }
    }

    // MARK: - 五时机触发接线（comercial §3 / M2 收尾）

    /// 触发点接线标准入口：价值触发 + 24h 频控 + 反向约束全在 Domain
    /// `PaywallRules`，本方法只是把它接到「弹墙」这个 UI 动作上。
    /// - Returns: true = 已弹墙（调用方应跳过原动作——proOutput/cloudSync
    ///   的语义是「先解锁再用」，AI 额度的语义是「额度用尽不给答」）
    @MainActor
    func evaluateTrigger(_ trigger: PaywallTrigger, now: Date = Date()) -> Bool {
        guard shouldShowPaywall(trigger: trigger, now: now) else { return false }
        markShown(trigger: trigger, at: now)
        pendingPaywallTrigger = trigger
        return true
    }

    /// 当前待展示的弹墙触发器（PaywallHost 观察）
    private(set) var pendingPaywallTrigger: PaywallTrigger?
    func clearPendingPaywall() { pendingPaywallTrigger = nil }
}
