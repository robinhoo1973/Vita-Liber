import Foundation
import Testing
@testable import Domain

// binds: SU-M2-PENDINGCARD
/// FR6.9 V3.61：待办卡 partial_data 从「键→值」升级为「共享字段 + 多行」（每类一卡多行），
/// 旧 JSON（纯字典）必须仍可读——视为全部共享字段。
@Suite("SU-M2-PENDINGCARD · 待办卡多行载荷（partial_data 兼容）")
struct PendingCardPayloadTests {
    @Test func 旧字典JSON按实际卡类恢复行() throws {
        let payload = try PendingCardPayload.decode(#"{"drug_name":"阿莫西林","hospital":"市一医院"}"#, cardKind: "prescription")
        #expect(payload.shared == ["hospital": "市一医院"])
        #expect(payload.rows == [["drug_name": "阿莫西林"]])
    }

    @Test func 新载荷往返相等() throws {
        let payload = PendingCardPayload(shared: ["measured_at": "2026-09-01"],
                                         rows: [["raw_label": "血红蛋白", "value": "150", "unit": "g/L"],
                                                ["raw_label": "白细胞", "value": "6.5"]])
        let decoded = try PendingCardPayload.decode(payload.json)
        #expect(decoded == payload)
        #expect(decoded.rows.count == 2)
    }

    @Test func invalidJSONIsVisibleCorruption() {
        #expect(throws: (any Error).self) { try PendingCardPayload.decode("not json") }
        #expect(throws: (any Error).self) {
            try PendingCardPayload.decode(#"{"shared":{},"rows":[{"value":12}]}"#)
        }
    }

    @Test func 从匹配卡构造载荷保留行序() {
        let card = MatchedCard(kind: "metric_sample", pageIndex: 3,
                               shared: [FieldDraft(key: "measured_at", value: "2026-09-01")],
                               rows: [MatchedCardRow(fields: [FieldDraft(key: "raw_label", value: "A"), FieldDraft(key: "value", value: "1")]),
                                      MatchedCardRow(fields: [FieldDraft(key: "raw_label", value: "B"), FieldDraft(key: "value", value: "2")])],
                               allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        let payload = PendingCardPayload(card: card)
        #expect(payload.shared == ["measured_at": "2026-09-01"])
        #expect(payload.rows.map { $0["raw_label"] } == ["A", "B"])
    }

    @Test func fullSnapshotPreservesReviewOriginalsAndStableIdentities() throws {
        var field = FieldDraft(key: "raw_label", value: "Original", confidence: 0.42, rawText: "OCR Original")
        field.value = "Corrected"
        _ = field.confirm()
        var rejected = FieldDraft(key: "unit", value: "bad", confidence: 0.3)
        rejected.reject()
        let card = MatchedCard(kind: "metric_sample", pageIndex: 2, shared: [],
                               rows: [MatchedCardRow(fields: [field, rejected])],
                               allFieldCoverage: 0.5, requiredCoverage: 0.8, missingRequired: [], level: .partiallyComplete)
        let decoded = try PendingCardPayload.decode(PendingCardPayload(card: card).json, cardKind: card.kind)
        #expect(decoded.card == card)
        #expect(decoded.card?.rows[0].fields[0].originalValue == "Original")
        #expect(decoded.card?.rows[0].fields[0].isConfirmed == true)
        #expect(decoded.card?.rows[0].fields[1].grade == .rejected)
    }

    @Test func legacyRowIDsAreStableAcrossReads() throws {
        let payload = try PendingCardPayload.decode(#"{"drug_name":"A","prescribed_at":"2020-01-01"}"#, cardKind: "prescription")
        let id = UUID()
        let first = try payload.matchedCard(kind: "prescription", pageIndex: 0, id: id)
        let second = try payload.matchedCard(kind: "prescription", pageIndex: 0, id: id)
        #expect(first == second)
        #expect(first.rows.count == 1)
        #expect(first.allFields.allSatisfy { !$0.isConfirmed })
    }

    @Test func originallyAbsentUnitStaysAbsentAfterMetadataRoundTrip() throws {
        var field = FieldDraft(key: "raw_label", value: "A")
        field.unit = "g/L"
        _ = field.confirm()
        let data = try JSONEncoder().encode(field)
        let restored = try JSONDecoder().decode(FieldDraft.self, from: data)
        #expect(restored.originalUnit == nil)
        #expect(restored.unit == "g/L")
        #expect(restored == field)
    }
}
