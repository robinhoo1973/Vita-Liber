import Testing
import Foundation
@testable import VitaLiber

/// 聊天媒体回执文案的 BR-003/BR-006 口径（2026-10-29 批三；UX/测试席要求背负）。
/// 两个 OCR 回执 + 语音回执必须：① 声明识别事实；② 含「确认前不进入…」边界句
/// （零字段模板同）；③ 不出现诊断/因果/分诊/剂量结论类措辞（措辞负清单子集）。
@Suite("聊天媒体回执口径")
struct ChatMediaCopyTests {
    /// 负向措辞子集：命中任一即失败（与 L0 措辞扫描同族的最小可断言集）。
    private let forbidden = ["确诊", "诊断为", "考虑为", "可能患有", "建议服用",
                             "建议停药", "调整剂量", "预后", "病情评估"]

    private var replies: [(name: String, text: String)] {
        [
            ("ocrReplyFmt", L10n.assistantOcrReply(3)),
            ("ocrReplyPlain", L10n.assistantOcrReplyPlain),
            ("voiceReply", L10n.assistantVoiceReply),
            ("mediaDetailHint", L10n.assistantMediaDetailHint),
            ("mediaLoadFailed", L10n.assistantMediaLoadFailed),
            ("mediaLegacyNote", L10n.assistantMediaLegacyNote),
            ("tabText", L10n.assistantMediaTabText),
            ("tabCards", L10n.assistantMediaTabCards),
            ("textEmpty", L10n.assistantMediaTextEmpty),
            ("cardsEmpty", L10n.assistantMediaCardsEmpty),
            ("openOriginal", L10n.assistantMediaOpenOriginal),
            ("pageFailed", L10n.assistantMediaPageFailed),
            ("pageNoText", L10n.assistantMediaPageNoText),
            ("egressNote", L10n.assistantMediaEgressNote),
            ("egressNoteMirror", L10n.assistantMediaEgressNoteMirror),
            // 2026-10-30 批新增边界句（卡片页脚 D 级 / 语音摘要仅摘录）：
            // 同纳入负向措辞清单，防后续改文案绕过 BR-003/BR-006。
            ("mediaCardsFootnote", L10n.chatMediaCardsFootnote),
            ("voiceSummaryNote", L10n.chatVoiceSummaryNote),
        ]
    }

    @Test("全部媒体文案非空且不含措辞负清单子集")
    func allCopyNonEmptyAndNegativeListClean() {
        for reply in replies {
            #expect(!reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(reply.name) 不得为空")
            for word in forbidden {
                #expect(!reply.text.contains(word),
                        "\(reply.name) 命中负向措辞「\(word)」")
            }
        }
    }

    @Test("OCR 两模板均带 D 级边界句（确认前不进入计划/急救卡/AI 事实）")
    func ocrTemplatesCarryBoundary() {
        for reply in [L10n.assistantOcrReply(3), L10n.assistantOcrReplyPlain] {
            if L10n.assistantMediaTabText.contains("识别") {
                // zh 语区：边界句关键片段
                #expect(reply.contains("确认前不会进入"))
                #expect(reply.contains("用药计划"))
                #expect(reply.contains("急救卡"))
                #expect(reply.contains("AI 事实"))
            }
        }
    }

    @Test("字段数模板如实携带入参")
    func ocrReplyCarriesFieldCount() {
        #expect(L10n.assistantOcrReply(7).contains("7"))
    }
}
