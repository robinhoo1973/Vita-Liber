import Foundation
import Domain
import Protocols
#if canImport(FoundationModels)
import FoundationModels
#endif

/// FR17.9/FR17.18（V3.61 实装，ADR-029 期三主轨的首个消费点）：端侧 Foundation Models 润色。
///
/// 门控三层：① 编译期 `canImport(FoundationModels)`（CI SDK 无该框架时整段编译为不可用分支——
/// 功能只能 iOS 26 真机验证）；② 运行期 `@available(iOS 26, macOS 26, *)` +
/// `SystemLanguageModel.default.availability == .available`；③ App 层 `authAI` 授权（不在本类）。
/// 安全合同：指令限定「仅断句/标点/明显同音错字」；输出经 `ProtectedTokenValidator` 校验，
/// 任一受保护 token 改变即回原文；1.5s 超时回原文；任何错误回原文（不阻塞保存）。
public struct LocalTranscriptRefiner: TextRefining {
    public static let timeoutNanos: UInt64 = 1_500_000_000

    public init() {}

    public var isAvailable: Bool {
        get async {
            #if canImport(FoundationModels)
            if #available(iOS 26, macOS 26, *) {
                if case .available = SystemLanguageModel.default.availability { return true }
            }
            #endif
            return false
        }
    }

    public func refine(_ original: String, localeIdentifier: String, drugNames: [String]) async -> TranscriptRevision {
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unavailable(original) }
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            guard case .available = SystemLanguageModel.default.availability else { return .unavailable(original) }
            let prompt = trimmed
            let work = Task { () -> String in
                let session = LanguageModelSession(instructions: Self.instructions)
                let response = try await session.respond(to: prompt)
                return response.content
            }
            let timeout = Task { () -> Void in
                try await Task.sleep(nanoseconds: Self.timeoutNanos)
                work.cancel()
            }
            defer { timeout.cancel() }
            do {
                let suggested = try await work.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !suggested.isEmpty else { return .unavailable(original) }
                let safety = ProtectedTokenValidator.validate(original: trimmed, suggested: suggested, drugNames: drugNames)
                return TranscriptRevision(original: original, suggested: suggested, safety: safety)
            } catch is CancellationError {
                return .timedOut(original)
            } catch {
                return .unavailable(original)
            }
        }
        #endif
        return .unavailable(original)
    }

    /// 模型指令（非医疗、非事实扩写；语言清理的边界与 FR17.18 一致）
    static let instructions = """
    你是语音转写文本的清理助手。只做：补标点、断句、修正明显的同音错字。
    绝对不要：改动任何数字、单位、日期、时间、药名、人名，不要增删「没有/不/未/无」等否定词，
    不要补充、解释或改写医学内容，不要加入任何新信息。只输出清理后的文本本身。
    """
}

// MARK: - EAL 第 9 工厂

/// 端侧润色引擎工厂（ADR-027）：Apple 平台返回 `LocalTranscriptRefiner`（运行期自行门控）；
/// 其余平台返回不可用替身。
public enum TextRefinerFactory: EngineFactory {
    public typealias Capability = any TextRefining
    public static var onDeviceOnly: Bool { true }
    public static func make(_ context: EngineContext) -> any TextRefining {
        #if os(iOS) || os(macOS)
        return LocalTranscriptRefiner()
        #else
        return UnavailableTextRefiner()
        #endif
    }
}
