import SwiftUI
import Domain
import Infrastructure

/// 卡类图标**单一出口**（ui-ux §3.4 / 子项目 J · round1 §E.4）：kind → 行内 SF Symbol + 大尺寸 VLIcon 字形 + 语义色令牌。
///
/// 纪律：
/// - 色按**卡类**不按严重度（BR-004/012）——结论 `severity_text` 永不参与着色。
/// - 全部 SF Symbol ≤ SF Symbols 4（iOS 16.0 部署目标，家族 J）；色令牌只取 Assets（brand-primary / semantic-* /
///   grade-* / text-secondary），不新增 hex。
/// - 替代此前散落的三处映射：`EncounterViews.icon(for:)` / `TimelineRowView.color` / `MedicalCardDetailView` 硬编码 `pills.fill`。
///   新增卡类只在此登记；对 `TimelineEntryKind` / `EncounterStore.LinkedCardRow.Kind` / `RecordHub` 的 switch 均**穷尽无 default**，
///   Domain/Infrastructure 增 case 时此处编译期即红（V11 验证合同）。
/// - 行内小尺寸用 `symbol`（SF Symbols），瓷砖/大尺寸用 `glyph`（VLIcon，§11-13 设计系统规则）。
enum CardKindIcon {
    struct Spec {
        let symbol: String
        let glyph: Image
        let tint: Color
    }

    // MARK: - 色令牌（Assets 已有，token-only）

    private static var brand: Color { Color("brand-primary", bundle: .main) }
    private static var gradeC: Color { Color("grade-c", bundle: .main) }
    private static var success: Color { Color("semantic-success", bundle: .main) }
    private static var warning: Color { Color("semantic-warning", bundle: .main) }
    private static var danger: Color { Color("semantic-danger", bundle: .main) }
    private static var secondary: Color { Color("text-secondary", bundle: .main) }

    // MARK: - 首页聚合行类别（AggregationKind）

    /// `AggregationKind` 全 9 case 穷尽（2026-09-16 委员会评审收敛）：首页聚合行
    /// 此前在 HomeView 内联 icon/tint 两张 switch，且 tint 直接写
    /// `.blue/.teal/.indigo/.yellow/.red/.orange/.green/.gray` 八个硬编码色——
    /// 违反 token-only 纪律，并与本出口构成第二套类别色映射（同类别两页两色）。
    /// 语义映射：提醒/预约/文档/系统 → brand；OCR 待确认 → warning；
    /// 预警/SOS → danger；家庭 → success。（图标字形沿用原内联值，视觉零变化。）
    static func spec(aggregation: AggregationKind) -> Spec {
        switch aggregation {
        // 符号按 §3.4 表统一（2026-09-16 评审）：同一业务概念跨聚合轴/时间轴必须同符号，
        // 否则同一符号在两个面上指代两个类别——`stethoscope` 曾在首页=预约、时间轴=就诊，
        // `pills.fill` 曾是**处方**符号却被聚合的「用药」类别占用。tint 保留表面语义
        // 差异（提醒行=brand）是允许的：符号是类别身份，tint 才是表面强调。
        case .medication: return Spec(symbol: "pills.circle", glyph: VLIcon.pill, tint: brand)
        case .appointment: return Spec(symbol: "calendar.badge.clock", glyph: VLIcon.appointment, tint: brand)
        case .document: return Spec(symbol: "doc.text", glyph: VLIcon.tag, tint: brand)
        case .ocr: return Spec(symbol: "exclamationmark.triangle.fill", glyph: VLIcon.tag, tint: warning)
        case .alert: return Spec(symbol: "waveform.path.ecg", glyph: VLIcon.vitalsChart, tint: danger)
        case .pendingCard: return Spec(symbol: "clock.badge.checkmark", glyph: VLIcon.doctor, tint: warning)
        case .family: return Spec(symbol: "person.2.fill", glyph: VLIcon.memberFamily, tint: success)
        case .sos: return Spec(symbol: "sos", glyph: VLIcon.memberSelf, tint: danger)
        case .system: return Spec(symbol: "gearshape.fill", glyph: VLIcon.settings, tint: secondary)
        }
    }

    // MARK: - 时间轴条目类型（主表；其余重载全部归并到此）

    /// `TimelineEntryKind` 全 22 case 穷尽（既有九类 + document + v27 十二类）。
    static func spec(timelineKind kind: TimelineEntryKind) -> Spec {
        switch kind {
        case .encounter: return Spec(symbol: "stethoscope", glyph: VLIcon.stethoscope, tint: brand)
        case .hospitalization: return Spec(symbol: "bed.double", glyph: VLIcon.hospital, tint: brand)
        case .healthExam: return Spec(symbol: "heart.text.square", glyph: VLIcon.vitalsChart, tint: brand)
        case .diagnosis: return Spec(symbol: "list.clipboard", glyph: VLIcon.doctor, tint: brand)
        case .prescription: return Spec(symbol: "pills", glyph: VLIcon.prescription, tint: brand)
        case .medication: return Spec(symbol: "pills.circle", glyph: VLIcon.pill, tint: gradeC)
        case .lab, .labReport: return Spec(symbol: "testtube.2", glyph: VLIcon.labClipboard, tint: brand)
        case .examReport: return Spec(symbol: "waveform.path.ecg.rectangle", glyph: VLIcon.imagingEcg, tint: brand)
        case .claim: return Spec(symbol: "creditcard", glyph: VLIcon.tag, tint: brand)   // 无专用票据字形，设计侧登记 ic-receipt
        case .surgery: return Spec(symbol: "scissors", glyph: VLIcon.doctor, tint: brand)
        case .treatmentRecord: return Spec(symbol: "cross.vial", glyph: VLIcon.medicineBox, tint: brand)
        case .clinicalConclusion: return Spec(symbol: "text.quote", glyph: VLIcon.doctor, tint: brand)
        case .vaccination: return Spec(symbol: "syringe", glyph: VLIcon.vaccine, tint: success)
        case .appointment: return Spec(symbol: "calendar.badge.clock", glyph: VLIcon.appointment, tint: brand)
        case .reminder: return Spec(symbol: "bell", glyph: VLIcon.bell, tint: warning)
        case .observation: return Spec(symbol: "eye", glyph: VLIcon.observeFrame, tint: warning)
        case .selfMeasured: return Spec(symbol: "waveform.path.ecg", glyph: VLIcon.pulse, tint: brand)
        // Apple 健康导入（FR7.9/FR16.1）：符号同健康 Tab（heart.text.clipboard）——
        // 与手输自测（波形）一眼可分，色仍按卡类不按严重度（BR-004）。
        case .healthData: return Spec(symbol: "heart.text.clipboard", glyph: VLIcon.pulse, tint: brand)
        case .allergy: return Spec(symbol: "allergens", glyph: VLIcon.allergy, tint: danger)
        case .voiceNote: return Spec(symbol: "mic", glyph: VLIcon.mic, tint: secondary)
        case .healthProblem: return Spec(symbol: "cross.case", glyph: VLIcon.timeline, tint: brand)
        case .document: return Spec(symbol: "doc.text", glyph: VLIcon.folder, tint: secondary)
        }
    }

    // MARK: - 主卡枢纽 / 子卡类

    /// 主卡三枢纽；就诊主卡带已确认住院期时以住院图标呈现（`hospitalized`）。
    static func spec(hub: RecordHub, hospitalized: Bool = false) -> Spec {
        switch hub {
        case .encounter: return spec(timelineKind: hospitalized ? .hospitalization : .encounter)
        case .hospitalization: return spec(timelineKind: .hospitalization)
        case .healthExam: return spec(timelineKind: .healthExam)
        }
    }

    static func spec(childKind kind: RecordChildKind) -> Spec { spec(timelineKind: kind.timelineKind) }

    // MARK: - 卡类字符串（CardKindRegistry kinds ∪ lab_report ∪ appointment ∪ reminder）

    /// 卡类字符串 → 时间轴条目类型（= 事实表名口径）；未登记键回落 document 图标。
    static func timelineKind(cardKind: String) -> TimelineEntryKind {
        switch cardKind {
        case "encounter": return .encounter
        case "hospitalization": return .hospitalization
        case "health_exam": return .healthExam
        // Apple 健康信息卡（HealthMetricCard，cardType "health_metric"，业主 2026-09-17 定）：
        // 与时间轴 .healthData 同符号（§3.4：同一业务概念跨面必须同符号）
        case "health_metric": return .healthData
        case "diagnosis": return .diagnosis
        case "prescription": return .prescription
        case "medication": return .medication
        case "metric_sample": return .lab
        case "lab_report": return .labReport
        case "exam_report": return .examReport
        case "claim_item": return .claim
        case "surgery": return .surgery
        case "treatment_record": return .treatmentRecord
        case "clinical_conclusion": return .clinicalConclusion
        case "immunization": return .vaccination
        case "appointment": return .appointment
        case "reminder": return .reminder
        default: return .document
        }
    }

    static func spec(cardKind: String) -> Spec { spec(timelineKind: timelineKind(cardKind: cardKind)) }

    // MARK: - 就诊关联卡（EncounterStore.LinkedCardRow.Kind，穷尽）

    static func timelineKind(linkedKind kind: EncounterStore.LinkedCardRow.Kind) -> TimelineEntryKind {
        switch kind {
        case .prescription: return .prescription
        case .claim: return .claim
        case .medication: return .medication
        case .metricSample: return .lab
        case .immunization: return .vaccination
        case .encounter: return .encounter
        case .hospitalization: return .hospitalization
        case .diagnosis: return .diagnosis
        case .examReport: return .examReport
        case .labReport: return .labReport
        case .surgery: return .surgery
        case .treatmentRecord: return .treatmentRecord
        case .appointment: return .appointment
        case .reminder: return .reminder
        }
    }

    static func spec(linkedKind kind: EncounterStore.LinkedCardRow.Kind) -> Spec { spec(timelineKind: timelineKind(linkedKind: kind)) }

    // MARK: - 文档稳定键（FR5.5）

    /// 文档稳定键 → 其「结构化目标卡」首卡类图标；仅附件类 / other / custom / 未知键 → document。
    static func spec(documentTypeKey key: String?) -> Spec {
        guard let key, let type = DocumentTypeKey(rawValue: key), let first = type.targetCardKinds.first else {
            return spec(timelineKind: .document)
        }
        return spec(cardKind: first)
    }

    // MARK: - 便捷出口（symbol / tint）
    // 实参标签按枚举区分（`.appointment` / `.surgery` / `.healthExam` 在 TimelineEntryKind / RecordChildKind /
    // LinkedCardRow.Kind / RecordHub 中同名——同标签重载会让隐式成员表达式二义，仅 macOS L1 才报）。

    static func symbol(for kind: TimelineEntryKind) -> String { spec(timelineKind: kind).symbol }
    static func tint(for kind: TimelineEntryKind) -> Color { spec(timelineKind: kind).tint }
    static func symbol(hub: RecordHub) -> String { spec(hub: hub).symbol }
    static func tint(hub: RecordHub) -> Color { spec(hub: hub).tint }
    static func symbol(child kind: RecordChildKind) -> String { spec(childKind: kind).symbol }
    static func tint(child kind: RecordChildKind) -> Color { spec(childKind: kind).tint }
    static func symbol(linked kind: EncounterStore.LinkedCardRow.Kind) -> String { spec(linkedKind: kind).symbol }
    static func tint(linked kind: EncounterStore.LinkedCardRow.Kind) -> Color { spec(linkedKind: kind).tint }
    static func symbol(cardKind kind: String) -> String { spec(cardKind: kind).symbol }
    static func tint(cardKind kind: String) -> Color { spec(cardKind: kind).tint }
}
