import Foundation

/// FR12.11 AI 图片/文档输入的 Domain 判据。
///
/// 图片识别结果一律标注「识别未确认」（D 级）——BR-003 在图片路径上的落点：
/// 机器识别的文本**不得**成为确定性陈述、不得进入计划/急救卡/AI 事实。
/// 纯影像无文字 → 「未识别到文字」+ 手输替代建议。
public enum ImageInputRules {

    public struct Recognition: Sendable, Equatable {
        /// 识别出的文本行（按序）
        public var lines: [String]
        /// 识别置信度（Vision 引擎输出，0..1）
        public var confidence: Double
        public init(lines: [String], confidence: Double) {
            self.lines = lines; self.confidence = confidence
        }
        public var text: String { lines.joined(separator: "\n") }
        public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 识别文本 → 待确认字段（**恒 D 级**，无论引擎置信度多高——
    /// 「识别未确认」是来源属性不是质量属性，BR-003）
    public static func draftFields(from recognition: Recognition) -> [CandidateField] {
        // 与 isEmpty 同源判定（trim 后为空 = 无文字）——两处曾不一致：
        // isEmpty 判 trim 后、本函数判原始串，导致「只有空白」的识别
        // 一边说无文字、一边产出空白草稿。
        guard !recognition.isEmpty else { return [] }
        let body = recognition.text
        return [CandidateField(key: "image_text", displayLabel: "图片识别文本",
                               rawText: body, confidence: recognition.confidence,
                               value: body, grade: .ocrUnconfirmed)]
    }

    /// 无文字时的降级文案（纯事实 + 手输替代——不含建议/应该等负清单词，
    /// BR-006 措辞纪律同样适用）
    public static let noTextMessage = "未识别到文字。你可以直接输入报告内容，或换一张更清晰的照片。"
    public static let noTextKey = "image_input.noText"

    /// 图片文本可否直接作为「提问」提交：
    /// - 有文字 → 必须先经确认卡（用户逐条确认后才可提交，BR-003）；
    /// - 无文字 → 返回 nil，UI 展示 `noTextMessage`。
    public static func requiresConfirmation(_ recognition: Recognition) -> Bool {
        !recognition.isEmpty
    }
}
