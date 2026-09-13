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

    /// round2 H-N1：两道谓词以样本 end 在 cutoff 处互补——end 恰等于 cutoff 归 recent（默认左闭），
    /// history 用 .strictEndDate 右开排除；边界样本恰出现一次，两道合并覆盖全部样本。
    /// 与 Domain `HealthFetchScope.matches` 必须一致（HealthFetchScopeTests 本机钉死同一边界）。
    func test_changePredicatesPartitionSamplesOnEndDateAtCutoff() {
        let cutoff = Date(timeIntervalSince1970: 1_700_006_400)
        let type = HKQuantityType(.stepCount)
        let straddling = HKQuantitySample(type: type, quantity: HKQuantity(unit: .count(), doubleValue: 1),
            start: cutoff.addingTimeInterval(-3600), end: cutoff)
        let older = HKQuantitySample(type: type, quantity: HKQuantity(unit: .count(), doubleValue: 1),
            start: cutoff.addingTimeInterval(-7200), end: cutoff.addingTimeInterval(-1))
        let newer = HKQuantitySample(type: type, quantity: HKQuantity(unit: .count(), doubleValue: 1),
            start: cutoff, end: cutoff.addingTimeInterval(60))
        let recentScope = HealthFetchScope(lane: .recent, cutoff: cutoff)
        let historyScope = HealthFetchScope(lane: .history, cutoff: cutoff)
        let recent = HealthKitReader.changePredicate(for: recentScope)
        let history = HealthKitReader.changePredicate(for: historyScope)
        for sample in [straddling, older, newer] {
            let reference = HealthSampleReference(id: sample.uuid, kind: .steps, sourceID: "s",
                                                  start: sample.startDate, end: sample.endDate)
            XCTAssertEqual(recent.evaluate(with: sample), recentScope.matches(reference), "recent 谓词与 Domain 分道判定必须一致")
            XCTAssertEqual(history.evaluate(with: sample), historyScope.matches(reference), "history 谓词与 Domain 分道判定必须一致")
            XCTAssertNotEqual(recent.evaluate(with: sample), history.evaluate(with: sample), "每个样本恰属一道")
        }
        XCTAssertTrue(recent.evaluate(with: straddling))
        XCTAssertFalse(history.evaluate(with: straddling))
        XCTAssertFalse(recent.evaluate(with: older))
        XCTAssertTrue(history.evaluate(with: older))
    }
}
#endif
