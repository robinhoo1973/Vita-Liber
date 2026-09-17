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
    /// 审查修复（取消传播）：任务取消必须沿链抛出 CancellationError——
    /// 此前生成轨的取消被折叠成降级结果（.timeout/.failure/engineUnavailable），
    /// 用户撤销的导入继续跑完全部区域并产出 D 级草稿。实现可保持不抛形态
    /// （不抛方法满足抛出协议要求），真正承接生成轨的链路必须抛。
    func understand(_ input: TextUnderstandingInput) async throws -> UnderstandingResult
    func isAvailable(for input: TextUnderstandingInput) async -> Bool
}

extension TextUnderstanding {
    public func isAvailable(for input: TextUnderstandingInput) async -> Bool { true }
}
