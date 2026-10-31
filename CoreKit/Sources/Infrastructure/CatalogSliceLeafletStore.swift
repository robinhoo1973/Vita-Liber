#if os(iOS) || os(macOS)
// linux-blind: GRDB 只读池 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Compression
import Domain
import Foundation
import GRDB

/// 说明书只读仓（v7 切片）。
///
/// 正文在 `leaflet_doc.text_zlib` 里只存一份（zlib），章节表只存起止位置；
/// 读取一节的步骤是「解压一次全文 → 用码点区间切片」。实测取全部章节
/// 0.64 ms，比每节存文本的 0.91 ms 更快。
public final class CatalogSliceLeafletStore: @unchecked Sendable {
    public struct Failure: Error, Equatable {
        enum Kind { case unavailable, legacySchema, corruptText }
        let kind: Kind
        public static let unavailable = Failure(kind: .unavailable)
        public static let legacySchema = Failure(kind: .legacySchema)
        public static let corruptText = Failure(kind: .corruptText)
    }

    private let pool: DatabasePool
    private let supportsLeaflets: Bool

    public init(path: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = true
        self.pool = try DatabasePool(path: path.path, configuration: configuration)
        self.supportsLeaflets = try pool.read { db in
            try String.fetchOne(db, sql: """
                SELECT value FROM slice_meta WHERE key = 'physical_schema'
                """) == "catalog-v7"
        }
    }

    /// 某药的全部说明书来源（同一文本可来自多个来源，按核验优先排序）。
    public func sources(forDrugID drugID: Int) async throws -> [MedicalCatalogLeaflet] {
        guard supportsLeaflets else { throw Failure.legacySchema }
        return try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.source_id, s.doc_sha256, s.name_zh, s.manufacturer,
                       s.source_url, s.fetched_at, l.match_method, l.match_verified
                FROM leaflet_link l JOIN leaflet_source s ON s.source_id = l.source_id
                WHERE l.drug_id = ?
                ORDER BY l.match_verified DESC, s.fetched_at DESC
                """, arguments: [drugID]).map { row in
                MedicalCatalogLeaflet(
                    sourceID: row["source_id"], docSHA256: row["doc_sha256"],
                    nameZh: row["name_zh"], manufacturer: row["manufacturer"],
                    matchMethod: row["match_method"],
                    matchVerified: (row["match_verified"] as Int64) == 1,
                    sourceURL: row["source_url"], fetchedAt: row["fetched_at"])
            }
        }
    }

    /// 章节目录（不解压正文）。
    public func sections(docSHA256: Data) async throws -> [MedicalCatalogLeafletSection] {
        guard supportsLeaflets else { throw Failure.legacySchema }
        return try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ordinal, kind, char_start, char_end
                FROM leaflet_section WHERE doc_sha256 = ? ORDER BY ordinal
                """, arguments: [docSHA256]).map { row in
                MedicalCatalogLeafletSection(
                    ordinal: row["ordinal"], kind: row["kind"],
                    charStart: row["char_start"], charEnd: row["char_end"])
            }
        }
    }

    /// 解压整份说明书；失败即报错，绝不返回空字符串冒充「没有内容」。
    public func text(docSHA256: Data) async throws -> String {
        guard supportsLeaflets else { throw Failure.legacySchema }
        let payload: (Data, Int)? = try await pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT text_zlib, text_bytes FROM leaflet_doc WHERE doc_sha256 = ?
                """, arguments: [docSHA256]).map { ($0["text_zlib"] as Data, $0["text_bytes"] as Int) }
        }
        guard let (compressed, expected) = payload else { throw Failure.unavailable }
        guard let decoded = Self.inflate(compressed), decoded.utf8.count == expected else {
            throw Failure.corruptText
        }
        return decoded
    }

    /// 一节正文；偏移是 Unicode 码点（与解析器一致），不是 UTF-8 字节。
    public func sectionText(section: MedicalCatalogLeafletSection, in text: String) -> String? {
        let characters = Array(text)
        guard section.charStart >= 0, section.charEnd > section.charStart,
              section.charEnd <= characters.count else { return nil }
        return String(characters[section.charStart..<section.charEnd])
    }

    static func inflate(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let capacity = max(64, data.count * 8)
        var buffer = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&buffer, buffer.count, base, data.count,
                                             nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return String(decoding: buffer[0..<written], as: UTF8.self)
    }
}
#endif
