import Foundation

/// 子项目 E2（design §4.5）：`GroundedValue` → 既有 `FieldDraft`，让 FR17.13 确认页与 `CardTemplateMatcher` 零改消费
/// 三轨产物。恒 D 级：`grade = .ocrUnconfirmed`、`confidence = min(页 OCR 置信, 0.6)`（模型自评分不作准确率，BR-003）；
/// `value` 取枚举 canonical（`normalized`）否则原文；`rawText` = 锚定行整行（BR-002 不丢内容）。行身份由 E5 `match(card:)` 承接。
public enum FieldDraftAdapter {
    /// 产出轨 → 字段来源标注（跨轨置信度不直接比较，仅呈现标注）。
    public static func source(_ track: ExtractionTrack) -> UnderstandingSource {
        switch track {
        case .foundationModels: return .foundationModels
        case .localLLM: return .localLLM
        case .rules: return .heuristic
        }
    }

    public static func draft(key: String, _ value: GroundedValue, lines: [String], pageConfidence: Double, track: ExtractionTrack) -> FieldDraft {
        FieldDraft(key: key, value: value.normalized ?? value.value, unit: value.unit,
                   confidence: min(pageConfidence, 0.6),
                   rawText: lines.indices.contains(value.anchor.lineIndex) ? lines[value.anchor.lineIndex] : value.value,
                   source: source(track), grade: .ocrUnconfirmed, sourceLineIndex: value.anchor.lineIndex)
    }

    /// 整卡 → 共享草稿 + 逐行草稿（按 spec 字段序；spec 外键按键名尾随，确定性输出）。轨道取卡级 `provenance.track`。
    public static func drafts(_ card: ExtractedCard, spec: ExtractionSpec, lines: [String], pageConfidence: Double)
        -> (shared: [FieldDraft], rows: [[FieldDraft]]) {
        func ordered(_ values: [String: GroundedValue], by order: [FieldSpec]) -> [FieldDraft] {
            let known = order.map(\.key).filter { values[$0] != nil }
            let rest = values.keys.filter { key in !order.contains { $0.key == key } }.sorted()
            return (known + rest).compactMap { key in
                values[key].map { draft(key: key, $0, lines: lines, pageConfidence: pageConfidence, track: card.provenance.track) }
            }
        }
        return (ordered(card.shared, by: spec.shared), card.rows.map { ordered($0, by: spec.row) })
    }
}
