import Foundation
import Testing
@testable import Domain

/// 写回 Apple 健康资格规则（业主 2026-09-17 定：单位不符即跳过、不换算不猜单位；
/// 导入侧指标不可写——防回声不在资格层开口子）。
@Suite("SU-FR16.1 · 写回资格（可写表 / 单位匹配 / 非法值）")
struct HealthWriteBackTests {

    @Test("可写表：六类手输指标各配规范单位；导入侧与编码键不可写")
    func 可写表() {
        let table: [(MetricType, String)] = [
            (.bloodPressureSys, "mmHg"), (.bloodPressureDia, "mmHg"),
            (.glucose, "mg/dL"), (.weight, "kg"), (.temperature, "°C"),
            (.heartRate, "bpm"), (.bloodOxygen, "%")
        ]
        for (metric, unit) in table {
            #expect(HealthWriteBack.canonicalUnit(for: metric.rawValue) == unit, "\(metric) → \(unit)")
        }
        // 导入侧/睡眠/编码键不可写（防回声：不把导入的数据再写回去）
        #expect(HealthWriteBack.canonicalUnit(for: MetricType.restingHeartRate.rawValue) == nil)
        #expect(HealthWriteBack.canonicalUnit(for: MetricType.steps.rawValue) == nil)
        #expect(HealthWriteBack.canonicalUnit(for: MetricType.sleepTotal.rawValue) == nil)
        #expect(HealthWriteBack.canonicalUnit(for: "code.8480-6") == nil, "编码键不可写")
    }

    @Test("单位逐字匹配：trim 与全角 ℃ 归一；mmol/L 刻意拒绝（不换算）")
    func 单位匹配() {
        #expect(HealthWriteBack.isWritable(metric: MetricType.temperature.rawValue, unit: " ℃ ", value: 37.2),
                "全角 ℃ + 空格 → 归一后匹配")
        #expect(!HealthWriteBack.isWritable(metric: MetricType.glucose.rawValue, unit: "mmol/L", value: 5.6),
                "mmol/L 不做换算、跳过（诚实纪律优先于覆盖）")
        #expect(HealthWriteBack.isWritable(metric: MetricType.glucose.rawValue, unit: "mg/dL", value: 100))
        #expect(!HealthWriteBack.isWritable(metric: MetricType.weight.rawValue, unit: "斤", value: 60),
                "非常规单位跳过")
        #expect(!HealthWriteBack.isWritable(metric: MetricType.bloodPressureSys.rawValue, unit: "kPa", value: 120),
                "血压 kPa 跳过（不换算）")
    }

    @Test("非法值不可写；未知指标不可写")
    func 非法值() {
        #expect(!HealthWriteBack.isWritable(metric: MetricType.heartRate.rawValue, unit: "bpm", value: .infinity))
        #expect(!HealthWriteBack.isWritable(metric: MetricType.heartRate.rawValue, unit: "bpm", value: .nan))
        #expect(!HealthWriteBack.isWritable(metric: "unknownMetric", unit: "bpm", value: 60))
    }

    @Test("草稿载荷：等值性与默认第二值")
    func 草稿() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let draft = HealthSampleDraft(metric: MetricType.bloodPressureSys.rawValue, value: 128,
                                      secondaryValue: 82, unit: "mmHg", measuredAt: date)
        #expect(draft.secondaryValue == 82)
        let single = HealthSampleDraft(metric: MetricType.heartRate.rawValue, value: 72,
                                       unit: "bpm", measuredAt: date)
        #expect(single.secondaryValue == nil)
        #expect(single != draft)
    }
}
