import Foundation

/// 健康读数后处理填卡（swift-class-design.md §5.5 推理链的健康侧落地，结构轮 2026-09-15）：
/// `DeviceMetricRow` → 附参考区间 / 引用式级别的 `HealthMetricCard`。
/// 纯函数零写入；评估与入库双流不受影响（alert_event 仍由 `AlertRuleEngine`
/// 判定链产出，本类只把定级结果作为**引用式呈现字段**复制到卡——BR-006）。
public enum HealthCardComposer {

    /// 填卡：B 级信源参考范围（正常带 = 信源 l1 界限内；A 级随行范围在
    /// `metric_sample` 事实行，不复制到卡）+ 引用式级别（无范围时 nil = 范围不可用，
    /// 与 AlertRuleEngine 同语义）。
    public static func compose(row: DeviceMetricRow, kind: HealthDataKind,
                               guideline: GuidelineEntry?, patientId: UUID?) -> HealthMetricCard {
        var card = HealthMetricCard.make(from: row, kind: kind, patientId: patientId)
        if let guideline,
           let low = guideline.l1Low, let high = guideline.l1High, low < high {
            card.referenceRange = ReferenceRange(lower: low, upper: high, grade: .B,
                                                 sourceNote: "\(guideline.title) \(guideline.version)")
        }
        let reading = MetricReading(
            metricKey: row.metricKey, value: row.value, unit: row.unit, origin: .device,
            measuredAt: row.measuredAt,
            sourceName: row.sourceName, sourceVersion: row.sourceVersion,
            sourceProduct: row.sourceProduct, sourceIdentifier: row.sourceIdentifier,
            sampleID: row.sourceRef)
        card.severity = AlertRuleEngine.severity(for: reading, guideline: guideline)
        return card
    }
}
