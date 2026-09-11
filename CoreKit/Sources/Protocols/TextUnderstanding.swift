import Foundation
import Domain

/// FR17.18 共享文本理解层端口（tech §5.13 / coreml-minilm-spec §4.1）：
/// 识别后文本（OCR 行文本 / 语音整句）→ 结构化字段草稿 + 去向判定，
/// 全 D 级（BR-003）。三轨同一端口（ADR-029）：主轨 Foundation Models
/// （iOS 26+）→ 备轨 Core ML 量化编码器 → 兜底轨 NL+正则+词表，
/// 上层零感知，降级零崩溃。
public protocol TextUnderstanding: Sendable {
    /// 识别后文本 → 统一 `UnderstandingResult`（去向判定 + D 级字段草稿）。
    /// 紧急关键词前置（BR-012）在**进入本层之前**由调用方执行（语音侧）。
    func understand(_ input: TextUnderstandingInput) async -> UnderstandingResult
    func isAvailable(for input: TextUnderstandingInput) async -> Bool
}

extension TextUnderstanding {
    public func isAvailable(for input: TextUnderstandingInput) async -> Bool { true }
}

/// 契约桩（非 Apple 平台与测试装配）：零产出——Linux 门禁/单测
/// 不依赖系统自然语言框架；Apple 平台经工厂装配真实兜底轨。
public actor StubTextUnderstanding: TextUnderstanding {
    public init() {}
    public func understand(_ input: TextUnderstandingInput) async -> UnderstandingResult {
        UnderstandingResult(suggestedTarget: nil, targetConfidence: 0, fields: [], engineUnavailable: true)
    }
}
