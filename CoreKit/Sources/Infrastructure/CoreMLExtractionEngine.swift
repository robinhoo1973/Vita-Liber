import Foundation
import Domain
import Protocols

/// Core ML 抽取轨（2026-11-06 业主：提取信息元用 Core ML 执行）。
///
/// 只负责“模型候选 → 区域字段”；区域切分/轨切换/并集/grounding 仍由
/// `CardExtractionRegistry` 统一执行。所有值恒 D 级：模型自评分只截到 0.6，
/// 不作为准确率；未通过 grounding 的值由注册表丢弃（BR-003）。
public struct CoreMLExtractionEngine: CardExtractionEngine {
    private let matcher: any InformationElementMatching
    public let track: ExtractionTrack = .coreML
    public var regionTimeout: Duration? { .seconds(3) }

    public init(matcher: any InformationElementMatching) {
        self.matcher = matcher
    }

    public func availability(for request: ExtractionRequest) async -> EngineAvailability {
        await matcher.isAvailable() ? .available : .unavailable(.notInstalled)
    }

    public func extract(region: ExtractionRegion, spec: ExtractionSpec,
                        request: ExtractionRequest) async throws -> RegionExtraction {
        guard await matcher.isAvailable() else { throw ExtractionEngineError.unavailable }
        var shared: [String: GroundedValue] = [:]
        var rows: [[String: GroundedValue]] = []
        let allowed = Set(spec.fields.map(\.key))

        for row in region.rows {
            // 模型契约 = 单行输入（Create ML 文本分类器）。按本行的每个 OCR 行
            // 逐一匹配：表格行的多个格可能各占一个 OCR 行，`row.text` 以空格
            // 拼接后不再等于任一单行原文，用首行做锚点必被 grounding 的
            // 「值须是锚定行子串」丢弃。逐行匹配后值 = 该行原文、锚点 = 该行
            // 行号；同一物理行的各格命中仍聚合为一行（row.id 不变）。
            let lineIndices = Array(Set(row.lineIndices.filter { request.lines.indices.contains($0) })).sorted()
            let texts: [String]
            let anchors: [Int]
            if lineIndices.isEmpty {
                // 兼容退化：无行号的合成行（旧夹具/纯文本路径）仍按整行文本匹配。
                let fallback = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fallback.isEmpty else { continue }
                texts = [fallback]
                anchors = [row.lineIndices.first ?? 0]
            } else {
                texts = lineIndices.map { request.lines[$0] }
                anchors = lineIndices
            }
            let matches = try await matcher.match(lines: texts, documentTypeKey: spec.kind)
            var rowFields: [String: GroundedValue] = [:]
            for match in matches where allowed.contains(match.key) {
                guard let field = spec.field(for: match.key) else { continue }
                let slot = match.sourceLineIndex ?? 0
                let lineIndex = anchors.indices.contains(slot) ? anchors[slot] : (anchors.first ?? 0)
                let value = GroundedValue(
                    value: match.value,
                    unit: match.unit,
                    anchor: TextAnchor(pageIndex: request.pageIndex,
                                       lineIndex: lineIndex,
                                       blockId: nil, rowId: row.id, utf16Range: 0..<0),
                    confidence: min(0.6, match.confidence))
                switch field.scope {
                case .shared:
                    if shared[match.key] == nil { shared[match.key] = value }
                case .row:
                    if rowFields[match.key] == nil { rowFields[match.key] = value }
                }
            }
            if !rowFields.isEmpty { rows.append(rowFields) }
        }
        return RegionExtraction(shared: shared, rows: rows)
    }
}
