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
    private let rules: any ExtractionRuleCataloging
    public let track: ExtractionTrack = .coreML
    public var regionTimeout: Duration? { .seconds(3) }
    public var modelID: String? { matcher.modelID }

    public init(matcher: any InformationElementMatching,
                rules: any ExtractionRuleCataloging = EmptyExtractionRuleCatalog()) {
        self.matcher = matcher
        self.rules = rules
    }

    public func availability(for request: ExtractionRequest) async -> EngineAvailability {
        await matcher.isAvailable() ? .available : .unavailable(.notInstalled)
    }

    public func extract(region: ExtractionRegion, spec: ExtractionSpec,
                        request: ExtractionRequest) async throws -> RegionExtraction {
        guard await matcher.isAvailable() else { throw ExtractionEngineError.unavailable }
        var shared: [String: GroundedValue] = [:]
        var rows: [[String: GroundedValue]] = []
        // 规则库覆盖：只追加 active 别名（码内 spec 仍是键/类型单源）。
        let overlay = await rules.activeOverlay()
        let spec = overlay.applied(to: spec)
        let allowed = Set(spec.fields.map(\.key))
        let knownLabels = Set(spec.fields.flatMap(\.labelAliases))
        var observations: [ExtractionRuleObservation] = []

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
                // 行级模型只给「键」，值必须收敛到行内片段：去标签前缀/合体行
                // 文法拆值；都失败才保留锚定行原文。格式不符（日期/数字/带单位）
                // 直接丢弃，让规则轨补键，绝不把整行冒充标量值（审计 P0）。
                let lineText = anchors.indices.contains(slot)
                    ? (texts.indices.contains(slot) ? texts[slot] : request.lines[anchors[slot]])
                    : match.value
                // 多标签行（`姓名：… 性别：… 年龄：…`）单标签模型无法拆两键，
                // 整体弃权，交给规则轨按标签位拆分（审计 2026-11-07）。
                guard Self.labelCount(in: lineText,
                                      aliases: spec.fields.flatMap(\.labelAliases)) < 2
                else { continue }
                var discovered: String?
                guard let parsed = Self.valueSpan(for: match.key, in: lineText,
                                                  field: field, kind: spec.kind,
                                                  fallback: match.value,
                                                  knownLabels: knownLabels,
                                                  discoveredLabel: &discovered)
                else { continue }
                // Core ML 在**未知标签**上命中既有键 → 记为观察候选（模型
                // 单独证据权重为 0，永不自动激活；须用户确认后才累计证据）。
                // 先做与 grounding 同源的原文定位：被丢弃的值不得留下规则。
                if let discovered, !discovered.isEmpty,
                   ExtractionGrounding.locate(parsed, in: lineText) != nil {
                    observations.append(ExtractionRuleObservation(kind: spec.kind,
                                                                  key: match.key,
                                                                  alias: discovered))
                }
                let value = GroundedValue(
                    value: parsed,
                    unit: match.unit,
                    anchor: TextAnchor(pageIndex: request.pageIndex,
                                       lineIndex: lineIndex,
                                       blockId: nil, rowId: row.id, utf16Range: 0..<0),
                    confidence: min(match.confidence,
                                    overlay.hasLearnedAlias(kind: spec.kind, key: match.key) ? 0.5 : 0.6))
                switch field.scope {
                case .shared:
                    if shared[match.key] == nil { shared[match.key] = value }
                case .row:
                    if rowFields[match.key] == nil { rowFields[match.key] = value }
                }
            }
            // 行门槛（与规则轨同源）：模型单键行不单独成行，避免只含噪声的
            // 一行在确认页多出一条空壳记录（审计 2026-11-07）。
            if rowFields.count >= max(1, spec.rowMinFields) { rows.append(rowFields) }
        }
        if !observations.isEmpty { await rules.observe(observations) }
        return RegionExtraction(shared: shared, rows: rows)
    }

    /// 行级分类 → 值域（纯函数，表驱动）：标签前缀优先，其次卡类合体行文法；
    /// 两者都不命中时保留原行（值仍须过 grounding）。日期字段只取日期记号，
    /// 其余字段按 `FieldSpec` 格式校验——不合格式即丢弃，不产出整行噪声。
    /// 行内**处于标签位**的不同标签数（多标签行判据）。
    static func labelCount(in line: String, aliases: [String]) -> Int {
        var count = 0
        var matched: [String] = []
        for alias in Set(aliases).sorted(by: { $0.count > $1.count }) {
            // 长别名已命中时，其子串别名不重复计数（「处方日期」vs「日期」）。
            if matched.contains(where: { alias != $0 && $0.contains(alias) }) { continue }
            if let span = ExtractionPatterns.valueSpan(afterLabel: alias, in: line),
               !span.isEmpty {
                count += 1
                matched.append(alias)
            }
        }
        return count
    }

    static func valueSpan(for key: String, in line: String, field: FieldSpec,
                          kind: String, fallback: String,
                          knownLabels: Set<String> = [],
                          discoveredLabel: inout String?) -> String? {
        var candidate = RuleExtractor.labeledValue(in: line, aliases: field.labelAliases)
        // 未知标签：`申请科室：骨科` 之类不在码内别名表，但模型已给出键。
        // 用通用「标签：值」切分取值，并把标签记入观察候选。
        if candidate == nil,
           let generic = RuleExtractor.genericLabeledValue(in: line),
           !knownLabels.contains(generic.label) {
            candidate = generic.value
            discoveredLabel = generic.label
        }
        if candidate == nil {
            candidate = RuleExtractor.classify(line, kind: kind).first { $0.key == key }?.value
        }
        // 处方药名：标签后的剩余仍可能是「药名 规格 用法」合体行——
        // 再按处方文法取药名，避免 drug_name 吃掉整行。
        if key == "drug_name",
           let split = RuleExtractor.classify(candidate ?? line, kind: "prescription")
               .first(where: { $0.key == "drug_name" })?.value {
            candidate = split
        }
        let trimmed = (candidate ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if case .date = field.type, let token = ExtractionPatterns.dateToken(in: trimmed) {
            return token
        }
        return field.type.acceptsFormat(trimmed) ? trimmed : nil
    }
}
