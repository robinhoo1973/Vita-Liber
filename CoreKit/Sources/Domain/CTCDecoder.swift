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

    /// 输入形状错误（词表/类别/概率数不匹配）。`decode` 为兼容返回空结果；
    /// 影子诊断必须用 `validate` 把它记成错误，而不是当成「识别为空」。
    public enum DecodeError: Error, Sendable, Equatable {
        case invalidShape(timesteps: Int, classes: Int, probabilities: Int, vocabulary: Int, blankIndex: Int)
    }

    public static func isValid(probabilitiesCount: Int, timesteps: Int, classes: Int,
                               vocabularyCount: Int, blankIndex: Int) -> Bool {
        let (product, overflow) = timesteps.multipliedReportingOverflow(by: classes)
        return !overflow && timesteps > 0 && classes > 0 && blankIndex >= 0 && blankIndex < classes
            && vocabularyCount == classes && probabilitiesCount >= product
    }

    public static func validate(probabilitiesCount: Int, timesteps: Int, classes: Int,
                                vocabularyCount: Int, blankIndex: Int) throws {
        guard isValid(probabilitiesCount: probabilitiesCount, timesteps: timesteps, classes: classes,
                      vocabularyCount: vocabularyCount, blankIndex: blankIndex) else {
            throw DecodeError.invalidShape(timesteps: timesteps, classes: classes,
                                           probabilities: probabilitiesCount,
                                           vocabulary: vocabularyCount, blankIndex: blankIndex)
        }
    }

    /// 原始 logits → 逐帧 softmax 概率（同形状）。
    ///
    /// CnOCR 的 ONNX 输出是 logits；Paddle 的 ONNX 输出已是概率。CTC 解码的
    /// argmax 不受影响，但置信度必须用概率，否则会把 logit 当 0..1 记录。
    public static func softmax(logits: [Float], timesteps: Int, classes: Int) -> [Float]? {
        guard timesteps > 0, classes > 0 else { return nil }
        let (product, overflow) = timesteps.multipliedReportingOverflow(by: classes)
        guard !overflow, product == logits.count else { return nil }
        var output = [Float](repeating: 0, count: logits.count)
        for t in 0..<timesteps {
            let offset = t * classes
            var maxValue = logits[offset]
            for c in 1..<classes where logits[offset + c] > maxValue {
                maxValue = logits[offset + c]
            }
            var sum: Float = 0
            for c in 0..<classes {
                let value = Float(Foundation.exp(Double(logits[offset + c] - maxValue)))
                output[offset + c] = value
                sum += value
            }
            guard sum > 0, sum.isFinite else { return nil }
            for c in 0..<classes { output[offset + c] /= sum }
        }
        return output
    }

    /// 直接对 logits 做 CTC argmax 解码，不做 softmax 归一。
    ///
    /// 第三源只需要文本，不需要置信度；对每帧 6683 类做 exp/softmax 会为每行
    /// 多分配一份 [T,C] 数组并做数万次 exp，纯属浪费。argmax 与 softmax 后
    /// 的 argmax 完全等价，故文本一致；`confidence` 置 0（未校准）。
    public static func decodeArgmax(logits: [Float], timesteps: Int, classes: Int,
                                    vocabulary: [String], blankIndex: Int = 0) -> Output {
        guard isValid(probabilitiesCount: logits.count, timesteps: timesteps,
                      classes: classes, vocabularyCount: vocabulary.count,
                      blankIndex: blankIndex) else {
            return Output(text: "", confidence: 0, emittedCharacters: 0)
        }
        var text = ""
        var emitted = 0
        var previousIndex = -1
        for t in 0..<timesteps {
            let offset = t * classes
            var bestIndex = 0
            var bestValue = logits[offset]
            if classes > 1 {
                for c in 1..<classes where logits[offset + c] > bestValue {
                    bestValue = logits[offset + c]
                    bestIndex = c
                }
            }
            let collapsed = bestIndex == previousIndex
            previousIndex = bestIndex
            guard !collapsed, bestIndex != blankIndex else { continue }
            text += vocabulary[bestIndex]
            emitted += 1
        }
        return Output(text: text, confidence: 0, emittedCharacters: emitted)
    }

    public static func decode(probabilities: [Float], timesteps: Int, classes: Int,
                              vocabulary: [String], blankIndex: Int = 0) -> Output {
        guard isValid(probabilitiesCount: probabilities.count, timesteps: timesteps,
                      classes: classes, vocabularyCount: vocabulary.count,
                      blankIndex: blankIndex) else {
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
