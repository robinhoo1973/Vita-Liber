import XCTest
import Foundation
import Domain
@testable import VitaLiber

/// FR6.9 展示层映射（fieldValueDisplay）回归网：
/// 数据层 canonical raw → 展示层本地化；未知值与自由文本一律原样透传
/// （不得误映射、不得丢内容）。编辑态 TextField 显示并回写 canonical raw，
/// 不经展示层往返（展示文案永不写回数据）。
@MainActor
final class DocumentsFieldDisplayTests: XCTestCase {

    private func display(_ key: String, _ value: String) -> String {
        DocumentsState.fieldValueDisplay(forKey: key, value: value)
    }

    // MARK: kind → EncounterKind

    func testKindMapsEveryEncounterKindToLocalizedName() {
        for kind in EncounterKind.allCases {
            XCTAssertEqual(display("kind", kind.rawValue), L10n.encounterKindName(kind))
        }
    }

    func testKindUnknownRawPassesThroughUnmapped() {
        XCTAssertEqual(display("kind", "unknown_kind"), "unknown_kind")
        XCTAssertEqual(display("kind", "门诊"), "门诊")
    }

    // MARK: doc_type / document_type → stable-key labels

    func testDocTypeKeysMapToLabels() {
        XCTAssertEqual(display("doc_type", "prescription"), L10n.docTypePrescription)
        XCTAssertEqual(display("doc_type", "lab_report"), L10n.docTypeReport)
        XCTAssertEqual(display("doc_type", "outpatient_record"), L10n.docTypeRecord)
        XCTAssertEqual(display("document_type", "diagnosis_certificate"), L10n.docTypeLabelDiagnosisProof)
        XCTAssertEqual(display("document_type", "vaccine_record"), L10n.docTypeLabelVaccineRecord)
        XCTAssertEqual(display("doc_type", "invoice"), L10n.claim_type_invoice)
        XCTAssertEqual(display("doc_type", "medication_label"), L10n.entityCardKindName("medication"))
    }

    func testDocTypeUnknownValuePassesThrough() {
        XCTAssertEqual(display("doc_type", "checkup_report"), "checkup_report")
    }

    // MARK: item_type → claim type labels

    func testItemTypeMapsAllThreeCanonicalValues() {
        XCTAssertEqual(display("item_type", "invoice"), L10n.claim_type_invoice)
        XCTAssertEqual(display("item_type", "fee"), L10n.claim_type_fee)
        XCTAssertEqual(display("item_type", "receipt"), L10n.claim_type_receipt)
    }

    func testItemTypeUnknownValuePassesThrough() {
        XCTAssertEqual(display("item_type", "检查单"), "检查单")
    }

    // MARK: unit_kind → 剂型名（已知集映射，未知透传）

    func testUnitKindMapsCanonicalSet() {
        for kind in ["tablet", "capsule", "patch", "vial"] {
            XCTAssertEqual(display("unit_kind", kind), L10n.lotUnitName(kind))
        }
    }

    func testUnitKindUnknownPassesThrough() {
        XCTAssertEqual(display("unit_kind", "盒"), "盒")
    }

    // MARK: currency

    func testCurrencyCNYMapsToLocalizedName() {
        XCTAssertEqual(display("currency", "CNY"), L10n.currencyCNY)
        XCTAssertEqual(display("currency", "USD"), "USD")
    }

    // MARK: 其余键与自由文本

    func testOtherKeysPassThroughUntouched() {
        XCTAssertEqual(display("drug_name", "阿莫西林"), "阿莫西林")
        XCTAssertEqual(display("hospital", "人民医院"), "人民医院")
        XCTAssertEqual(display("metric_key", "blood_oxygen"), "blood_oxygen")
    }
}
