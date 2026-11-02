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


    @Test("保留行 ID 与字段源行号，供裁片/引文锚定")
    func keepsRowIdentityAndSourceLine() {
        let row = MatchedCardRow(id: UUID(), fields: [
            FieldDraft(key: "drug_name", value: "氨氯地平", confidence: 0.8,
                       rawText: "氨氯地平 5mg 每日一次", sourceLineIndex: 4)
        ])
        let card = MatchedCard(id: UUID(), kind: "prescription", pageIndex: 0,
                               shared: [], rows: [row], allFieldCoverage: 0,
                               requiredCoverage: 0, missingRequired: [],
                               level: .partiallyComplete)
        let groups = ChatMediaElementGrouping.groups(cardID: "c5", card: card)
        #expect(groups.count == 1)
        #expect(groups[0].rowId == row.id)
        #expect(groups[0].fields[0].sourceLineIndex == 4)
        #expect(groups[0].fields[0].sourceText == "氨氯地平 5mg 每日一次")
    }


    @Test("编辑模式保留空值字段，避免清空后卡片消失")
    func includeEmptyKeepsEditableField() {
        let card = MatchedCard(id: UUID(), kind: "encounter", pageIndex: 0,
                               shared: [FieldDraft(key: "hospital", value: "", confidence: 0.8)],
                               rows: [MatchedCardRow(id: UUID(), fields: [])],
                               allFieldCoverage: 0, requiredCoverage: 0,
                               missingRequired: [], level: .partiallyComplete)
        let readOnly = ChatMediaElementGrouping.groups(cardID: "c6", card: card)
        #expect(readOnly.isEmpty)
        let editable = ChatMediaElementGrouping.groups(cardID: "c6", card: card, includeEmpty: true)
        #expect(editable.count == 1)
        #expect(editable[0].fields.map(\.key) == ["hospital"])
        #expect(editable[0].fields[0].value.isEmpty)
    }

    @Test("组头动作：保存中优先、脏才保存、只读无动作")
    func groupActionPriority() {
        #expect(ChatMediaElementGrouping.groupAction(editable: true, saving: false,
                                                      dirty: false, saved: false) == .none)
        #expect(ChatMediaElementGrouping.groupAction(editable: true, saving: false,
                                                      dirty: true, saved: false) == .save)
        #expect(ChatMediaElementGrouping.groupAction(editable: true, saving: true,
                                                      dirty: true, saved: false) == .saving)
        #expect(ChatMediaElementGrouping.groupAction(editable: true, saving: false,
                                                      dirty: false, saved: true) == .saved)
        #expect(ChatMediaElementGrouping.groupAction(editable: false, saving: false,
                                                      dirty: true, saved: false) == .none)
    }

    @Test("完全空卡不产生任何组")
    func emptyCardProducesNoGroups() {
        let groups = ChatMediaElementGrouping.groups(
            cardID: "c4", shared: [], rows: [[], []])
        #expect(groups.isEmpty)
    }

    @Test("拒绝字段保留拒绝标记；C 徽章以 isConfirmed 为准")
    func keepsRejectedAndConfirmationProvenance() {
        let rejected = FieldDraft(key: "result", value: "12", confidence: 0.8,
                                  grade: .rejected)
        let confirmed = FieldDraft(key: "item", value: "血红蛋白", confidence: 0.8,
                                   grade: .userConfirmed)
        var overstated = FieldDraft(key: "unit", value: "g/L", confidence: 0.8)
        overstated.grade = .userConfirmed   // 无 reviewedValue：不是真的已核对
        let groups = ChatMediaElementGrouping.groups(
            cardID: "c7", shared: [rejected, confirmed, overstated], rows: [])
        #expect(groups.count == 1)
        #expect(groups[0].fields[0].isRejected)
        #expect(groups[0].fields[0].grade == "D")
        #expect(!groups[0].fields[1].isRejected)
        #expect(groups[0].fields[1].grade == "C")
        #expect(groups[0].fields[2].grade == "D")
    }
}
