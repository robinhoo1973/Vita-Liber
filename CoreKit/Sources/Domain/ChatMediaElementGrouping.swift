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
    public let confidence: Double
    /// 字段级源行（BR-002 锚点）；空=卡级 rawText 回落。
    public let sourceText: String

    public init(id: String, key: String, value: String, confidence: Double,
                sourceText: String) {
        self.id = id
        self.key = key
        self.value = value
        self.confidence = confidence
        self.sourceText = sourceText
    }
}

public struct ChatMediaElementGroup: Sendable, Equatable, Identifiable {
    public let id: String
    /// 行组为 0 基行号；共享字段组为 nil。
    public let rowIndex: Int?
    public let fields: [ChatMediaElementField]

    public init(id: String, rowIndex: Int?, fields: [ChatMediaElementField]) {
        self.id = id
        self.rowIndex = rowIndex
        self.fields = fields
    }
}

public enum ChatMediaElementGrouping {
    /// 内部键不进入识别结果页（与待核对卡字段摘要同一排除口径）。
    static let excludedKeys: Set<String> = ["metric_key"]

    public static func groups(cardID: String, shared: [FieldDraft],
                              rows: [[FieldDraft]]) -> [ChatMediaElementGroup] {
        var groups: [ChatMediaElementGroup] = []
        if let sharedGroup = makeGroup(id: "\(cardID)-shared", rowIndex: nil,
                                       fields: shared, cardID: cardID, prefix: "s") {
            groups.append(sharedGroup)
        }
        for (index, fields) in rows.enumerated() {
            if let group = makeGroup(id: "\(cardID)-row-\(index)", rowIndex: index,
                                     fields: fields, cardID: cardID, prefix: "r\(index)") {
                groups.append(group)
            }
        }
        return groups
    }

    private static func makeGroup(id: String, rowIndex: Int?, fields: [FieldDraft],
                                  cardID: String, prefix: String) -> ChatMediaElementGroup? {
        var seen: Set<String> = []
        var projected: [ChatMediaElementField] = []
        for field in fields {
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !excludedKeys.contains(field.key),
                  !seen.contains(field.key) else { continue }
            seen.insert(field.key)
            projected.append(ChatMediaElementField(
                id: "\(cardID)-\(prefix)-\(field.key)",
                key: field.key, value: value, confidence: field.confidence,
                sourceText: field.rawText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        }
        guard !projected.isEmpty else { return nil }
        return ChatMediaElementGroup(id: id, rowIndex: rowIndex, fields: projected)
    }
}
