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
}
