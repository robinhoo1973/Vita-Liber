import Foundation

/// Core ML 信息元匹配结果（2026-11-06 业主：提取信息元用 Core ML 执行）。
///
/// 只描述模型对**一行文本**给出的字段键/值候选；不直接落库、不改卡，
/// 统一经 `CardExtractionRegistry` 的 grounding 第二道防线后才成为 D 级字段。
/// `sourceLineIndex` 是页行号（与 `ExtractionCell.lineIndices` 同坐标），
/// 供 BR-002 原文锚点与确认页 [原文] 使用。
public struct InformationElementMatch: Sendable, Equatable {
    public let key: String
    public let value: String
    public let unit: String?
    public let confidence: Double
    public let sourceLineIndex: Int?

    public init(key: String, value: String, unit: String? = nil,
                confidence: Double, sourceLineIndex: Int? = nil) {
        self.key = key
        self.value = value
        self.unit = unit
        self.confidence = confidence
        self.sourceLineIndex = sourceLineIndex
    }
}
