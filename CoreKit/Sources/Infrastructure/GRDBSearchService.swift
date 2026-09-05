#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// F12 全文搜索 GRDB 实现（§5.30 / §4.3）：查询长度路由
/// ≥3 字 trigram 主表 / 2 字 2-gram 影子表 / 1 字 LIKE 兜底。
/// 敏感媒体只命中元数据；归档默认排除；snippet 高亮由 FTS snippet 函数生成。
public actor GRDBSearchService: FullTextSearch {
    private let writer: any DatabaseWriter

    /// BR-003：D 级（机器识别未确认）文档不进入任何检索路由——三条路由共用
    /// 同一谓词，新增路由必须复用；漏一处即把未确认 OCR 内容漏进检索。
    private static let searchableDocPredicate = "d.status IN ('active','favorite') AND d.grade != 'D'"

    public init(writer: any DatabaseWriter) { self.writer = writer }

    /// FTS 同步由源表触发器维护（SchemaV2 V3.44：external-content 表不支持直接
    /// 写入，曾报 disk image malformed）——写入 document_file 即自动索引。
    /// 检索：按查询长度路由；返回带片段高亮的命中（引用构造）。
    /// 评审修正：①BR-001 成员隔离——三条路由强制 patient_id 过滤（scope 为空
    /// 即空集，跨成员命中=红线越权）；②MATCH 查询双引号包裹防注入（引号/AND/OR）。
    public func search(_ text: String, scope: DataAccessScope, limit: Int) async throws -> [EntityReference] {
        let route = SearchRules.route(text)
        guard route != .invalid, !scope.patientIds.isEmpty else { return [] }
        let query = text.trimmingCharacters(in: .whitespaces)
        let patientIds = scope.patientIds.map(\.uuidString)
        return try await writer.read { db in
            switch route {
            case .trigram:
                let match = "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
                // BR-007/008：snippet 列号 0-based（1=ocr_text）且 external-content 表
                // 从源表取实时内容——敏感行必须先 CASE 短路，否则标题命中也会把
                // 敏感正文整段载入结果行（与 bigram 分支同一纪律：绝不取回 ocr_text）
                let rows = try Row.fetchAll(db, sql: """
                    SELECT d.id, d.patient_id, d.doc_type, d.created_at, d.is_sensitive,
                           CASE WHEN d.is_sensitive = 1 THEN NULL
                                ELSE snippet(document_fts, 1, '<b>', '</b>', '…', 12) END AS snip
                    FROM document_fts f
                    JOIN document_file d ON d.rowid = f.rowid
                    WHERE document_fts MATCH ? AND \(Self.searchableDocPredicate)
                      AND d.patient_id IN (\(patientIds.map { _ in "?" }.joined(separator: ",")))
                    ORDER BY rank LIMIT ?
                    """, arguments: StatementArguments([match] + patientIds + [limit]))
                return rows.compactMap { Self.hit($0) }
            case .bigram:
                // 每个 2-gram 必须**加引号转义**后再拼 OR：裸拼会把用户输入当 FTS5 语法。
                // 2 字查询「OR」/「\"a」/「-(」会抛 fts5 syntax error（一路冒到 AI 助手显示
                // 「回答失败」），「x*」会被当前缀通配符而返回过量结果。与 trigram 分支同一纪律。
                let grams = SearchRules.bigrams(query)
                    .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                    .joined(separator: " OR ")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT d.id, d.patient_id, d.doc_type, d.created_at, d.is_sensitive, d.title,
                           CASE WHEN d.is_sensitive = 1 THEN NULL ELSE d.ocr_text END AS ocr_text
                    FROM document_fts_2gram f
                    JOIN document_file d ON d.rowid = f.rowid
                    WHERE document_fts_2gram MATCH ? AND \(Self.searchableDocPredicate)
                      AND d.patient_id IN (\(patientIds.map { _ in "?" }.joined(separator: ",")))
                    ORDER BY rank LIMIT ?
                    """, arguments: StatementArguments([grams] + patientIds + [limit]))
                // contentless 表无 snippet 函数——取回源列手动高亮（V3.44）
                return rows.compactMap { row in
                    guard let ref = Self.hit(row) else { return nil }
                    // BR-007/008：敏感行绝不取回 ocr_text——沿用 hit() 的脱敏片段，
                    // 否则会覆盖掉脱敏逻辑、把敏感正文泄漏进搜索结果。
                    let sensitive = (row["is_sensitive"] as Int?) == 1
                    guard !sensitive else { return ref }
                    let source = (row["title"] as String?) ?? (row["ocr_text"] as String?) ?? ""
                    return EntityReference(kind: ref.kind, refID: ref.refID, title: ref.title,
                                           snippet: SearchRules.highlight(source, query: query))
                }
            case .like:
                // 1 字兜底：低频高噪音，限定最近 90 天窗口 + 成员过滤缩小扫描集；
                // 检索列 = title/ocr_text/notes/meta_json（V3.43 起标题等独立列）
                let since = DayArithmetic.since(days: 90)
                let pattern = "%\(query)%"
                let rows = try Row.fetchAll(db, sql: """
                    SELECT d.id, d.patient_id, d.doc_type, d.created_at, d.is_sensitive,
                           CASE WHEN d.is_sensitive = 1 THEN d.title
                                ELSE COALESCE(d.title, d.ocr_text, d.meta_json) END AS snip
                    FROM document_file d
                    WHERE \(Self.searchableDocPredicate) AND d.created_at >= ?
                      AND d.patient_id IN (\(patientIds.map { _ in "?" }.joined(separator: ",")))
                      AND (d.title LIKE ?
                           OR (d.is_sensitive = 0
                               AND (d.meta_json LIKE ? OR d.ocr_text LIKE ? OR d.notes LIKE ?)))
                    ORDER BY d.created_at DESC LIMIT ?
                    """, arguments: StatementArguments([since] + patientIds + [pattern, pattern, pattern, pattern, limit]))
                return rows.compactMap { Self.hit($0) }
            case .invalid:
                return []
            }
        }
    }

    private static func hit(_ row: Row) -> EntityReference? {
        guard let id = UUID(uuidString: row["id"] as String) else { return nil }
        let sensitive = (row["is_sensitive"] as Int?) == 1
        // BR-007/008：敏感行只命中元数据（标题）——正文不随检索呈现
        let snippet = (row["snip"] as String?) ?? ""
        return EntityReference(
            kind: row["doc_type"] as String,
            refID: id,
            title: "资料",
            snippet: sensitive ? "敏感资料（解锁后可见内容）" : snippet,
            isSensitive: sensitive)
    }
}
#endif
