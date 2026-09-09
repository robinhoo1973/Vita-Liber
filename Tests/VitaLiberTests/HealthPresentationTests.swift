import XCTest
import Foundation
import Domain
@testable import VitaLiber

// binds: SU-M2-F16, SU-M15-L10N
@MainActor
final class HealthPresentationTests: XCTestCase {
    func test_sixHealthTypesAndEverySleepStageHaveVisibleMetricNames() throws {
        let cases: [(kind: HealthDataKind, metrics: [(raw: String, type: MetricType, english: String)])] = [
            (.heartRate, [("heart_rate", .heartRate, "Heart rate")]),
            (.restingHeartRate, [("restingHeartRate", .restingHeartRate, "Resting heart rate")]),
            (.bloodOxygen, [("blood_oxygen", .bloodOxygen, "Blood oxygen")]),
            (.respiratoryRate, [("respiratory_rate", .respiratoryRate, "Respiratory rate")]),
            (.steps, [("steps", .steps, "Steps")]),
            (.sleep, [
                ("sleep_total", .sleepTotal, "Total sleep duration"),
                ("sleep_deep", .sleepDeep, "Deep sleep duration"),
                ("sleep_rem", .sleepREM, "REM sleep duration"),
                ("sleep_awake", .sleepAwake, "Awake time in sleep window"),
                ("sleep_core", .sleepCore, "Core sleep duration"),
                ("sleep_unspecified", .sleepUnspecified, "Unspecified sleep duration")
            ])
        ]
        XCTAssertEqual(cases.count, 6)
        XCTAssertEqual(Set(cases.map { $0.kind.rawValue }), Set(HealthDataKind.allCases.map(\.rawValue)))
        try forEachLanguage { language, bundle in
            var labels: [String] = []
            for item in cases.flatMap(\.metrics) {
                let key = "metric.name.\(item.type.rawValue)"
                let expected = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertFalse(expected.isEmpty)
                XCTAssertNotEqual(expected, key, "\(language):\(key)")
                XCTAssertEqual(L10n.metricName(item.type), expected)
                XCTAssertEqual(L10n.healthMetricName(item.raw), expected)
                XCTAssertEqual(L10n.healthMetricName(item.type.rawValue), expected)
                if language == "en" { XCTAssertEqual(expected, item.english) }
                labels.append(expected)
            }
            XCTAssertEqual(Set(labels).count, labels.count, "Different metrics must remain distinguishable")
        }
    }

    func test_aggregationLabelsDistinguishSamplesAveragesTotalsAndDurations() throws {
        let cases: [(MetricAggregation, String)] = [
            (.sample, "Individual reading"), (.hourlyAverage, "Hourly average"),
            (.dailySum, "Daily total"), (.sleepDuration, "Duration in sleep window")
        ]
        try forEachLanguage { language, bundle in
            var labels: [String] = []
            for (aggregation, english) in cases {
                let key = "health.aggregation.\(aggregation.rawValue)"
                let label = L10n.healthAggregation(aggregation)
                XCTAssertTrue(L10n.registeredKeys.contains(key))
                XCTAssertEqual(label, bundle.localizedString(forKey: key, value: nil, table: nil))
                XCTAssertFalse(label.isEmpty)
                XCTAssertNotEqual(label, key)
                if language == "en" { XCTAssertEqual(label, english) }
                labels.append(label)
            }
            XCTAssertEqual(Set(labels).count, cases.count)
        }
    }

    func test_unknownMetricsUseALocalizedFallbackInsteadOfStorageKeys() throws {
        try forEachLanguage { _, bundle in
            let fallback = bundle.localizedString(forKey: "health.metric.unknown", value: nil, table: nil)
            XCTAssertFalse(fallback.isEmpty)
            XCTAssertNotEqual(fallback, "health.metric.unknown")
            for key in ["", "custom_metric", "heart_rate_unrecognized"] {
                XCTAssertEqual(L10n.healthMetricName(key), fallback)
                XCTAssertTrue(L10n.gsDetailMetric(key).contains(fallback))
                if !key.isEmpty { XCTAssertFalse(L10n.gsDetailMetric(key).contains(key)) }
            }
        }
    }

    func test_deviceEvidenceKeepsItsOriginAndLocalizesMetricNames() throws {
        try forEachLanguage { _, _ in
            XCTAssertEqual(L10n.alertOriginName("device"), L10n.trendOriginDevice)
            XCTAssertEqual(L10n.alertOriginName("hospital"), L10n.trendOriginHospital)
            XCTAssertEqual(L10n.alertOriginName("manual"), L10n.trendSelfMeasured)
            XCTAssertNotEqual(L10n.alertOriginName("device"), L10n.alertOriginName("manual"))
            XCTAssertNotEqual(L10n.alertOriginName("device"), L10n.trendOriginSelfDevice)
            let facts = L10n.alertEvidenceFacts(L10n.healthMetricName("blood_oxygen"), "97.5", "%",
                                               L10n.alertOriginName("device"), "2026-09-09 10:15")
            for value in [L10n.metricName(.bloodOxygen), "97.5", "%", L10n.trendOriginDevice, "2026-09-09 10:15"] {
                XCTAssertTrue(facts.contains(value))
            }
            XCTAssertFalse(facts.contains("blood_oxygen"))
            XCTAssertTrue(L10n.gsDetailMetric("heart_rate").contains(L10n.metricName(.heartRate)))
            XCTAssertFalse(L10n.gsDetailMetric("heart_rate").contains("heart_rate"))
        }
    }

    func test_healthFormatsInterpolateArgumentsWithoutTruncatingCounts() throws {
        let count = 4_294_967_300
        let placeholder = try NSRegularExpression(pattern: #"%(?:[0-9]+\$)?(?:ld|d|@)"#)
        try forEachLanguage { language, _ in
            let cases: [(text: String, arguments: [String])] = [
                (L10n.healthImportSubject("Alex 100%"), ["Alex 100%"]),
                (L10n.healthImportSubject(L10n.commonMember), [L10n.commonMember]),
                (L10n.healthImportPartial(2), ["2"]),
                (L10n.healthWindowEnd("2026-09-09 10:15"), ["2026-09-09 10:15"]),
                (L10n.healthWindowStatistics("51.25", "103.75", count), ["51.25", "103.75", String(count)]),
                (L10n.f16SyncedRows(count), [String(count)]),
                (L10n.f16SyncDone(count), [String(count)]),
                (L10n.f16NoRange(count), [String(count)]),
                (L10n.f16LastSync("2026-09-09 10:15"), ["2026-09-09 10:15"])
            ]
            for item in cases {
                for argument in item.arguments { XCTAssertTrue(item.text.contains(argument), item.text) }
                XCTAssertNil(placeholder.firstMatch(in: item.text, range: NSRange(item.text.startIndex..., in: item.text)))
            }
            if language == "en" {
                XCTAssertEqual(L10n.healthWindowStatistics("51.25", "103.75", 4),
                               "Window minimum 51.25, maximum 103.75; 4 samples")
                XCTAssertEqual(L10n.f16SyncDone(0),
                               "Alert notifications scheduled in this sync: 0 (not confirmed delivered)")
                XCTAssertEqual(L10n.f16SyncedRows(3), "Metric records added, updated or removed in this sync: 3")
            }
        }
    }

    func test_healthKeysAndPrintfContractsMatchAllThreeLanguages() throws {
        let contracts: [String: [String]] = [
            "health.importSubject": ["%@"], "health.importPartial": ["%ld"],
            "health.windowEnd": ["%@"], "health.windowStatistics": ["%1$@", "%2$@", "%3$ld"],
            "f16.syncDoneFmt": ["%ld"], "f16.syncedRowsFmt": ["%ld"],
            "f16.noRangeFmt": ["%ld"], "f16.lastSyncFmt": ["%@"]
        ]
        let placeholder = try NSRegularExpression(pattern: #"%(?:[0-9]+\$)?(?:ld|d|@)"#)
        var baselineKeys: Set<String>?
        try forEachLanguage { language, bundle in
            let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
            let strings = try XCTUnwrap(try PropertyListSerialization.propertyList(
                from: Data(contentsOf: url), options: [], format: nil) as? [String: String])
            let keys = Set(strings.keys)
            if let baselineKeys { XCTAssertEqual(keys, baselineKeys, language) }
            else { baselineKeys = keys }
            let staticValues: [(String, String)] = [
                ("common.member", L10n.commonMember),
                ("health.noReadableData", L10n.healthNoReadableData),
                ("health.importMore", L10n.healthImportMore),
                ("health.notificationRetry", L10n.healthNotificationRetry),
                ("health.medicalReviewPending", L10n.healthMedicalReviewPending),
                ("health.showLegacy", L10n.healthShowLegacy),
                ("health.historicalEvaluation", L10n.healthHistoricalEvaluation),
                ("health.loadMore", L10n.healthLoadMore),
                ("health.openHelp", L10n.healthOpenHelp)
            ]
            for (key, value) in staticValues {
                XCTAssertEqual(value, strings[key])
                XCTAssertFalse(value.isEmpty)
                XCTAssertNotEqual(value, key)
            }
            let healthKeys = keys.filter { $0.hasPrefix("health.") || $0.hasPrefix("f16.") }
            let required = Set(healthKeys).union(staticValues.map { $0.0 }).union(contracts.keys)
                .union(MetricType.allCases.map { "metric.name.\($0.rawValue)" })
            XCTAssertTrue(required.isSubset(of: Set(L10n.registeredKeys)))
            XCTAssertTrue(required.isSubset(of: keys))
            for (key, expected) in contracts {
                let text = try XCTUnwrap(strings[key])
                let matches = placeholder.matches(in: text, range: NSRange(text.startIndex..., in: text))
                let tokens = matches.map { (text as NSString).substring(with: $0.range) }
                XCTAssertEqual(tokens, expected, "\(language):\(key)")
            }
        }
    }

    private func forEachLanguage(_ check: (String, Bundle) throws -> Void) throws {
        let previous = L10n.bundleLanguage
        let stored = UserDefaults.standard.string(forKey: "vl.language")
        defer {
            L10n.setLanguage(previous)
            UserDefaults.standard.set(stored, forKey: "vl.language")
        }
        for language in L10n.supportedLocalizations {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            L10n.setLanguage(language)
            try check(language, bundle)
        }
    }
}
