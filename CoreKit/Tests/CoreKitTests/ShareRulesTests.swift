import Foundation
import Testing
@testable import Domain

/// 分级分享包规则（FR13.13/function V4.22，Linux 可跑）。
struct ShareRulesTests {

    @Test func tierSensitivityOrder() {
        #expect(ShareTier.notification.sensitivityRank < ShareTier.summary.sensitivityRank)
        #expect(ShareTier.summary.sensitivityRank < ShareTier.card.sensitivityRank)
        #expect(ShareTier.card.sensitivityRank < ShareTier.original.sensitivityRank)
    }

    @Test func defaultExpiryPerTier() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day = 24.0 * 3600
        #expect(ShareExpiryRules.defaultExpiry(tier: .notification, now: now)
                == now.addingTimeInterval(90 * day))
        #expect(ShareExpiryRules.defaultExpiry(tier: .summary, now: now)
                == now.addingTimeInterval(90 * day))
        #expect(ShareExpiryRules.defaultExpiry(tier: .card, now: now)
                == now.addingTimeInterval(7 * day))
        #expect(ShareExpiryRules.defaultExpiry(tier: .original, now: now)
                == now.addingTimeInterval(7 * day))
    }

    @Test func expiryClampedToTierCap() {
        // 卡片/原件级上限 90 天：申请 200 天 → 钳到「当下 + 90 天」（上限自发起起算，裁决 C2）。
        // 此断言此前以纪元偏移量核对（clamped 塌到 1970 纪元附近也通过）——改为相对 now 核验。
        let tier = ShareTier.card
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let over = now.addingTimeInterval(200 * 24 * 3600)
        let clamped = ShareExpiryRules.clamped(over, tier: tier, now: now)
        let capDays = clamped.timeIntervalSince(now) / (24 * 3600)
        #expect(abs(capDays - 90) < 0.01)
        // 过去时间 → 钳到当下
        #expect(ShareExpiryRules.clamped(Date(timeIntervalSince1970: 100), tier: tier, now: now) >= now)
        // 钳制结果必须仍在未来（原实现恒返回 1970 纪元：发出即过期）
        #expect(!ShareExpiryRules.isExpired(clamped, now: now))
    }

    @Test func expiredDetection() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ShareExpiryRules.isExpired(now.addingTimeInterval(-1), now: now))
        #expect(!ShareExpiryRules.isExpired(now.addingTimeInterval(1), now: now))
    }

    @Test func medicationNameLevels() {
        #expect(!ShareRules.summaryAllowsMedicationNames(.timeAndStatusOnly))
        #expect(ShareRules.summaryAllowsMedicationNames(.withNames))
        #expect(ShareRules.summaryAllowsMedicationNames(.withNamesAndDosage))
        #expect(!ShareRules.summaryAllowsDosage(.withNames))
        #expect(ShareRules.summaryAllowsDosage(.withNamesAndDosage))
        // 通知级恒不含药名（FR24.4 口径）
        #expect(!ShareRules.notificationAllowsMedicationNames(.withNamesAndDosage))
    }

    @Test func dGradeExcluded() {
        // BR-003 显式条款：D 级（机器识别未确认）绝不参与分享
        #expect(ShareRules.excludesUnconfirmed(grade: "D"))
        #expect(!ShareRules.excludesUnconfirmed(grade: "C"))
        #expect(!ShareRules.excludesUnconfirmed(grade: "A"))
    }

    @Test func selectionCodableRoundTrip() throws {
        let selection = ShareSelection(tier: .summary,
                                       medicationNameLevel: .withNames,
                                       expiry: Date(timeIntervalSince1970: 1_700_000_000),
                                       selectedCardIds: [UUID()],
                                       selectedDocumentIds: [UUID(), UUID()])
        let decoded = try JSONDecoder().decode(ShareSelection.self, from: JSONEncoder().encode(selection))
        #expect(decoded == selection)
    }
}
