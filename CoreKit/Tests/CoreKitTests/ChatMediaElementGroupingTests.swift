import Testing
import Foundation
@testable import Domain

/// 识别结果页分组纪律（2026-11-01 业主；mock 第 3 帧）：
/// 共享字段单独成组，每个药品/检验行各自成组；空值、内部键不进 UI；
/// 同组同键只保留首个值（不把重复识别拼成两行）。
@Suite("聊天识别结果要素分组")
struct ChatMediaElementGroupingTests {
    private func field(_ key: String, _ value: String) -> FieldDraft {
        FieldDraft(key: key, value: value, confidence: 0.8)
    }

    @Test("共享字段与每个行各自成组，保留行上下文")
    func separatesSharedAndRows() {
        let groups = ChatMediaElementGrouping.groups(
            cardID: "c1",
            shared: [field("hospital", "协和医院"), field("date", "2026-03-12")],
            rows: [
                [field("drug_name", "氨氯地平"), field("dose", "1 片"),
                 field("frequency", "每日一次")],
                [field("drug_name", "阿托伐他汀"), field("dose", "1 片")],
            ])
        #expect(groups.count == 3)
        #expect(groups[0].rowIndex == nil)
        #expect(groups[0].fields.map(\.key) == ["hospital", "date"])
        #expect(groups[1].rowIndex == 0)
        #expect(groups[1].fields.map(\.key) == ["drug_name", "dose", "frequency"])
        #expect(groups[2].rowIndex == 1)
        #expect(groups[2].fields.map(\.key) == ["drug_name", "dose"])
    }

    @Test("空值与内部键被过滤，空组不出现")
    func dropsEmptyAndInternalKeys() {
        let groups = ChatMediaElementGrouping.groups(
            cardID: "c2",
            shared: [field("metric_key", "hgb"), field("note", "  ")],
            rows: [[field("item", "血红蛋白"), field("result", "150"),
                    field("unit", "g/L"), field("extra", "")]])
        #expect(groups.count == 1)
        #expect(groups[0].rowIndex == 0)
        #expect(groups[0].fields.map(\.key) == ["item", "result", "unit"])
    }

    @Test("同组同键去重，保留首个非空值")
    func deduplicatesKeysWithinGroup() {
        let groups = ChatMediaElementGrouping.groups(
            cardID: "c3",
            shared: [field("hospital", "协和医院"), field("hospital", "另一值")],
            rows: [])
        #expect(groups.count == 1)
        #expect(groups[0].fields.count == 1)
        #expect(groups[0].fields[0].value == "协和医院")
    }

    @Test("完全空卡不产生任何组")
    func emptyCardProducesNoGroups() {
        let groups = ChatMediaElementGrouping.groups(
            cardID: "c4", shared: [], rows: [[], []])
        #expect(groups.isEmpty)
    }
}
