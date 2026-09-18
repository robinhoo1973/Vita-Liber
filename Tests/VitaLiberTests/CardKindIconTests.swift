import XCTest
import SwiftUI
import Domain
import Infrastructure
@testable import VitaLiber

/// v27 子项目 J · round1 §E.7 V11：卡类图标单一出口穷尽性——`TimelineEntryKind` 全 case 有符号；
/// 注册卡类不得回落文档图标；仅附件文档键回落文档图标；就诊关联卡 / 子卡类 / 卡类字符串三路归并到同一表。
// binds: SU-M1c-REGRESSION（ui-ux §3.4 卡类图标表 / round1 §E.7 V11 / BR-004 色按类型不按严重度；TC 登记 J5）
final class CardKindIconTests: XCTestCase {
    /// 原名：test_时间轴全类型均有符号_且v27十二类不回落文档图标
    func test_timelineAllTypesHaveSymbols_v27TwelveKindsNoDocumentFallback() {
        for kind in TimelineEntryKind.allCases {
            XCTAssertFalse(CardKindIcon.spec(timelineKind: kind).symbol.isEmpty, kind.rawValue)
        }
        let v27: [TimelineEntryKind] = [.hospitalization, .healthExam, .diagnosis, .prescription, .labReport, .examReport,
                                        .claim, .surgery, .treatmentRecord, .appointment, .reminder, .clinicalConclusion]
        for kind in v27 {
            XCTAssertNotEqual(CardKindIcon.symbol(for: kind), "doc.text", kind.rawValue)
        }
        XCTAssertEqual(CardKindIcon.symbol(for: TimelineEntryKind.healthExam), "heart.text.square")
        XCTAssertEqual(CardKindIcon.symbol(for: TimelineEntryKind.surgery), "scissors")
        XCTAssertEqual(CardKindIcon.symbol(for: TimelineEntryKind.treatmentRecord), "cross.vial")
        XCTAssertEqual(CardKindIcon.symbol(for: TimelineEntryKind.appointment), "calendar.badge.clock")
        XCTAssertEqual(CardKindIcon.symbol(for: TimelineEntryKind.reminder), "bell")
        XCTAssertEqual(CardKindIcon.symbol(for: TimelineEntryKind.diagnosis), "list.clipboard")
        XCTAssertEqual(CardKindIcon.symbol(for: TimelineEntryKind.clinicalConclusion), "text.quote")
    }

    /// 原名：test_注册卡类字符串不回落文档图标_未知键回落
    func test_registeredCardKindsNoDocumentFallback_unknownKeyFallsBack() {
        for entry in CardKindRegistry.entries {
            XCTAssertNotEqual(CardKindIcon.spec(cardKind: entry.kind).symbol, "doc.text", entry.kind)
            XCTAssertNotEqual(CardKindIcon.timelineKind(cardKind: entry.kind), .document, entry.kind)
        }
        XCTAssertEqual(CardKindIcon.spec(cardKind: "lab_report").symbol, CardKindIcon.symbol(for: TimelineEntryKind.labReport))
        XCTAssertEqual(CardKindIcon.spec(cardKind: "nonexistent").symbol, "doc.text")
    }

    /// 原名：test_就诊关联卡类与子卡类归并到同一表
    func test_encounterCardKindsAndSubKindsMergeIntoSameTable() {
        let linked: [(EncounterStore.LinkedCardRow.Kind, TimelineEntryKind)] = [
            (.prescription, .prescription), (.claim, .claim), (.medication, .medication), (.metricSample, .lab),
            (.immunization, .vaccination), (.encounter, .encounter), (.hospitalization, .hospitalization), (.diagnosis, .diagnosis),
            (.examReport, .examReport), (.labReport, .labReport), (.surgery, .surgery), (.treatmentRecord, .treatmentRecord),
            (.appointment, .appointment), (.reminder, .reminder),
        ]
        for (kind, expected) in linked {
            XCTAssertEqual(CardKindIcon.timelineKind(linkedKind: kind), expected, kind.rawValue)
            XCTAssertEqual(CardKindIcon.symbol(linked: kind), CardKindIcon.symbol(for: expected), kind.rawValue)
        }
        for child in RecordChildKind.allCases {
            XCTAssertEqual(CardKindIcon.symbol(child: child), CardKindIcon.symbol(for: child.timelineKind), child.rawValue)
        }
        XCTAssertEqual(CardKindIcon.symbol(hub: .healthExam), CardKindIcon.symbol(for: TimelineEntryKind.healthExam))
        XCTAssertEqual(CardKindIcon.spec(hub: .encounter, hospitalized: true).symbol, CardKindIcon.symbol(for: TimelineEntryKind.hospitalization))
    }

    /// 原名：test_文档稳定键_结构化目标首卡类图标_仅附件回落文档
    func test_documentStableKey_structuredTargetPrimaryIcon_attachmentOnlyFallsBack() {
        XCTAssertEqual(CardKindIcon.spec(documentTypeKey: "medical_order").symbol, "doc.text")
        XCTAssertEqual(CardKindIcon.spec(documentTypeKey: "consent_form").symbol, "doc.text")
        XCTAssertEqual(CardKindIcon.spec(documentTypeKey: nil).symbol, "doc.text")
        XCTAssertEqual(CardKindIcon.spec(documentTypeKey: "checkup_report").symbol, CardKindIcon.symbol(for: TimelineEntryKind.healthExam))
        XCTAssertEqual(CardKindIcon.spec(documentTypeKey: "prescription").symbol, CardKindIcon.symbol(for: TimelineEntryKind.prescription))
        XCTAssertEqual(CardKindIcon.spec(documentTypeKey: "surgery_record").symbol, CardKindIcon.symbol(for: TimelineEntryKind.surgery))
    }
}
