import Foundation
import Testing
@testable import Domain

/// M1c 商业化（comercial V1.5 / tech §5.14）——Domain 规则验收
@Suite("M1c · 付费墙五时机与红线（comercial §2/§3）")
struct PaywallTests {
    @Test func 五时机弹墙矩阵() {
        let now = Date()
        // 未解锁 → 弹
        #expect(PaywallRules.shouldShow(trigger: .proOutputFirstTap, entitlementUnlocked: false,
                                        lastShownAt: nil, now: now))
        // 已解锁 → 不弹
        #expect(!PaywallRules.shouldShow(trigger: .proOutputFirstTap, entitlementUnlocked: true,
                                         lastShownAt: nil, now: now))
        // 24h 频控 → 不弹
        #expect(!PaywallRules.shouldShow(trigger: .memberQuotaReached, entitlementUnlocked: false,
                                         lastShownAt: now.addingTimeInterval(-3600), now: now))
        // 24h 过后 → 再弹
        #expect(PaywallRules.shouldShow(trigger: .memberQuotaReached, entitlementUnlocked: false,
                                        lastShownAt: now.addingTimeInterval(-25 * 3600), now: now))
    }

    @Test func 免费红线能力不可禁用() {
        for cap in ["sensitiveProtection", "offline", "medicationReminder", "refillAlert",
                    "basicHealthAlert", "search", "careMode", "emergencyCard",
                    "helpDiagnostics", "voiceInput", "allergyRecord"] {
            #expect(!PaywallRules.isBlockable(cap), "红线能力 \(cap) 永不可被付费墙禁用")
        }
        #expect(PaywallRules.isBlockable("proOutput"))
    }

    @Test func 额度判定() {
        let quota = FreeQuota()
        var state = EntitlementState(memberCount: 5)
        #expect(state.quotaExceeded(quota) == .memberQuotaReached)
        state = EntitlementState(aiMonthlyUsed: 20, memberCount: 3)
        #expect(state.quotaExceeded(quota) == .aiQuotaExhausted)
        state = EntitlementState(ownedProducts: [.proBase], aiMonthlyUsed: 30, memberCount: 6)
        #expect(state.quotaExceeded(quota) == nil)   // 已购 Pro 不受免费额度限制
    }

    @Test func 信任文案固定() {
        #expect(PaywallRules.trustCopy.contains("不续费不会删除你的任何数据"))
    }
}
