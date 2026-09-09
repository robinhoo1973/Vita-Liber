import Foundation

/// FR6.9 V3.61 待办卡 `partial_data` 载荷：卡级共享字段 + 多行（每类一卡多行）。
/// 向后兼容：旧行是纯 `{key: value}` 字典 → 全部视为共享字段、无行。
/// BR-003：本载荷只在待办卡详情/续确认中展示，不进任何事实链、FTS、AI、导出。
public struct PendingCardPayload: Codable, Sendable, Equatable {
    public var shared: [String: String]
    public var rows: [[String: String]]

    public init(shared: [String: String] = [:], rows: [[String: String]] = []) {
        self.shared = shared
        self.rows = rows
    }

    /// 由匹配卡快照（保留行序；字段取 value）
    public init(card: MatchedCard) {
        var shared: [String: String] = [:]
        for field in card.shared where !field.value.isEmpty { shared[field.key] = field.value }
        self.shared = shared
        self.rows = card.rows.map { row in
            var map: [String: String] = [:]
            for field in row.fields where !field.value.isEmpty { map[field.key] = field.value }
            return map
        }
    }

    /// 解析存储 JSON：新形态优先；旧字典 → shared；非法 → 空载荷（不崩溃、不猜）
    public static func decode(_ json: String) -> PendingCardPayload {
        guard let data = json.data(using: .utf8) else { return PendingCardPayload() }
        let decoder = JSONDecoder()
        if let payload = try? decoder.decode(PendingCardPayload.self, from: data) {   // try?-ok: 旧字典形态回落到下一分支
            return payload
        }
        if let legacy = try? decoder.decode([String: String].self, from: data) {   // try?-ok: 非法 JSON 回落空载荷，调用方按空态渲染
            return PendingCardPayload(shared: legacy)
        }
        return PendingCardPayload()
    }

    /// 存储形态（稳定键序，便于对比/去重）
    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"   // try?-ok: 纯字符串字典编码不会失败；失败回落空对象
    }
}
