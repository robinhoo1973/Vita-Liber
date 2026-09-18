import Foundation
import Domain

/// 文档字段展示映射命名空间（2026-09-18 OOP 颗粒度轮：从
/// DocumentLibraryView.swift 拆出；2026-09-19 二次拆分：从 DocumentsState
/// 静态成员改为独立类型——展示映射与状态仓解耦，调用方
/// `DocumentsDisplay.fieldLabel` 等自明归属）。canonical raw → 当前语言
/// 展示名的四个单一出口（fieldLabel / timelineEntryTitle / fieldValueDisplay /
/// enumOptions）。所有字段值渲染面必须经此命名空间，禁止 raw 直出。
enum DocumentsDisplay {
    static func fieldLabel(forKey key: String) -> String {
        switch key {
        case "dept": return L10n.ocFieldDept
        case "report_date", "prescribed_at": return L10n.ocFieldReportDate
        case "reference_range": return L10n.ocFieldReferenceRange
        case "lab_item": return L10n.ocFieldLabItem
        case "chief_complaint": return L10n.ocFieldChiefComplaint
        case "diagnosis": return L10n.ocFieldDiagnosis
        case "treatment": return L10n.ocFieldTreatment
        case "drug_name": return L10n.prescriptionFieldDrugName
        case "hospital": return L10n.prescriptionFieldHospital
        case "doctor": return L10n.prescriptionFieldDoctor
        default:
            if key.hasPrefix("line_"), let index = Int(key.dropFirst(5)) { return L10n.entityCardRowIndex(index + 1) }
            if key.hasPrefix("rx_line_"), let index = Int(key.dropFirst(8)) { return L10n.entityCardRowIndex(index + 1) }
            return L10n.templateFieldLabel(key)
        }
    }

    /// FR6.9 字段值**展示层映射**（discussions/2026-09-12-owner-round10-issues.md §3a）：
    /// 数据层保持 canonical raw（如 `EncounterKind.outpatient`、`unit_kind=tablet`），
    /// 展示层按当前语言呈现；用户实测「信息卡出现 outpatient」的根因就是 raw 值直出。
    /// 所有字段值渲染面（确认卡/待办续确认/已确认卡详情/首页待办卡/库存/图片确认卡）
    /// 必须经此函数。编辑态 TextField 仍显示并回写 canonical raw（编辑框即数据
    /// 真值、展示文案永不写回数据）——把展示文案映射进编辑框会让半程编辑
    /// 把本地化片段写进 raw 槽位（round10 max 审查结论，保持原设计）。
    /// 时间轴行**标题**的展示出口（2026-09-17 业主实测复发：就诊类型显示 `outpatient`）。
    ///
    /// **根因**：`TimelineQueryStore` 的就诊/住院行是 `SELECT … e.kind AS title`——`title`
    /// **就是** `kind` canonical raw。V3.71 那次修复只把**主卡行**接到了 `fieldValueDisplay`，
    /// 子卡行与平铺叶子行仍直出 `entry.title` → 英文 raw 上屏。
    ///
    /// 本函数收口三处渲染面（主卡行继续保持原调用，子卡行与叶子行改经此处），
    /// 使「同一 kind raw 在任何时间轴行上都按当前语言呈现」只有一处实现。
    static func timelineEntryTitle(_ entry: TimelineEntry) -> String {
        switch entry.kind {
        // ── title 是 **canonical raw** 的行类：必须映射，否则英文 raw 上屏 ──
        // 依据：`TimelineQueryStore` 的 SQL 别名（逐条可查）——
        //   :44  `kind AS title`（就诊平铺）  :214 `e.kind AS title`（就诊主卡）
        //   :326 住院 `hospitalization` 行的 title 是文本（医院名）→ 不在本组
        //   :60  `kind AS title`（观察）
        //   :334 `f.metric_key AS title`（医院检验点）
        //   :335 `report_type AS title`（检查报告）
        case .encounter, .hospitalization:
            return fieldValueDisplay(forKey: "kind", value: entry.title)
        case .observation:
            // title = `ObservationKind` raw（stool/urine/skin/eye/…）；全仓其余渲染面
            // 均经 `L10n.observationKindName`，唯时间轴行此前直出。
            return ObservationKind(rawValue: entry.title).map(L10n.observationKindName) ?? entry.title
        case .examReport:
            // title = `report_type` canonical raw（pathology/imaging/…）
            return fieldValueDisplay(forKey: "report_type", value: entry.title)
        case .lab, .selfMeasured, .healthData:
            // title = `metric_key`（`lab.*` canonical）→ 本地化指标名
            if let metric = entry.metricKey.flatMap({ MetricType(grammarKey: $0) }) ?? MetricType(grammarKey: entry.title) {
                return L10n.metricName(metric)
            }
            return entry.title
        // ── title 是「已被上层处理过或本就是文本」的行类 ──
        // 说明：住院行（:326）title = 医院名；处方行（:328）title = 首行药名或其他文本；
        // 检验表头行（:330）title = 检验类别/实验室/医院文本——三者均为原文，不映射。
        case .clinicalConclusion:
            return L10n.timelineHubConclusions(Int(entry.title) ?? 0)
        case .treatmentRecord:
            return L10n.treatmentTypeName(entry.title)
        case .document:
            return entry.title.isEmpty ? L10n.timelineKindName(.document) : entry.title
        default:
            return entry.title.isEmpty ? L10n.timelineKindName(entry.kind) : entry.title
        }
    }

    static func fieldValueDisplay(forKey key: String, value: String) -> String {
        switch key {
        case "kind":
            return EncounterKind(rawValue: value).map(L10n.encounterKindName) ?? value
        case "doc_type", "document_type":
            return DocumentsState.docTypeLabel(forStableKey: value) ?? value
        case "item_type":
            switch value {
            case "invoice": return L10n.claim_type_invoice
            case "fee": return L10n.claim_type_fee
            case "receipt": return L10n.claim_type_receipt
            default: return value
            }
        case "unit_kind":
            return ["tablet", "capsule", "patch", "vial"].contains(value) ? L10n.lotUnitName(value) : value
        case "currency":
            return value == "CNY" ? L10n.currencyCNY : value
        case "prescription_type":
            return L10n.prescriptionTypeName(value)
        // v26（§C.3 / §C.4）：诊断类型 / 检查报告类型 canonical raw → 展示名（未登记原样透传）
        case "diagnosis_type":
            return L10n.diagnosisTypeName(value)
        case "report_type":
            return L10n.examReportTypeName(value)
        // v27（子项目 J）：治疗类型 / 结论类型 / 预约目的 / 文档稳定键 canonical raw → 展示名（未登记原样透传）。
        // `severity`（结论程度）**不在此列**：打印原文直出，不映射不着色（BR-004/012）。
        case "treatment_type":
            return L10n.treatmentTypeName(value)
        case "conclusion_type":
            return L10n.conclusionTypeName(value)
        case "purpose":
            return L10n.appointmentPurposeName(value)
        case "doc_type_key":
            return DocumentsState.docTypeLabel(forStableKey: value) ?? value
        default:
            return value
        }
    }

    /// 枚举槽位的 canonical 值目录（SP-12 确认卡 Picker 选项；标签经 `fieldValueDisplay`）。
    /// 与 `EntityCardProjection.invalidFields` 的枚举校验同拼写；nil = 自由文本字段（走 TextField）。
    /// 处方类型按 Domain `prescriptionTypes` 过滤保序（Domain 增删枚举不会让 Picker 出现非法项）。
    static func enumOptions(forKey key: String) -> [String]? {
        switch key {
        case "kind": return EncounterKind.allCases.map(\.rawValue)
        case "item_type": return ["invoice", "fee", "receipt"]
        case "unit_kind": return ["tablet", "capsule", "patch", "vial"]
        case "currency": return ["CNY", "HKD", "MOP", "TWD", "USD", "EUR", "JPY", "GBP"]
        case "prescription_type":
            return ["general", "emergency", "pediatric", "narcotic", "psychotropic", "tcm", "other"]
                .filter { EntityCardProjection.prescriptionTypes.contains($0) }
        // v26：诊断类型 / 检查报告类型（Domain CHECK 同拼写目录，Picker 绑 canonical raw）；
        // `kind` 目录随 EncounterKind.allCases 自动含 daySurgery（住院卡以外的 kind 由 invalidFields 裁定）。
        case "diagnosis_type": return Diagnosis.diagnosisTypes
        case "report_type": return ExamReport.reportTypes
        // v27：治疗类型 / 结论类型（Domain CHECK 同拼写目录；Picker 绑 canonical raw）
        case "treatment_type": return TreatmentRecord.treatmentTypes
        case "conclusion_type": return ClinicalConclusion.conclusionTypes
        default: return nil
        }
    }
}
