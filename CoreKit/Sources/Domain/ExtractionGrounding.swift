import Foundation

/// 子项目 E2（design §4.6）：轨道无关的第二道防线——T1/T2/T3 产出的每个 `GroundedValue` 都必须能在其锚定行**定位到原文**；
/// 子串 / 数字边界 / 否定守卫 / 单位邻接 / 叙事整段 / 枚举归一全部**复用 `OCRGrounding.fields`**（参数化键集），不另起一套规则。
/// 额外只查格式（`FieldType.acceptsFormat`：日期可解析 / 数字有限 / 枚举 canonical），不判读、不换算、不猜（BR-004/012）。
/// 定位成功即回填 `TextAnchor.utf16Range`；失败即丢弃并计数（`diagnostics.droppedUngrounded`），不做「JSON 修补」。
public enum ExtractionGrounding {
    /// 校验整卡：共享逐键；行内逐键，行锚（drug_name / raw_label / item_name…）未锚定 → 整行不出（不猜行），
    /// 该行其余已锚定值一并计入 dropped（它们同样不进卡）。
    public static func validate(_ card: ExtractedCard, spec: ExtractionSpec, lines: [String]) -> (card: ExtractedCard, dropped: Int) {
        let types = Dictionary(spec.fields.map { ($0.key, $0.type) }, uniquingKeysWith: { a, _ in a })
        let allowed = Set(types.keys)
        let extraLabels = Set(spec.fields.filter { if case .narrative = $0.type { return true } else { return false } }.flatMap(\.labelAliases))
        var out = card
        var dropped = 0
        func keep(_ key: String, _ value: GroundedValue) -> GroundedValue? {
            guard let type = types[key],
                  let ok = validate(value, key: key, type: type, allowed: allowed, lines: lines, extraLabels: extraLabels) else {
                dropped += 1
                return nil
            }
            return ok
        }
        out.shared = card.shared.reduce(into: [:]) { acc, kv in if let v = keep(kv.key, kv.value) { acc[kv.key] = v } }
        out.rows = card.rows.compactMap { row in
            let kept = row.reduce(into: [String: GroundedValue]()) { acc, kv in if let v = keep(kv.key, kv.value) { acc[kv.key] = v } }
            if let anchor = spec.rowAnchor {
                guard kept[anchor] != nil else { dropped += kept.count; return nil }
            } else if kept.isEmpty {
                return nil
            }
            return kept
        }
        out.diagnostics.droppedUngrounded += dropped
        return (out, dropped)
    }

    /// 单值校验：`value` 按 `\n` 分段，段数须与锚点数（主锚 + 续行）一致；每段在其锚定行定位 → 以**原文精确子串**
    /// 过 `OCRGrounding.fields`（子串 / 边界 / 否定 / 单位 / 叙事）；枚举取 canonical 进 `normalized`，其余查格式。
    static func validate(_ value: GroundedValue, key: String, type: FieldType, allowed: Set<String>, lines: [String],
                         extraLabels: Set<String>) -> GroundedValue? {
        let segments = value.value.components(separatedBy: "\n")
        let anchors = [value.anchor] + value.continuation
        guard segments.count == anchors.count else { return nil }
        // round4 D-1：多段值只允许 `.narrative`——本处是轨道无关的第二道防线，T1/T2/T3 同受约；
        // 此前逐段各自单行合法即过，T2（assembler）非叙事键的 `\n` 值可穿过，同一单据跨轨异形。
        if segments.count > 1, !type.isNarrative { return nil }
        var narrative = Set<String>(), numeric = Set<String>()
        if case .narrative = type { narrative.insert(key) }
        if case .number = type { numeric.insert(key) }
        var checked = value
        var normalizedSegments: [String] = []
        for (i, (segment, anchor)) in zip(segments, anchors).enumerated() {
            guard lines.indices.contains(anchor.lineIndex), let range = locate(segment, in: lines[anchor.lineIndex]) else { return nil }
            let line = lines[anchor.lineIndex]
            let exact = String(line[range])
            let span = OCRExtractedSpan(key: key, value: exact, unit: i == 0 ? value.unit : nil, lineIndex: anchor.lineIndex)
            guard let draft = OCRGrounding.fields([span], lines: lines, allowedKeys: allowed, narrativeKeys: narrative,
                                                  numericKeys: numeric, extraLabels: extraLabels).first else { return nil }
            normalizedSegments.append(draft.value)
            let utf16 = NSRange(range, in: line)
            let located = utf16.location..<(utf16.location + utf16.length)
            if i == 0 { checked.anchor.utf16Range = located } else { checked.continuation[i - 1].utf16Range = located }
        }
        if case .enumerated(let domain) = type {
            // 印刷原文留在 value，canonical 进 normalized（不猜：别名表不命中即丢）——归一单出口 OCRGrounding.normalized。
            let canonical = OCRGrounding.normalized(normalizedSegments[0], key: key)
            guard domain.contains(canonical) else { return nil }
            checked.normalized = canonical
        } else {
            guard type.acceptsFormat(value.value) else { return nil }
            checked.normalized = nil
        }
        return checked
    }

    /// 精确子串 → NFKC + 空白折叠 + 全角冒号归一后按字符映射回原文范围；否则 nil（不做繁简、不纠错——FR25.4 保真）。
    public static func locate(_ value: String, in line: String) -> Range<String.Index>? {
        guard !value.isEmpty, !line.isEmpty else { return nil }
        if let exact = line.range(of: value) { return exact }
        func fold(_ c: Character) -> String {
            String(c).precomposedStringWithCompatibilityMapping.replacingOccurrences(of: "：", with: ":").filter { !$0.isWhitespace }
        }
        var folded = ""
        var map: [String.Index] = []
        for index in line.indices {
            let f = fold(line[index])
            folded += f
            map += Array(repeating: index, count: f.count)
        }
        let target = value.map(fold).joined()
        guard !target.isEmpty, let r = folded.range(of: target) else { return nil }
        let start = folded.distance(from: folded.startIndex, to: r.lowerBound)
        let end = folded.distance(from: folded.startIndex, to: r.upperBound)
        guard end > start, end <= map.count else { return nil }
        return map[start]..<line.index(after: map[end - 1])
    }
}
