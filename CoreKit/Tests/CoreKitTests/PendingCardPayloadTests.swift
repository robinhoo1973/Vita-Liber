import Foundation
import Testing
@testable import Domain

// binds: SU-M2-PENDINGCARD
/// FR6.9 V3.61：待办卡 partial_data 从「键→值」升级为「共享字段 + 多行」（每类一卡多行），
/// 旧 JSON（纯字典）必须仍可读——视为全部共享字段。
@Suite("SU-M2-PENDINGCARD · 待办卡多行载荷（partial_data 兼容）")
struct PendingCardPayloadTests {
    @Test func 旧字典JSON读为共享字段() {
        let payload = PendingCardPayload.decode(#"{"drug_name":"阿莫西林","hospital":"市一医院"}"#)
        #expect(payload.shared == ["drug_name": "阿莫西林", "hospital": "市一医院"])
        #expect(payload.rows.isEmpty)
    }

    @Test func 新载荷往返相等() {
        let payload = PendingCardPayload(shared: ["measured_at": "2026-09-01"],
                                         rows: [["raw_label": "血红蛋白", "value": "150", "unit": "g/L"],
                                                ["raw_label": "白细胞", "value": "6.5"]])
        let decoded = PendingCardPayload.decode(payload.json)
        #expect(decoded == payload)
        #expect(decoded.rows.count == 2)
    }

    @Test func 非法JSON回落空载荷不崩溃() {
        let payload = PendingCardPayload.decode("not json")
        #expect(payload == PendingCardPayload())
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
}
