#if os(iOS)
import XCTest
import Foundation
import HealthKit
import Domain
@testable import Infrastructure

// binds: SU-M2-F16
final class HealthKitReaderPredicateTests: XCTestCase {
    func test_stepStatisticsExcludeSamplesArrivingAfterIdentityEnumeration() {
        let start = Date(timeIntervalSince1970: 1_700_006_400)
        let window = HealthImportWindow(kind: .steps, start: start, end: start.addingTimeInterval(86400))
        let type = HKQuantityType(.stepCount)
        let enumerated = HKQuantitySample(type: type, quantity: HKQuantity(unit: .count(), doubleValue: 100),
            start: start.addingTimeInterval(60), end: start.addingTimeInterval(120))
        let lateArrival = HKQuantitySample(type: type, quantity: HKQuantity(unit: .count(), doubleValue: 200),
            start: enumerated.startDate, end: enumerated.endDate)
        let outside = HKQuantitySample(type: type, quantity: HKQuantity(unit: .count(), doubleValue: 300),
            start: window.end.addingTimeInterval(60), end: window.end.addingTimeInterval(120))
        let predicate = HealthKitReader.stepStatisticsPredicate(for: window, sampleIDs: [enumerated.uuid, outside.uuid])
        XCTAssertTrue(predicate.evaluate(with: enumerated))
        XCTAssertFalse(predicate.evaluate(with: lateArrival), "A persisted total cannot acquire an unindexed contributor")
        XCTAssertFalse(predicate.evaluate(with: outside))
    }
}
#endif
