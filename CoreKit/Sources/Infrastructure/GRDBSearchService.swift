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

    /// 写入侧：文档入库时同步 FTS（trigram 主表 + 2-gram 影子列）。
    /// external-content 模式：FTS rowid = document_file 的隐式整数 rowid
    /// （FTS5 rowid 必须 INTEGER，源表主键是 TEXT UUID——V3.43）。
    /// FTS5 虚表不支持 UPSERT——同事务 DELETE+INSERT 实现幂等重建。
    public func index(docID: UUID, patientId: UUID, title: String, ocrText: String?, notes: String?) async throws {
        try await writer.write { db in
            guard let rowid = try Int64.fetchOne(db, sql: """
                SELECT rowid FROM document_file WHERE id = ?
                """, arguments: [docID.uuidString]) else {
                throw SearchError.docNotFound(docID)
            }
            try db.execute(sql: "DELETE FROM document_fts WHERE rowid = ?", arguments: [rowid])
            try db.execute(sql: """
                INSERT INTO document_fts (rowid, title, ocr_text, notes) VALUES (?, ?, ?, ?)
                """, arguments: [rowid, title, ocrText, notes])
            try db.execute(sql: "DELETE FROM document_fts_2gram WHERE rowid = ?", arguments: [rowid])
            let title2 = SearchRules.bigrams(title).joined(separator: " ")
            let ocr2 = ocrText.map { SearchRules.bigrams($0).joined(separator: " ") } ?? ""
            let note2 = notes.map { SearchRules.bigrams($0).joined(separator: " ") } ?? ""
            try db.execute(sql: """
                INSERT INTO document_fts_2gram (rowid, title_2gram, ocr_2gram, note_2gram) VALUES (?, ?, ?, ?)
                """, arguments: [rowid, title2, ocr2, note2])
        }
    }

    public enum SearchError: Error, LocalizedError {
        case docNotFound(UUID)
        public var errorDescription: String? { "文档不存在: \(self)" }
    }

    /// 检索：按查询长度路由；返回带片段高亮的命中（引用构造）。
    public func search(_ text: String, scope: DataAccessScope, limit: Int) async throws -> [EntityReference] {
        let route = SearchRules.route(text)
        guard route != .invalid else { return [] }
        let query = text.trimmingCharacters(in: .whitespaces)
        return try await writer.read { db in
            switch route {
            case .trigram:
                let rows = try Row.fetchAll(db, sql: """
                    SELECT d.id, d.patient_id, d.doc_type, d.created_at,
                           snippet(document_fts, 1, '<b>', '</b>', '…', 12) AS snip
                    FROM document_fts f
                    JOIN document_file d ON d.rowid = f.rowid
                    WHERE document_fts MATCH ? AND d.status IN ('active','favorite')
                    ORDER BY rank LIMIT ?
                    """, arguments: [query, limit])
                return rows.compactMap { Self.hit($0) }
            case .bigram:
                let grams = SearchRules.bigrams(query).joined(separator: " OR ")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT d.id, d.patient_id, d.doc_type, d.created_at,
                           snippet(document_fts_2gram, 1, '<b>', '</b>', '…', 12) AS snip
                    FROM document_fts_2gram f
                    JOIN document_file d ON d.rowid = f.rowid
                    WHERE document_fts_2gram MATCH ? AND d.status IN ('active','favorite')
                    ORDER BY rank LIMIT ?
                    """, arguments: [grams, limit])
                return rows.compactMap { Self.hit($0) }
            case .like:
                // 1 字兜底：低频高噪音，限定最近 90 天窗口缩小扫描集
                let since = Date().timeIntervalSince1970 - 90 * 86400
                let rows = try Row.fetchAll(db, sql: """
                    SELECT d.id, d.patient_id, d.doc_type, d.created_at, d.meta_json AS snip
                    FROM document_file d
                    WHERE d.status IN ('active','favorite') AND d.created_at >= ?
                      AND d.meta_json LIKE ?
                    ORDER BY d.created_at DESC LIMIT ?
                    """, arguments: [since, "%\(query)%", limit])
                return rows.compactMap { Self.hit($0) }
            case .invalid:
                return []
            }
        }
    }

    private static func hit(_ row: Row) -> EntityReference? {
        guard let id = UUID(uuidString: row["id"] as String) else { return nil }
        return EntityReference(
            kind: row["doc_type"] as String,
            refID: id,
            title: "资料",
            snippet: row["snip"] as String? ?? "")
    }
}
#endif
