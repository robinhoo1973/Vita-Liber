import Foundation

/// FR11.4 懒创建触发点（V3.49）：病历类文档确认保存后，从已确认字段派生
/// 候选健康问题名——诊断字段优先（截断 40 字），无诊断回落「文档类型+日期」。
/// Domain 纯函数零业务决策：候选仅作建议，用户确认后才落 health_problem
/// （D 级建议→C 级事实）。
/// 结构轮（2026-09-15）：自 DocumentTypeClassifierFallback.swift 迁出——
/// 健康问题派生与文档分类无关（P2）。
public enum HealthProblemDerivation {
    /// 候选名回落格式 "yyyy-MM-dd"（静态缓存——DateFormatter 构造昂贵，
    /// 每份病历保存触发一次懒创建即一次构造不必要）
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func candidateName(fields: [CandidateField], docTypeLabel: String,
                                     now: Date = Date()) -> String {
        if let diagnosis = fields.first(where: { $0.key == "diagnosis" && !$0.value.isEmpty }) {
            return String(diagnosis.value.prefix(40))
        }
        return "\(docTypeLabel)·\(dayFormatter.string(from: now))"
    }
}

/// FR11.4 · v26（子项目 D §C.3）：诊断行 → D 级健康问题候选（每行一候选，替代 40 字截断）。
/// 纯函数、零写入：候选只供用户勾选；用户逐项采用后才由 store 写 `health_problem` 并回填
/// `diagnosis.health_problem_id`（BR-003 D→C 只经显式确认）。名称/编码/日期均为诊断行原文，不猜码、不猜日期。
public struct HealthProblemCandidate: Sendable, Equatable {
    /// 医生原文（去首尾空白），不改写。
    public var name: String
    public var codeText: String?
    public var codeSystemText: String?
    public var diagnosedAt: Date?
    /// 来源诊断行（采用后回填 `diagnosis.health_problem_id` 的落点）。
    public var diagnosisId: UUID

    public init(name: String, codeText: String? = nil, codeSystemText: String? = nil, diagnosedAt: Date? = nil, diagnosisId: UUID) {
        self.name = name; self.codeText = codeText; self.codeSystemText = codeSystemText
        self.diagnosedAt = diagnosedAt; self.diagnosisId = diagnosisId
    }

    /// 每行一候选；同名（去空白）只保留首见（入院诊断/出院诊断重复列同一病名不生成两条）；空名跳过。
    public static func from(diagnoses: [Diagnosis]) -> [HealthProblemCandidate] {
        var seen = Set<String>()
        return diagnoses.compactMap { row in
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return HealthProblemCandidate(name: name, codeText: row.codeText, codeSystemText: row.codeSystemText,
                                          diagnosedAt: row.diagnosedAt, diagnosisId: row.id)
        }
    }
}
