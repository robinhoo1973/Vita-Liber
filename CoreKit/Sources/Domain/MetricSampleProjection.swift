import Foundation

/// 确认后的检验项目 → `metric_sample` 医院来源行（FR7.9/FR7.2：A 级参考范围随行、
/// 原始指标名保真 FR25.4、编码只在用户确认建议后回填 FR25.11）。
/// 结构轮（2026-09-15）：自 CardTemplateMatcher.swift 迁出——模板匹配与
/// 检验样本投影是两个域（P2）；投影侧（EntityCardProjection / TrendQueryStore /
/// OCRCardStore / ExportService）共享本模型。
public struct HospitalSample: Sendable, Equatable {
    public var metricKey: String
    public var rawLabel: String
    public var value: Double
    public var unit: String
    public var measuredAt: Date
    public var refLow: Double?
    public var refHigh: Double?
    public var refSourceLabel: String?
    public var codeConceptId: String?
    /// v26（§C.5）：报告**打印**的 ↑↓/H/L 原文（A 级来源事实）——App 不计算、不解释、不据此提示（BR-004/012）。
    public var abnormalFlag: String?
    /// v27（子项目 J）：体检一般检查投影点回指体检枢纽（`metric_sample.health_exam_id`）；检验行为 nil。
    /// 意图内为 `HealthExam.id`（= 回执 row_id）；store `ensureHealthExam` 命中同文档既有体检时以其 id 覆盖。
    public var healthExamId: UUID?
    public init(metricKey: String, rawLabel: String, value: Double, unit: String, measuredAt: Date,
                refLow: Double? = nil, refHigh: Double? = nil, refSourceLabel: String? = nil,
                codeConceptId: String? = nil, abnormalFlag: String? = nil, healthExamId: UUID? = nil) {
        self.metricKey = metricKey; self.rawLabel = rawLabel; self.value = value; self.unit = unit
        self.measuredAt = measuredAt; self.refLow = refLow; self.refHigh = refHigh
        self.refSourceLabel = refSourceLabel; self.codeConceptId = codeConceptId; self.abnormalFlag = abnormalFlag
        self.healthExamId = healthExamId
    }

    /// 文档页回链（`metric_sample.source_ref`）：`doc:<uuid>#p<index>`
    public static func sourceRef(documentId: UUID, pageIndex: Int) -> String {
        "doc:\(documentId.uuidString)#p\(pageIndex)"
    }
}
