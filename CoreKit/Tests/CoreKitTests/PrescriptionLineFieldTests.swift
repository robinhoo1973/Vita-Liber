import Foundation
import Testing
@testable import Domain

/// round5 Q1（业主 2026-09-20 第 1 项）：处方行「模板键 ↔ 事实列」此前四份手工登记（投影 / 展示 / 审计同步 / 编辑面），
/// `CardKindRegistry` 目录含 `unit` 而投影不认识 → 用户添加「单位」、填值、确认、过校验后**静默丢弃**。
/// `PrescriptionLineField` 一表四读；契约测试把「目录键必有列」钉成事实。
@Suite("SU-OCRA-LAYOUT · PrescriptionLineField 一表四读")
struct PrescriptionLineFieldTests {
    @Test func catalogKeysExactlyMatchFieldTable() {
        let catalog = CardKindRegistry.entry(for: "prescription")!.rowAllowed
        let table = Set(PrescriptionLineField.allCases.map(\.key))
        #expect(catalog == table, "目录 − 表 = \(catalog.subtracting(table))；表 − 目录 = \(table.subtracting(catalog))")
    }

    @Test func templateRowKeysAreCoveredByTheTable() {
        // 模板 rowLevelKeys 可少于目录（模板只管机器抽取），但不得含表外键
        let template = CardTemplateMatcher.ocrTemplates.first { $0.kind == "prescription" }!
        let table = Set(PrescriptionLineField.allCases.map(\.key))
        #expect(template.rowLevelKeys.isSubset(of: table))
    }

    @Test func standaloneUnitFieldProjectsToDoseUnit() throws {
        // 确认页 showUnit=false → 用户唯一能走的路是「添加字段 → 单位」；此前投影只读 dosage.unit 属性
        var card = MatchedCard(kind: "prescription", pageIndex: 0,
            shared: [.init(key: "prescribed_at", value: "2026-09-20")],
            rows: [MatchedCardRow(fields: [.init(key: "drug_name", value: "阿莫西林胶囊"),
                                           .init(key: "dosage", value: "0.5"),
                                           .init(key: "unit", value: "g", confidence: 1)])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).fullyConfirmed()
        let intent = try #require(EntityCardProjection.prescriptionIntent(from: card))
        #expect(intent.lines[0].line.doseText == "0.5")
        #expect(intent.lines[0].line.doseUnit == "g")
        // dosage 自带单位属性优先（机器抽取形态），独立 unit 字段为兜底
        card.rows[0].fields[1] = FieldDraft(key: "dosage", value: "0.5", unit: "mg", grade: .userConfirmed)
        let intent2 = try #require(EntityCardProjection.prescriptionIntent(from: card))
        #expect(intent2.lines[0].line.doseUnit == "mg")
    }

    @Test func everyOptionalKeyRoundTripsThroughProjection() throws {
        // 举一反三：目录里每个可选键填值后都必须出现在行实体上（不再有静默丢弃的键）
        var fields: [FieldDraft] = [.init(key: "drug_name", value: "X")]
        let sample: [String: String] = [
            "spec": "0.25g×24", "dosage": "1", "quantity": "2", "frequency": "每日3次", "route": "口服", "days": "7",
            "unit": "粒", "note": "饭后", "drug_form": "胶囊", "generic_name": "阿莫西林", "brand_name": "再林",
            "start_date": "2026-09-20", "end_date": "2026-09-27", "as_needed": "否", "medication_notes": "多饮水",
            "insurance_code": "XA01", "item_code": "IC-9", "unit_price": "12.5", "line_amount": "25",
        ]
        for (k, v) in sample { fields.append(.init(key: k, value: v, confidence: 1)) }
        let card = MatchedCard(kind: "prescription", pageIndex: 0, shared: [.init(key: "prescribed_at", value: "2026-09-20")],
            rows: [MatchedCardRow(fields: fields)], allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
            .fullyConfirmed()
        let line = try #require(EntityCardProjection.prescriptionIntent(from: card)).lines[0].line
        for field in PrescriptionLineField.allCases where field != .drugName {
            #expect(field.displayValue(of: line) != nil, "键 \(field.key) 填值后未落到行实体")
        }
        #expect(line.doseUnit == "粒")
        #expect(line.unitPrice == 12.5 && line.amount == 25)
    }

    @Test func valueKindsAlignWithProjectionSingleSource() {
        for field in PrescriptionLineField.allCases {
            #expect(field.valueKind == EntityCardProjection.valueKind(kind: "prescription", key: field.key), Comment(rawValue: field.key))
        }
    }
}
