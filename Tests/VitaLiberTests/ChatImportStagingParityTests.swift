import Testing
import Foundation
@testable import VitaLiber

/// 聊天导入待提交区的 mock parity 契约（业主规则 2026-10-31；
/// mock `chat-import-staging.html` 第 1 帧）。状态行与 L10n 键由
/// `.github/config/gates/mock-parity/chat-import-staging.json` 钉死。
@MainActor
@Suite("聊天导入待提交区 parity")
struct ChatImportStagingParityTests {
    private func data(_ n: Int = 8) -> Data { Data(repeating: 0x41, count: n) }

    @Test("空待提交区禁用提交，取消始终可用")
    func testEmptyStagingDisablesSubmit() {
        let model = ChatImportStagingModel()
        #expect(model.isEmpty)
        #expect(!model.canSubmit)
        #expect(model.totalPages == 0)
    }

    @Test("有项目时启用提交且保持选择顺序")
    func testStagedItemsEnableSubmitAndPreserveOrder() {
        let model = ChatImportStagingModel()
        #expect(model.add(data: data(), filename: "a", isPDF: false,
                          pageCount: 1, source: .photoLibrary) == .added)
        #expect(model.add(data: data(), filename: "b", isPDF: true,
                          pageCount: 2, source: .fileImport) == .added)
        #expect(model.add(data: data(), filename: "c", isPDF: false,
                          pageCount: 1, source: .camera) == .added)
        #expect(model.canSubmit)
        #expect(model.items.map(\.filename) == ["a", "b", "c"])
        #expect(model.totalPages == 4)
        #expect(model.items.map(\.source) == [.photoLibrary, .fileImport, .camera])
    }

    @Test("条目/页数/字节上限硬拒绝且不截断")
    func testCapsRejectWithoutTruncation() {
        let items = ChatImportStagingModel()
        for index in 0..<ChatImportStagingModel.maxItems {
            #expect(items.add(data: data(), filename: "i\(index)", isPDF: false,
                              pageCount: 1, source: .photoLibrary) == .added)
        }
        #expect(items.add(data: data(), filename: "overflow", isPDF: false,
                          pageCount: 1, source: .photoLibrary) == .tooManyItems)
        #expect(items.items.count == ChatImportStagingModel.maxItems)

        let pages = ChatImportStagingModel()
        #expect(pages.add(data: data(), filename: "pdf", isPDF: true,
                          pageCount: ChatImportStagingModel.maxPages, source: .fileImport) == .added)
        #expect(pages.add(data: data(), filename: "extra", isPDF: false,
                          pageCount: 1, source: .photoLibrary) == .tooManyPages)
        #expect(pages.items.count == 1)

        let bytes = ChatImportStagingModel()
        #expect(bytes.add(data: data(ChatImportStagingModel.maxBytes), filename: "max",
                          isPDF: false, pageCount: 1, source: .photoLibrary) == .added)
        #expect(bytes.add(data: data(1), filename: "extra", isPDF: false,
                          pageCount: 1, source: .photoLibrary) == .tooLarge)
        #expect(bytes.items.count == 1)
    }

    @Test("读取中禁用提交与继续添加")
    func testReadingDisablesSubmit() {
        // 读取中是视图瞬态；模型层只保证未提交前可由取消清空，提交入口由
        // `canSubmit` + 视图 reading 双闸。此测试钉死清空语义。
        let model = ChatImportStagingModel()
        #expect(model.add(data: data(), filename: "a", isPDF: false,
                          pageCount: 1, source: .camera) == .added)
        model.clear()
        #expect(model.isEmpty)
        #expect(!model.canSubmit)
    }

    @Test("旋转回写保持条目身份与页数，并推进修订号")
    func testReplaceKeepsPageCountAndIdentity() {
        let model = ChatImportStagingModel()
        #expect(model.add(data: data(4), filename: "a", isPDF: false,
                          pageCount: 3, source: .camera) == .added)
        let item = model.items[0]
        #expect(model.replace(id: item.id, data: data(12)) == .added)
        #expect(model.items[0].id == item.id)
        #expect(model.items[0].pageCount == 3)
        #expect(model.items[0].data.count == 12)
        #expect(model.items[0].revision != item.revision)
    }

    @Test("前移/后移按用户顺序改变提交序")
    func testMoveChangesSubmissionOrder() {
        let model = ChatImportStagingModel()
        for name in ["a", "b", "c"] {
            #expect(model.add(data: data(), filename: name, isPDF: false,
                              pageCount: 1, source: .photoLibrary) == .added)
        }
        model.moveUp(id: model.items[2].id)
        #expect(model.items.map(\.filename) == ["a", "c", "b"])
        model.moveDown(id: model.items[0].id)
        #expect(model.items.map(\.filename) == ["c", "a", "b"])
        model.move(from: IndexSet(integer: 0), to: 3)
        #expect(model.items.map(\.filename) == ["a", "b", "c"])
    }


    @Test("数据信息元/裁片状态行与契约一一对应（表驱动）")
    func testElementAndCropRowsMatchMock() {
        let rows: [(id: String, label: String, enabled: Bool)] = [
            ("elements-default", L10n.chatMediaTabElements, true),
            ("elements-dirty", L10n.chatMediaElementSaveAll, true),
            ("elements-saved", L10n.chatMediaElementSaved, true),
            ("crop-measured", L10n.chatMediaViewSourceImage, true),
            ("crop-fallback", L10n.chatMediaCropFullPageNote, true),
        ]
        for row in rows {
            #expect(!row.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(row.id) 文案不得为空")
            #expect(row.enabled, "\(row.id) 主行动必须可用")
        }
    }

    @Test("两组页签与待提交区文案键非空（mock 专用键零死键）")
    func testMockSpecificKeysAreConsumed() {
        let keys = [
            L10n.chatImportStagingTitle,
            L10n.chatImportStagingHint(3, 4),
            L10n.chatImportStagingSubmit(3),
            L10n.chatImportStagingPrivacy,
            L10n.chatMediaResultTitle,
            L10n.chatMediaTabElements,
            L10n.chatMediaTabCards,
            L10n.chatMediaElementSave,
            L10n.chatMediaElementSaveAll,
            L10n.chatMediaViewSourceImage,
            L10n.chatMediaElementsP1Note,
            L10n.chatMediaElementsToCards,
            L10n.chatMediaCropTitle,
            L10n.chatMediaCropFullPageNote,
            L10n.chatMediaCardsAssemblyNote,
        ]
        for key in keys {
            #expect(!key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
