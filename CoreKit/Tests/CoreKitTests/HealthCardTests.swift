import Foundation
import Testing
@testable import Domain

/// 健康信息卡 + 后处理填卡（结构轮 2026-09-15）：`HealthMetricCard` 的
/// InformationCard 契约、DeviceMetricRow 读侧装配、`HealthCardComposer`
/// 参考区间/引用式级别填充、`AlertRuleEngine.guidelineKey` 归一化单一事实源。
@Suite("SU-F16 · Apple 健康信息卡与后处理填卡")
struct HealthCardTests {

    private func row(metricKey: String = "heartRate", value: Double = 105,
                     unit: String = "bpm", sourceRef: String? = "hk:heartRate:123:") -> DeviceMetricRow {
        DeviceMetricRow(metricKey: metricKey, value: value, unit: unit,
                        valueMin: 100, valueMax: 110, sampleCount: 3,
                        sourceName: "Apple Watch", sourceVersion: "11.0",
                        sourceProduct: "watchOS", measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
                        sourceRef: sourceRef, sourceIdentifier: "com.apple.watch",
                        aggregation: .hourlyAverage)
    }

    private func guideline() -> GuidelineEntry {
        GuidelineEntry(title: "AHA 心率指南", org: "AHA", year: 2023, clauseRef: "§3.2",
                       citationUrl: "https://example.org", version: "v1", checkedAt: Date(),
                       metricKey: "heart_rate", unit: "bpm", l1Low: 60, l1High: 100,
                       l2Low: 50, l2High: 120, l3Low: 40, l3High: 140)
    }

    @Test("HealthMetricCard 满足 InformationCard 契约且 P9 溯源偏差成立")
    func cardConforms() {
        let card = HealthMetricCard.make(from: row(), kind: .heartRate, patientId: UUID())
        #expect(HealthMetricCard.cardType == "health_metric")
        #expect(card.source == .healthKit)
        #expect(card.confidence == 1.0)
        #expect(card.rawText == nil)          // HealthKit 无原文——溯源性由 sampleRef + 来源三键承担
        #expect(card.sampleRef == "hk:heartRate:123:")
        #expect(card.sourceName == "Apple Watch")
        #expect(!card.cardId.isEmpty)
    }

    @Test("读侧装配保持 metric_sample 事实行字段逐项映射")
    func makeFromRow() {
        let patientId = UUID()
        let card = HealthMetricCard.make(from: row(metricKey: "steps", value: 3_200, unit: "steps"),
                                         kind: .steps, patientId: patientId)
        #expect(card.patientId == patientId.uuidString)
        #expect(card.metricKey == "steps")
        #expect(card.value == 3_200)
        #expect(card.unit == "steps")
        #expect(card.valueMin == 100)
        #expect(card.sampleCount == 3)
        #expect(card.aggregation == .hourlyAverage)
        #expect(card.createdAt == card.measuredAt)
    }

    @Test("composer 填 B 级参考区间与引用式级别；无信源时级别 nil（范围不可用）")
    func composerFillsSlots() {
        let patientId = UUID()
        // 105 > l1High(100) → L1
        let elevated = HealthCardComposer.compose(row: row(), kind: .heartRate,
                                                  guideline: guideline(), patientId: patientId)
        #expect(elevated.severity == .L1)
        #expect(elevated.referenceRange?.grade == .B)
        #expect(elevated.referenceRange?.lower == 60)
        #expect(elevated.referenceRange?.upper == 100)

        // 无信源 → 范围不可用（nil），与 AlertRuleEngine 同语义
        let noGuideline = HealthCardComposer.compose(row: row(), kind: .heartRate,
                                                     guideline: nil, patientId: patientId)
        #expect(noGuideline.severity == nil)
        #expect(noGuideline.referenceRange == nil)
    }

    @Test("判定键归一化单一事实源：restingHeartRate → heart_rate，其余原样")
    func guidelineKeyNormalization() {
        #expect(AlertRuleEngine.guidelineKey(for: "restingHeartRate") == "heart_rate")
        #expect(AlertRuleEngine.guidelineKey(for: "heartRate") == "heartRate")
        #expect(AlertRuleEngine.guidelineKey(for: "bloodOxygen") == "bloodOxygen")
    }
}
