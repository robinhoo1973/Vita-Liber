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
                let rows = try Row.fetchAll(db, sql: """
                    SELECT d.id, d.patient_id, d.doc_type, d.created_at, d.is_sensitive,
                           snippet(document_fts, 1, '<b>', '</b>', '…', 12) AS snip
                    FROM document_fts f
                    JOIN document_file d ON d.rowid = f.rowid
                    WHERE document_fts MATCH ? AND d.status IN ('active','favorite')
                      AND d.patient_id IN (\(patientIds.map { _ in "?" }.joined(separator: ",")))
                    ORDER BY rank LIMIT ?
                    """, arguments: StatementArguments([match] + patientIds + [limit]))
                return rows.compactMap { Self.hit($0) }
            case .bigram:
                let grams = SearchRules.bigrams(query).joined(separator: " OR ")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT d.id, d.patient_id, d.doc_type, d.created_at, d.is_sensitive, d.title, d.ocr_text
                    FROM document_fts_2gram f
                    JOIN document_file d ON d.rowid = f.rowid
                    WHERE document_fts_2gram MATCH ? AND d.status IN ('active','favorite')
                      AND d.patient_id IN (\(patientIds.map { _ in "?" }.joined(separator: ",")))
                    ORDER BY rank LIMIT ?
                    """, arguments: StatementArguments([grams] + patientIds + [limit]))
                // contentless 表无 snippet 函数——取回源列手动高亮（V3.44）
                return rows.compactMap { row in
                    guard let ref = Self.hit(row) else { return nil }
                    let source = (row["title"] as String?) ?? (row["ocr_text"] as String?) ?? ""
                    return EntityReference(kind: ref.kind, refID: ref.refID, title: ref.title,
                                           snippet: SearchRules.highlight(source, query: query))
                }
            case .like:
                // 1 字兜底：低频高噪音，限定最近 90 天窗口 + 成员过滤缩小扫描集；
                // 检索列 = title/ocr_text/notes/meta_json（V3.43 起标题等独立列）
                let since = Date().timeIntervalSince1970 - 90 * 86400
                let pattern = "%\(query)%"
                let rows = try Row.fetchAll(db, sql: """
                    SELECT d.id, d.patient_id, d.doc_type, d.created_at, d.is_sensitive,
                           COALESCE(d.title, d.ocr_text, d.meta_json) AS snip
                    FROM document_file d
                    WHERE d.status IN ('active','favorite') AND d.created_at >= ?
                      AND d.patient_id IN (\(patientIds.map { _ in "?" }.joined(separator: ",")))
                      AND (d.meta_json LIKE ? OR d.title LIKE ? OR d.ocr_text LIKE ? OR d.notes LIKE ?)
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
            snippet: sensitive ? "敏感资料（解锁后可见内容）" : snippet)
    }
}
#endif
