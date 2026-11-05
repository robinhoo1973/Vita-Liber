import Foundation

/// OCR 行级第三源共识（纯函数）：Paddle 主轨 + Vision/CnOCR 两副源。
///
/// 只有两个副源都在场、且选择器真的产生替换时才返回新文本；单副源（Vision 一块
/// 多行、CnOCR 缺件/失败）一律 nil，调用方保留 Paddle 原文。数字/单位/否定/极性
/// 的保护由 `TranscriptionConsensusSelector` 统一执行。
public enum OCRLineConsensus {
    public static func select(primary: String, vision: String?, cnocr: String?,
                              policy: HypothesisFusionPolicy) -> String? {
        guard let cnocr, !cnocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        var secondaries: [TranscriptionHypothesis] = []
        if let vision, !vision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            secondaries.append(TranscriptionHypothesis(engineID: "apple-vision",
                                                       localeIdentifier: "zh-Hans-CN",
                                                       text: vision))
        }
        secondaries.append(TranscriptionHypothesis(engineID: "cnocr",
                                                   localeIdentifier: "zh-Hans-CN",
                                                   text: cnocr))
        guard secondaries.count >= TranscriptionConsensusSelector.minimumAgreement else {
            return nil
        }
        let result = TranscriptionConsensusSelector.select(
            primary: TranscriptionHypothesis(engineID: "paddle",
                                             localeIdentifier: "zh-Hans-CN", text: primary),
            secondaries: secondaries, policy: policy)
        return result.edits.isEmpty ? nil : result.text
    }

    /// CnOCR 词表里的控制占位：`<space>` 还原为空格，`<unusedN>` 丢弃。
    public static func cleanText(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "<space>", with: " ")
        while let start = value.range(of: "<unused") {
            guard let end = value[start.lowerBound...].firstIndex(of: ">") else { break }
            value.removeSubrange(start.lowerBound..<value.index(after: end))
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
