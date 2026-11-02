import Foundation

/// 聊天媒体详情「识别结果」页的要素分组（2026-11-01 业主；mock
/// `chat-import-staging.html` 第 3 帧）。
///
/// 分组纪律：要素不能跨卡/跨行平铺——药名、规格、剂量、频次必须留在同一
/// 处方行；检验项目、结果、单位必须留在同一检验行。共享字段单独成组，
/// 每个 `MatchedCardRow` 各自成组。纯函数、零依赖，供 UI 投影与测试共用。
public struct ChatMediaElementField: Sendable, Equatable, Identifiable {
    public let id: String
    public let key: String
    public let value: String
    /// 字段单位（可为空）；编辑只改数值，单位保留。
    public let unit: String?
    public let confidence: Double
    /// 字段级源行（BR-002 锚点）；空=卡级 rawText 回落。
    public let sourceText: String
    /// 字段在合并页文本行中的 0 基行号（与 `PageLayout.blocks` 同坐标）。
    public let sourceLineIndex: Int?
    /// 当前字段级来源：C=已确认，D=机器识别未确认。
    public let grade: String

    public init(id: String, key: String, value: String, unit: String? = nil,
                confidence: Double, sourceText: String, sourceLineIndex: Int? = nil,
                grade: String = "D") {
        self.id = id
        self.key = key
        self.value = value
        self.unit = unit
        self.confidence = confidence
        self.sourceText = sourceText
        self.sourceLineIndex = sourceLineIndex
        self.grade = grade
    }
}

public struct ChatMediaElementGroup: Sendable, Equatable, Identifiable {
    public let id: String
    /// 行组为 0 基行号；共享字段组为 nil。
    public let rowIndex: Int?
    /// 行组对应的稳定行 ID；共享字段组为 nil。
    public let rowId: UUID?
    public let fields: [ChatMediaElementField]

    public init(id: String, rowIndex: Int?, rowId: UUID? = nil,
                fields: [ChatMediaElementField]) {
        self.id = id
        self.rowIndex = rowIndex
        self.rowId = rowId
        self.fields = fields
    }
}

public enum ChatMediaElementGrouping {
    /// 内部键不进入识别结果页（与待核对卡字段摘要同一排除口径）。
    static let excludedKeys: Set<String> = ["metric_key"]

    public static func groups(cardID: String, card: MatchedCard,
                              includeEmpty: Bool = false) -> [ChatMediaElementGroup] {
        var groups: [ChatMediaElementGroup] = []
        if let shared = makeGroup(id: "\(cardID)-shared", rowIndex: nil, rowId: nil,
                                  fields: card.shared, cardID: cardID, prefix: "s",
                                  includeEmpty: includeEmpty) {
            groups.append(shared)
        }
        for (index, row) in card.rows.enumerated() {
            if let group = makeGroup(id: "\(cardID)-row-\(row.id.uuidString)", rowIndex: index,
                                     rowId: row.id, fields: row.fields,
                                     cardID: cardID, prefix: "r\(index)",
                                     includeEmpty: includeEmpty) {
                groups.append(group)
            }
        }
        return groups
    }

    /// 旧待办载荷（无卡身份/行 ID）的兼容投影；调用方不得据此回写。
    public static func groups(cardID: String, shared: [FieldDraft],
                              rows: [[FieldDraft]]) -> [ChatMediaElementGroup] {
        var groups: [ChatMediaElementGroup] = []
        if let sharedGroup = makeGroup(id: "\(cardID)-shared", rowIndex: nil, rowId: nil,
                                       fields: shared, cardID: cardID, prefix: "s",
                                       includeEmpty: false) {
            groups.append(sharedGroup)
        }
        for (index, fields) in rows.enumerated() {
            if let group = makeGroup(id: "\(cardID)-row-\(index)", rowIndex: index, rowId: nil,
                                     fields: fields, cardID: cardID, prefix: "r\(index)",
                                     includeEmpty: false) {
                groups.append(group)
            }
        }
        return groups
    }

    private static func makeGroup(id: String, rowIndex: Int?, rowId: UUID?,
                                  fields: [FieldDraft], cardID: String,
                                  prefix: String, includeEmpty: Bool) -> ChatMediaElementGroup? {
        var seen: Set<String> = []
        var projected: [ChatMediaElementField] = []
        for field in fields {
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (includeEmpty || !value.isEmpty), !excludedKeys.contains(field.key),
                  !seen.contains(field.key) else { continue }
            seen.insert(field.key)
            projected.append(ChatMediaElementField(
                id: "\(cardID)-\(prefix)-\(field.key)",
                key: field.key, value: value, unit: field.unit,
                confidence: field.confidence,
                sourceText: field.rawText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                sourceLineIndex: field.sourceLineIndex,
                grade: field.grade == .userConfirmed ? "C" : "D"))
        }
        guard !projected.isEmpty else { return nil }
        return ChatMediaElementGroup(id: id, rowIndex: rowIndex, rowId: rowId, fields: projected)
    }
}
