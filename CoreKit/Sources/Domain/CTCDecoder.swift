import Foundation

/// PP-OCRv6 CTC 贪心解码（2026-11-03 调参批）。
///
/// 纯函数、零框架：输入为 recognition 头的 `[T, classes]` 概率（模型已在
/// 图内 Softmax）；`vocabulary` 必须是完整词表（blank + 字典 + 尾空格），
/// 长度必须等于 `classes`。置信度 = 被选中非 blank 字符概率均值，仅作
/// 影子对照排序，不进入 BR-003 的事实链。
public enum CTCDecoder {
    public struct Output: Sendable, Equatable {
        public var text: String
        public var confidence: Double
        public var emittedCharacters: Int

        public init(text: String, confidence: Double, emittedCharacters: Int) {
            self.text = text
            self.confidence = confidence
            self.emittedCharacters = emittedCharacters
        }
    }

    public static func decode(probabilities: [Float], timesteps: Int, classes: Int,
                              vocabulary: [String], blankIndex: Int = 0) -> Output {
        guard timesteps > 0, classes > 0, blankIndex >= 0, blankIndex < classes,
              vocabulary.count == classes,
              probabilities.count >= timesteps * classes else {
            return Output(text: "", confidence: 0, emittedCharacters: 0)
        }
        var text = ""
        var confidenceSum = 0.0
        var emitted = 0
        var previousIndex = -1
        for t in 0..<timesteps {
            let offset = t * classes
            var bestIndex = 0
            var bestValue = probabilities[offset]
            if classes > 1 {
                for c in 1..<classes {
                    let value = probabilities[offset + c]
                    if value > bestValue { bestValue = value; bestIndex = c }
                }
            }
            let collapsed = bestIndex == previousIndex
            previousIndex = bestIndex
            guard !collapsed, bestIndex != blankIndex else { continue }
            text += vocabulary[bestIndex]
            confidenceSum += Double(bestValue)
            emitted += 1
        }
        return Output(text: text,
                      confidence: emitted > 0 ? confidenceSum / Double(emitted) : 0,
                      emittedCharacters: emitted)
    }
}
