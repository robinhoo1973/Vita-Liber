import Foundation
import Domain

/// FR12.11 图片文字识别端口。识别结果一律 D 级待确认（BR-003）——
/// 该判定在 Domain `ImageInputRules`，实现只负责产出文本行与置信度。
public protocol ImageTextRecognizing: Sendable {
    /// 从图片数据识别文字（零落盘：入参出参不含文件路径，实现内部流式处理）
    func recognize(_ imageData: Data) async throws -> ImageInputRules.Recognition
}

/// 测试/Preview 替身：脚本化识别结果。
public actor StubImageTextRecognizer: ImageTextRecognizing {
    private let scripted: ImageInputRules.Recognition
    public init(scripted: ImageInputRules.Recognition) { self.scripted = scripted }
    public func recognize(_ imageData: Data) async throws -> ImageInputRules.Recognition {
        scripted
    }
}
