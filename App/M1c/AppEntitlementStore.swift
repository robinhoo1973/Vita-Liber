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
    private let logger = Logger(subsystem: "com.vitaliber", category: "entitlement")

    init(store: EntitlementStore) { self.store = store }

    func load() async {
        do {
            let state = try await store.state()
            owned = state.ownedProducts
            aiMonthlyUsed = state.aiMonthlyUsed
        } catch {
            logger.error("权益加载失败: \(error)")
        }
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
    }

    func recordAIUse() async {
        do {
            try await store.recordAIUse()
            aiMonthlyUsed += 1
        } catch {
            logger.error("AI 额度计数失败: \(error)")
        }
    }
}
