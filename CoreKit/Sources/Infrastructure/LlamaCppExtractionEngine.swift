import Foundation
import Domain
import Protocols
#if canImport(Llama)
import Llama
#endif

/// 子项目 F（2026-09-14）：T2 本机 LLM 轨——`CardExtractionEngine` 端口，使用 llama.cpp 运行 Qwen2.5-0.5B GGUF，
/// 配合 `GBNFGrammarGenerator` 生成的文法约束输出格式。零网络、零资产、仅 macOS/iOS 且模型已下载时可用。
/// 全部产物恒 D 级（BR-003）；grounding 由注册表统一执行（第二道防线）。
/// 失败降级：T2 unavailable → T3（注册表逐区域切换，零崩溃）。

// MARK: - 模型管理器

/// Qwen2.5-0.5B GGUF 模型管理：路径查找、下载状态、文件校验。
public enum LlamaModelManager {
    /// 模型文件名（与 asr-release-spec.json 一致）。
    public static let modelFileName = "qwen2.5-0.5b-instruct-q4_k_m.gguf"
    /// 模型包大小上限（字节），用于 WiFi-only 下载判断。
    public static let maxModelSize: Int64 = 400_000_000

    /// 模型文件路径（App 沙盒 Documents 目录下）。
    public static func modelURL(for fileName: String = modelFileName) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("llm-models/\(fileName)")
    }

    /// 模型是否已就绪（文件存在且可读）。
    public static func isModelReady(fileName: String = modelFileName) -> Bool {
        let url = modelURL(for: fileName)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// 模型文件大小（字节）。
    public static func modelSize(fileName: String = modelFileName) -> Int64 {
        let url = modelURL(for: fileName)
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs[.size] as? Int64) ?? 0
        } catch {
            return 0
        }
    }
}

// MARK: - T2 引擎

#if canImport(Llama)
/// T2 本机 LLM 轨引擎——`CardExtractionEngine` 端口实现。
/// 使用 `Llama` 包（DePasqualeOrg/swift-llama）加载 GGUF 模型 + GBNF 文法约束输出。
public struct LlamaCppExtractionEngine: CardExtractionEngine {
    public let track: ExtractionTrack = .localLLM
    public let regionTimeout: Duration? = .seconds(15)
    private let modelURL: URL
    private let gbnfGrammar: String

    /// 初始化：传入模型路径和 GBNF 文法。文法由 `GBNFGrammarGenerator` 从 spec 生成。
    public init(modelURL: URL? = nil, gbnfGrammar: String? = nil) {
        self.modelURL = modelURL ?? LlamaModelManager.modelURL()
        self.gbnfGrammar = gbnfGrammar ?? GBNFGrammarGenerator.generate(for: ExtractionSpecRegistry.specs.first!)
    }

    public func availability(for request: ExtractionRequest) async -> EngineAvailability {
        guard request.allowsGenerativeProcessing else {
            return .unavailable(.notAuthorized)
        }
        guard LlamaModelManager.isModelReady() else {
            return .unavailable(.notInstalled)
        }
        if await HeavyModelLease.shared.isOccupied {
            return .unavailable(.modelBusy)
        }
        return .available
    }

    public func extract(region: ExtractionRegion, spec: ExtractionSpec, request: ExtractionRequest) async throws -> RegionExtraction {
        guard await HeavyModelLease.shared.tryAcquire() else {
            throw ExtractionEngineError.modelBusy
        }
        defer { Task { await HeavyModelLease.shared.release() } }

        let lines = request.lines
        let prompt = Self.buildPrompt(lines: lines, spec: spec)
        let grammar = GBNFGrammarGenerator.generate(for: spec)

        // 使用 Llama 包的 actor-based API
        let state = LlamaState()
        try await state.loadModel(from: modelURL)
        try await state.load(gbnf: grammar)
        let response = try await state.complete(prompt, maxTokens: spec.outputTokenBudget)

        guard let data = response.data(using: .utf8) else {
            throw ExtractionEngineError.unavailable
        }
        let result: LlamaResult
        do {
            result = try JSONDecoder().decode(LlamaResult.self, from: data)
        } catch {
            throw ExtractionEngineError.unavailable
        }
        return Self.toRegionExtraction(result, spec: spec, lines: lines, pageIndex: region.pageIndex)
    }

    // MARK: - Prompt 构建

    private static func systemPrompt(for spec: ExtractionSpec) -> String {
        let keys = spec.fields.map { $0.key }.joined(separator: ", ")
        return """
        Extract fields from OCR text. Return valid JSON with keys: \(keys).
        Every value MUST be a verbatim substring of the input lines. Do not invent fields.
        """
    }

    private static func buildPrompt(lines: [String], spec: ExtractionSpec) -> String {
        let numbered = lines.enumerated().map { "[\($0.offset)] \($0.element)" }.joined(separator: "\n")
        return "\(systemPrompt(for: spec))\n\n\(numbered)"
    }

    // MARK: - 结果解析

    private struct LlamaResult: Codable {
        var shared: [LlamaSpan]?
        var rows: [[LlamaSpan]]?
    }

    private struct LlamaSpan: Codable {
        var key: String
        var value: String
        var unit: String?
        var lineIndex: Int
    }

    private static func toRegionExtraction(_ result: LlamaResult, spec: ExtractionSpec, lines: [String], pageIndex: Int) -> RegionExtraction {
        var shared: [String: GroundedValue] = [:]
        for span in result.shared ?? [] {
            guard spec.shared.contains(where: { $0.key == span.key }),
                  lines.indices.contains(span.lineIndex) else { continue }
            let line = lines[span.lineIndex]
            guard let range = line.range(of: span.value) else { continue }
            let start = line.distance(from: line.startIndex, to: range.lowerBound)
            let end = line.distance(from: line.startIndex, to: range.upperBound)
            let anchor = TextAnchor(pageIndex: pageIndex, lineIndex: span.lineIndex, blockId: nil, rowId: nil,
                                    utf16Range: start..<end)
            shared[span.key] = GroundedValue(value: span.value, unit: span.unit, anchor: anchor, confidence: 0.6)
        }
        var rows: [[String: GroundedValue]] = []
        for rowSpans in result.rows ?? [] {
            var row: [String: GroundedValue] = [:]
            for span in rowSpans {
                guard spec.row.contains(where: { $0.key == span.key }),
                      lines.indices.contains(span.lineIndex) else { continue }
                let line = lines[span.lineIndex]
                guard let range = line.range(of: span.value) else { continue }
                let start = line.distance(from: line.startIndex, to: range.lowerBound)
                let end = line.distance(from: line.startIndex, to: range.upperBound)
                let anchor = TextAnchor(pageIndex: pageIndex, lineIndex: span.lineIndex, blockId: nil, rowId: nil,
                                        utf16Range: start..<end)
                row[span.key] = GroundedValue(value: span.value, unit: span.unit, anchor: anchor, confidence: 0.6)
            }
            if !row.isEmpty { rows.append(row) }
        }
        return RegionExtraction(shared: shared, rows: rows)
    }
}
#endif
