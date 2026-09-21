import Foundation
import Testing
@testable import Domain

/// round5 Q4：「哪个键是日期/数值/枚举」此前散落四处（`optionalDateKeys` 私有 / `dateKey` / `ExtractionSpec .date` /
/// `CardFieldEditSheet` 手抄）。`EntityCardProjection.valueKind(kind:key:)` 为**单源**——控件选择（DatePicker / 数字键盘 /
/// Picker）、落库校验（`invalidFields`）、编辑预校验三者同一张表。
@Suite("SU-OCRA-LAYOUT · FieldValueKind 单源")
struct FieldValueKindTests {
    @Test func requiredDateKeyIsDate() {
        #expect(EntityCardProjection.valueKind(kind: "prescription", key: "prescribed_at") == .date)
        #expect(EntityCardProjection.valueKind(kind: "encounter", key: "date") == .date)
        #expect(EntityCardProjection.valueKind(kind: "immunization", key: "administered_at") == .date)
        #expect(EntityCardProjection.valueKind(kind: "health_exam", key: "exam_date") == .date)
    }

    @Test func optionalDateKeysAreDate() {
        #expect(EntityCardProjection.valueKind(kind: "prescription", key: "start_date") == .date)
        #expect(EntityCardProjection.valueKind(kind: "prescription", key: "end_date") == .date)
        #expect(EntityCardProjection.valueKind(kind: "hospitalization", key: "admit_at") == .date)
        #expect(EntityCardProjection.valueKind(kind: "metric_sample", key: "collected_at") == .date)
        #expect(EntityCardProjection.valueKind(kind: "claim_item", key: "fee_at") == .date)
    }

    @Test func numericAndIntegerKeys() {
        #expect(EntityCardProjection.valueKind(kind: "prescription", key: "unit_price") == .number)
        #expect(EntityCardProjection.valueKind(kind: "prescription", key: "total_amount") == .number)
        #expect(EntityCardProjection.valueKind(kind: "hospitalization", key: "inpatient_times") == .integer)
        #expect(EntityCardProjection.valueKind(kind: "claim_item", key: "amount") == .number)   // 必填金额亦数值
    }

    @Test func enumeratedKeysCarryCanonicalOptions() {
        guard case .enumerated(let kinds) = EntityCardProjection.valueKind(kind: "encounter", key: "kind") else {
            Issue.record("encounter.kind 应为枚举"); return
        }
        #expect(kinds.contains(EncounterKind.outpatient.rawValue))
        guard case .enumerated(let types) = EntityCardProjection.valueKind(kind: "prescription", key: "prescription_type") else {
            Issue.record("prescription_type 应为枚举"); return
        }
        #expect(types.contains("general"))
        #expect(EntityCardProjection.enumeratedOptions(forKey: "currency")?.contains("CNY") == true)
    }

    @Test func everythingElseIsText() {
        #expect(EntityCardProjection.valueKind(kind: "prescription", key: "hospital") == .text)
        #expect(EntityCardProjection.valueKind(kind: "prescription", key: "spec") == .text)
        #expect(EntityCardProjection.valueKind(kind: "unknown_kind", key: "date") == .text)   // 未知卡种不猜
    }

    /// 单源 ⊇ 编辑面此前手抄集（回归护栏：迁移后任何旧键都不得退化为文本框）。
    @Test func supersedesHandCopiedEditSheetSets() {
        let legacyDates: [(String, String)] = [("immunization", "administered_at"), ("diagnosis", "diagnosed_at"),
            ("exam_report", "exam_at"), ("exam_report", "reported_at"), ("surgery", "surgery_at"), ("surgery", "ended_at"),
            ("treatment_record", "treated_at"), ("hospitalization", "admit_at"), ("hospitalization", "discharge_at"),
            ("hospitalization", "summary_date")]
        for (kind, key) in legacyDates { #expect(EntityCardProjection.valueKind(kind: kind, key: key) == .date, "\(kind).\(key)") }
        let legacyNumbers: [(String, String)] = [("claim_item", "amount"), ("claim_item", "reimbursed_amount"),
            ("claim_item", "out_of_pocket"), ("claim_item", "personal_account_amount"), ("prescription", "total_amount"),
            ("hospitalization", "total_cost"), ("metric_sample", "ref_low"), ("metric_sample", "ref_high"),
            ("prescription", "unit_price"), ("prescription", "line_amount")]
        for (kind, key) in legacyNumbers { #expect(EntityCardProjection.valueKind(kind: kind, key: key) == .number, "\(kind).\(key)") }
    }
}
