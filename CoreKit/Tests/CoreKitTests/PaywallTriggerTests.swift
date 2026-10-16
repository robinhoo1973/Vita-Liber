import Foundation
import Testing
@testable import Domain

/// 订阅触发点与门槛状态（comercial V1.12，Linux 可跑）。
struct PaywallTriggerTests {

    @Test func newTriggersCodableRoundTrip() throws {
        for trigger in [PaywallTrigger.backupFirstTap, .syncFirstToggle, .shareFirstTap] {
            let decoded = try JSONDecoder().decode(PaywallTrigger.self, from: JSONEncoder().encode(trigger))
            #expect(decoded == trigger)
        }
    }

    @Test func hasBackupSyncShareFollowsPro() {
        #expect(!EntitlementState(ownedProducts: []).hasBackupSyncShare)
        #expect(EntitlementState(ownedProducts: [.proBase]).hasBackupSyncShare)
    }

    @Test func backupTriggerPaywallRules() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 未解锁 → 弹（价值触发）
        #expect(PaywallRules.shouldShow(trigger: .backupFirstTap, entitlementUnlocked: false, lastShownAt: nil, now: now))
        // 已解锁 → 不弹
        #expect(!PaywallRules.shouldShow(trigger: .backupFirstTap, entitlementUnlocked: true, lastShownAt: nil, now: now))
        // 24h 频控
        #expect(!PaywallRules.shouldShow(trigger: .backupFirstTap, entitlementUnlocked: false,
                                         lastShownAt: now.addingTimeInterval(-3600), now: now))
        // 频控窗口外 → 再弹
        #expect(PaywallRules.shouldShow(trigger: .backupFirstTap, entitlementUnlocked: false,
                                        lastShownAt: now.addingTimeInterval(-25 * 3600), now: now))
        // 三处新触发点同族
        for trigger in [PaywallTrigger.syncFirstToggle, PaywallTrigger.shareFirstTap] {
            #expect(PaywallRules.shouldShow(trigger: trigger, entitlementUnlocked: false, lastShownAt: nil, now: now))
        }
    }

    @Test func backupIsNotFreeRedLine() {
        // 备份本体订阅（comercial V1.12）——不在免费红线清单；
        // 免费红线（敏感媒体/提醒/搜索/急救卡等）仍 isFree，永不弹墙
        #expect(!FreeRedLine.isFree("backup"))
        for capability in FreeRedLine.capabilities {
            #expect(PaywallRules.isBlockable(capability) == false)
        }
    }
}
