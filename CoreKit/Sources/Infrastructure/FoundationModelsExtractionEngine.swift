import Foundation
import Domain
import Protocols
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 子项目 E4（2026-09-14）：T1 Foundation Models 轨——`CardExtractionEngine` 端口，使用系统 `LanguageModelSession`
/// 直接从 OCR 文本抽取结构化字段。零网络、零资产、仅 iOS 26+ 且 Apple Intelligence 已启用的设备可用。
/// 全部产物恒 D 级（BR-003）；grounding 由注册表统一执行（第二道防线）。
/// 失败降级：T1 unavailable → 跳过 → T2 → T3（注册表逐区域切换，零崩溃）。
/// 结构轮（2026-09-15）：互斥锁迁出（HeavyModelLease.swift，T1/T2 共用）；
/// prompt / span→区域装配收敛到 ModelPromptBuilder / ModelSpanAssembler 单点。

// MARK: - T1 引擎

#if canImport(FoundationModels)
@available(iOS 26, macOS 26, *)
private struct ExtractionModelField: Sendable {
    let key: String
    let value: String
    let unit: String?
    let lineIndex: Int
}

@available(iOS 26, macOS 26, *)
@Generable
private struct ExtractionModelSpan {
    var key: String
    var value: String
    var unit: String?
    var lineIndex: Int
}

@available(iOS 26, macOS 26, *)
@Generable
private struct ExtractionModelResult {
    var shared: [ExtractionModelSpan]
    var rows: [[ExtractionModelSpan]]
}
#endif

/// T1 Foundation Models 轨引擎——`CardExtractionEngine` 端口实现。
public struct FoundationModelsExtractionEngine: CardExtractionEngine {
    public let track: ExtractionTrack = .foundationModels
    public let regionTimeout: Duration? = .seconds(8)
    public init() {}

    public func availability(for request: ExtractionRequest) async -> EngineAvailability {
        guard request.allowsGenerativeProcessing else {
            return .unavailable(.notAuthorized)
        }
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                return .unavailable(.unavailable)
            }
            if await HeavyModelLease.shared.isOccupied {
                return .unavailable(.modelBusy)
            }
            return .available
        }
        #endif
        return .unavailable(.unavailable)
    }

    public func extract(region: ExtractionRegion, spec: ExtractionSpec, request: ExtractionRequest) async throws -> RegionExtraction {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            guard await HeavyModelLease.shared.tryAcquire() else {
                throw ExtractionEngineError.modelBusy
            }
            defer { Task { await HeavyModelLease.shared.release() } }

            let lines = request.lines
            let prompt = ModelPromptBuilder.numbered(lines: lines)
            let deadline = UnderstandingDeadline()
            let result = await deadline.run(timeout: regionTimeout ?? .seconds(8)) {
                let session = LanguageModelSession(instructions: ModelPromptBuilder.systemPrompt(for: spec))
                let response = try await session.respond(to: prompt,
                    generating: ExtractionModelResult.self,
                    options: GenerationOptions(maximumResponseTokens: spec.outputTokenBudget))
                try Task.checkCancellation()
                return response.content
            }
            guard let result else {
                throw ExtractionEngineError.unavailable
            }
            return ModelSpanAssembler.region(
                shared: result.shared.map { ModelSpan(key: $0.key, value: $0.value, unit: $0.unit, lineIndex: $0.lineIndex) },
                rows: result.rows.map { $0.map { ModelSpan(key: $0.key, value: $0.value, unit: $0.unit, lineIndex: $0.lineIndex) } },
                spec: spec, lines: lines, pageIndex: region.pageIndex)
        }
        #endif
        throw ExtractionEngineError.unavailable
    }
}
