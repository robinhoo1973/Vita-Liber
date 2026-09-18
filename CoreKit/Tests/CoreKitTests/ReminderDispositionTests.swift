import Foundation
import Testing
@testable import Domain

// binds: SU-M1c-REGRESSION — TC-M1c-09（FR2.1⑦ / FR14.8 / BR-003 / BR-004）
@Suite("FR2.1⑦ 首页按源动作表与通知键")
struct ReminderDispositionTests {
    private func item(_ kind: String, id: String = "S1", priority: Int = 0, status: String? = nil) -> AggregatedReminderItem {
        AggregatedReminderItem(id: .init(kind: kind, sourceId: id), aggregationKind: .medication,
                               occurredAt: Date(), title: "t", priority: priority, status: status)
    }

    /// 动作表金样（显式类型，避免异构元组字面量推断歧义）
    static let table: [(kind: String, priority: Int, status: String?, expected: [ReminderDisposition])] = [
        ("dose_slot", 1, "pending", [.markTaken, .snoozeDose, .skipDose]),
        ("dose_slot", 0, "taken", []), ("dose_slot", 0, "resolved", []),
        ("refill", 0, nil, [.openCabinet, .snoozeUntilTomorrow, .archive]),
        ("stock_backlog", 0, nil, [.openCabinet, .snoozeUntilTomorrow, .archive]),
        ("appointment", 0, nil, [.archive]),
        ("alert_event", 2, "L2", [.viewEvidence]),
        ("ocr", 2, nil, [.view]), ("ocr", 0, nil, [.snoozeUntilTomorrow]),
        ("pending_card", 0, "pending", [.resumePendingCard, .snoozeUntilTomorrow]),
        ("profile_progress", 0, nil, [])
    ]

    @Test(arguments: table)
    /// 原名：按源动作表
    func dispositionBySourceActionTable(_ row: (kind: String, priority: Int, status: String?, expected: [ReminderDisposition])) {
        #expect(ReminderAggregationCenter.dispositions(for: item(row.kind, priority: row.priority, status: row.status)) == row.expected)
    }

    /// 原名：任何源都不归档用药且医疗动作只有三项
    @Test func noSourceArchivesMedicationAndMedicalActionsAreThree() {
        #expect(!ReminderAggregationCenter.dispositions(for: item("dose_slot", status: "pending")).contains(.archive))
        #expect(ReminderDisposition.allCases.filter(\.isMedicalAction) == [.markTaken, .snoozeDose, .skipDose])
    }

    /// 原名：全滑仅对纯信息行的稍后或归档开放
    @Test func fullSwipeOnlyForInfoRowsSnoozeOrArchive() {
        let dose = item("dose_slot", priority: 1, status: "pending")
        #expect(!ReminderAggregationCenter.allowsFullSwipe(for: dose, side: .trailing))
        #expect(!ReminderAggregationCenter.allowsFullSwipe(for: dose, side: .leading))
        #expect(!ReminderAggregationCenter.allowsFullSwipe(for: item("alert_event", priority: 2, status: "L1"), side: .trailing))
        #expect(!ReminderAggregationCenter.allowsFullSwipe(for: item("ocr", priority: 2), side: .trailing))
        #expect(ReminderAggregationCenter.allowsFullSwipe(for: item("appointment"), side: .trailing))
        #expect(ReminderAggregationCenter.allowsFullSwipe(for: item("refill"), side: .trailing))
        #expect(!ReminderAggregationCenter.allowsFullSwipe(for: item("refill"), side: .leading))
    }

    @Test(arguments: [("alert_event", "alert-X"), ("appointment", "apt-X"), ("refill", "lot-X"), ("dose_slot", "dose-X"),
                      ("ocr", "ocr-X"), ("stock_backlog", "stock_backlog-X"), ("pending_card", "pending_card-X")])
    /// 原名：通知键与通知中心同命名空间
    func notificationKeysShareCenterNamespace(_ kind: String, _ expected: String) {
        #expect(NotificationItemKey.key(kind: kind, sourceId: "X") == expected)
    }

    /// 原名：次日键按自然日派生
    @Test func tomorrowKeyDerivesFromCalendarDay() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00Z
        #expect(NotificationItemKey.snoozedUntilTomorrowKey("lot-L", now: day, calendar: cal) == "lot-L@2027-1-15")
        #expect(NotificationItemKey.snoozedUntilTomorrowKey("lot-L", now: day.addingTimeInterval(86_400), calendar: cal) == "lot-L@2027-1-16")
    }

    /// 原名：隐藏键集_用药与逾期OCR不可被任何键隐藏
    @Test func hideKeysMedicationAndOverdueOCRUnhidable() {
        let now = Date()
        #expect(NotificationItemKey.hideKeys(for: item("dose_slot", status: "pending"), now: now).isEmpty)
        #expect(NotificationItemKey.hideKeys(for: item("ocr", priority: 2), now: now).isEmpty)
        #expect(NotificationItemKey.hideKeys(for: item("profile_progress"), now: now).isEmpty)
        #expect(NotificationItemKey.hideKeys(for: item("alert_event", id: "A", priority: 2), now: now) == ["alert-A"])
        let refill = NotificationItemKey.hideKeys(for: item("refill", id: "L"), now: now)
        #expect(refill.count == 2 && refill[0] == "lot-L" && refill[1].hasPrefix("lot-L@"))
        #expect(NotificationItemKey.hideKeys(for: item("pending_card", id: "C"), now: now).allSatisfy { $0.hasPrefix("pending_card-C@") })
        #expect(NotificationItemKey.writeKey(for: item("appointment", id: "A"), disposition: .archive, now: now) == "apt-A")
        #expect(NotificationItemKey.writeKey(for: item("refill", id: "L"), disposition: .snoozeUntilTomorrow, now: now)?.hasPrefix("lot-L@") == true)
        #expect(NotificationItemKey.writeKey(for: item("dose_slot", status: "pending"), disposition: .markTaken, now: now) == nil)
    }
}
