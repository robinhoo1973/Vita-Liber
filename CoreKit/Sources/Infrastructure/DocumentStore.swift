#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// F5 资料库数据仓（SP-09）：列表/归档/收藏/去重/入库。
/// BR-002：原件永不覆盖——写路径只 INSERT 新行或软状态变更，绝不 UPDATE 原件列。
public actor DocumentStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public enum StoreError: Error, Sendable {
        case invalidMember, invalidSource, invalidPage, unreviewedField, reviewConflict
    }

    static func validateSource(_ db: Database, patientId: UUID, documentId: UUID, pageIndex: Int,
                               requireRecognizedPage: Bool = true) throws {
        guard pageIndex >= 0 else { throw StoreError.invalidPage }
        guard let row = try Row.fetchOne(db, sql: """
            SELECT p.status AS page_status FROM document_file d
            JOIN patient_profile m ON m.id = d.patient_id
            JOIN document_page p ON p.document_file_id = d.id AND p.page_index = ?
            WHERE d.id = ? AND d.patient_id = ? AND m.deleted_at IS NULL
              AND d.status IN ('active','favorite')
            """, arguments: [pageIndex, documentId.uuidString, patientId.uuidString]) else {
            throw StoreError.invalidSource
        }
        let status: String = row["page_status"]
        guard ["ok", "failed", "skipped"].contains(status), !requireRecognizedPage || status == "ok" else {
            throw StoreError.invalidPage
        }
    }

    public struct DocumentRow: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var patientId: UUID
        public var encounterId: UUID?
        public var docType: String
        public var sha256: String?
        public var mimeType: String?
        public var origin: String
        public var status: String          // active/favorite/archived
        public var isSensitive: Bool
        public var title: String?
        /// 来源徽章 A–E（BR-003）：机器识别未确认 = 'D'，用户确认升 'C'。
        public var grade: String
        /// 投影元数据（标题/确认计数/修订历史/原件路径等 JSON 侧载，V3.41）。
        public var metaJSON: String?
        public var createdAt: Date
        /// BR-003 D 级判定（第四轮全仓审查修复：`grade == "D"` 裸字符串曾
        /// 散落 4 个视图文件 8 处内联——视图层不得承载业务判定，收敛为
        /// 行投影谓词，徽章语义唯一出处是 Domain 来源徽章纪律）。
        public var isPendingConfirmation: Bool { grade == "D" }
        public init(id: UUID, patientId: UUID, encounterId: UUID?, docType: String,
                    sha256: String?, mimeType: String?, origin: String, status: String,
                    isSensitive: Bool, title: String?, grade: String = "C",
                    metaJSON: String? = nil, createdAt: Date) {
            self.id = id; self.patientId = patientId; self.encounterId = encounterId
            self.docType = docType; self.sha256 = sha256; self.mimeType = mimeType
            self.origin = origin; self.status = status; self.isSensitive = isSensitive
            self.title = title; self.grade = grade; self.metaJSON = metaJSON; self.createdAt = createdAt
        }
    }

    /// FR6.1 页语义（V3.99 / 迁移 v21）：一条 OCR 记录的一页——失败/跳过页占位保页号。
    public struct Page: Sendable, Equatable {
        public let index: Int
        public let text: String?
        public let status: String   // ok / failed / skipped
        public init(index: Int, text: String?, status: String = "ok") {
            self.index = index; self.text = text; self.status = status
        }
    }

    public func list(patientId: UUID, includeArchived: Bool = false,
                     limit: Int = 200) async throws -> [DocumentRow] {
        try await writer.read { db in
            // 评审修正：status != 'archived' 会把 archived_favorite 组合态漏进活跃
            // 列表——白名单式过滤只放行活跃/收藏两态
            let statusClause = includeArchived ? "" : "AND status IN ('active','favorite')"
            return try Row.fetchAll(db, sql: """
                SELECT * FROM document_file
                WHERE patient_id = ? \(statusClause)
                ORDER BY created_at DESC LIMIT ?
                """, arguments: [patientId.uuidString, limit]).map(Self.row)
        }
    }

    /// 单文档取回（详情页用：列表不携带 meta_json，详情页需要解析原图路径等扩展字段）。
    public func fetch(id: UUID) async throws -> DocumentRow? {
        try await writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM document_file WHERE id = ?",
                             arguments: [id.uuidString]).map(Self.row)
        }
    }

    /// SP-53 待确认队列：跨成员聚合 D 级文档（第四轮全仓审查修复——队列
    /// 此前复用 list(patientId:)（仅当前成员），成员筛选对其他成员恒空态）。
    /// 占位符由 count 构造（非用户输入，无注入面）；上限保护查询规模。
    public func listPending(patientIds: [UUID], limit: Int = 500) async throws -> [DocumentRow] {
        guard !patientIds.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: patientIds.count).joined(separator: ",")
        // Swift 6 收敛：读闭包并发执行——args 一次性构造为不可变值再捕获
        // （原 var + append 的变异捕获在 Swift 6 语言模式转硬错误）
        let args: [DatabaseValueConvertible] = patientIds.map { $0.uuidString as DatabaseValueConvertible } + [limit]
        return try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM document_file
                WHERE patient_id IN (\(placeholders)) AND grade = 'D' AND status IN ('active','favorite')
                ORDER BY created_at DESC LIMIT ?
                """, arguments: StatementArguments(args)).map(Self.row)
        }
    }

    /// FR5.8 归档/取消归档（归档资料默认不出现在列表与搜索）。
    /// 评审修正：状态机坍缩——归档/收藏是正交标志但共用一列（CHECK 允许
    /// 'archived_favorite'），原实现写绝对值互相覆盖：收藏一个已归档文档
    /// 会把它静默移回活跃列表（FR5.8 归档语义破裂）。改为读当前状态计算
    /// 目标值：archived_favorite 组合态可产生、可逆。
    public func setArchived(id: UUID, archived: Bool, now: Date = Date()) async throws {
        try await writer.write { db in
            let current = try String.fetchOne(db, sql: "SELECT status FROM document_file WHERE id = ?",
                                               arguments: [id.uuidString])
            let target: String
            switch (current ?? "active", archived) {
            case (_, true) where current == "favorite" || current == "archived_favorite": target = "archived_favorite"
            case (_, true): target = "archived"
            case ("archived_favorite", false): target = "favorite"
            case ("archived", false): target = "active"
            case (let c, false): target = c
            }
            try db.execute(sql: """
                UPDATE document_file SET status = ?, updated_at = ? WHERE id = ?
                """, arguments: [target, now.timeIntervalSince1970, id.uuidString])
        }
    }

    /// FR5.8 收藏（对已归档文档收藏 → archived_favorite，绝不解除归档）
    public func setFavorite(id: UUID, favorite: Bool, now: Date = Date()) async throws {
        try await writer.write { db in
            let current = try String.fetchOne(db, sql: "SELECT status FROM document_file WHERE id = ?",
                                               arguments: [id.uuidString])
            let target: String
            switch (current ?? "active", favorite) {
            case ("archived", true), ("archived_favorite", true): target = "archived_favorite"
            case (_, true): target = "favorite"
            case ("archived_favorite", false): target = "archived"
            case ("favorite", false): target = "active"
            case (let c, false): target = c
            }
            try db.execute(sql: """
                UPDATE document_file SET status = ?, updated_at = ? WHERE id = ?
                """, arguments: [target, now.timeIntervalSince1970, id.uuidString])
        }
    }

    /// FR5.6 重复检测：文件哈希精确重复（感知哈希在 CaptureQuality DuplicateDetectionService）。
    /// 绝不自动删除——只提示并给并排对比（UI 层）。
    public func duplicates(sha256: String, patientId: UUID) async throws -> [DocumentRow] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM document_file WHERE patient_id = ? AND sha256 = ?
                """, arguments: [patientId.uuidString, sha256]).map(Self.row)
        }
    }

    /// 入库（BR-002：INSERT 新行；meta_json 承载投影元数据）。
    /// ocrText 写入 FTS 检索列（触发器自动索引）；grade = 来源徽章（BR-003：
    /// 机器识别未确认传 'D'，手工/已确认传 'C'）。
    @discardableResult
    public func save(patientId: UUID, docType: String, sha256: String?,
                     mimeType: String?, origin: String, isSensitive: Bool,
                     metaJSON: String?, title: String?,
                      ocrText: String? = nil, grade: String = "C",
                      pages: [Page] = [],
                      cards: [MatchedCard] = [], reviewedFields: [Int: [CandidateField]] = [:],
                      now: Date = Date()) async throws -> UUID {
        let id = UUID()
        try await writer.write { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM patient_profile WHERE id = ? AND deleted_at IS NULL",
                                   arguments: [patientId.uuidString]) == 1 else { throw StoreError.invalidMember }
            guard Set(pages.map(\.index)).count == pages.count,
                  pages.allSatisfy({ $0.index >= 0 && ["ok", "failed", "skipped"].contains($0.status) }) else {
                throw StoreError.invalidPage
            }
            try db.execute(sql: """
                INSERT INTO document_file
                  (id, patient_id, doc_type, sha256, mime_type, origin, status,
                   is_sensitive, meta_json, title, ocr_text, grade, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, patientId.uuidString, docType, sha256,
                                 mimeType, origin, isSensitive ? 1 : 0,
                                 metaJSON, title, ocrText, grade,
                                 now.timeIntervalSince1970,
                                 now.timeIntervalSince1970])
            // 页文本同事务落库（FR6.1 页语义）：单图 = 第 0 页；PDF 每页一行
            for page in pages {
                try db.execute(sql: """
                    INSERT INTO document_page (id, document_file_id, page_index, ocr_text, status, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, id.uuidString, page.index, page.text,
                                     page.status, now.timeIntervalSince1970])
            }
            try Self.stageReview(db, documentId: id, patientId: patientId, cards: cards, reviewedFields: reviewedFields, now: now)
        }
        return id
    }

    /// 文档的全部页（页序升序；无页记录的旧文档返回空——调用方回落 ocr_text）。
    public func pages(documentId: UUID) async throws -> [Page] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT page_index, ocr_text, status FROM document_page
                WHERE document_file_id = ? ORDER BY page_index
                """, arguments: [documentId.uuidString]).map {
                Page(index: $0["page_index"], text: $0["ocr_text"], status: $0["status"])
            }
        }
    }

    /// Review edits update projections, never source media or pages already cited by committed facts.
    public func updateReview(id: UUID, patientId: UUID, docType: String, isSensitive: Bool,
                             metaJSON: String?, ocrText: String?, grade: String, pages: [Page],
                             cards: [MatchedCard] = [], reviewedFields: [Int: [CandidateField]] = [:]) async throws {
        try await writer.write { db in
            guard !docType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ["C", "D"].contains(grade), Set(pages.map(\.index)).count == pages.count,
                  pages.allSatisfy({ $0.index >= 0 && ["ok", "failed", "skipped"].contains($0.status) }),
                  let document = try Row.fetchOne(db, sql: """
                    SELECT d.* FROM document_file d JOIN patient_profile p ON p.id = d.patient_id
                    WHERE d.id = ? AND d.patient_id = ? AND p.deleted_at IS NULL
                      AND d.status IN ('active','favorite')
                    """, arguments: [id.uuidString, patientId.uuidString]) else { throw StoreError.invalidSource }
            let previousPages = try Row.fetchAll(db, sql: "SELECT page_index, ocr_text, status FROM document_page WHERE document_file_id = ? ORDER BY page_index",
                                                arguments: [id.uuidString]).map {
                Page(index: $0["page_index"], text: $0["ocr_text"], status: $0["status"])
            }
            let orderedPages = pages.sorted { $0.index < $1.index }
            let receiptCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ocr_card_commit WHERE document_file_id = ?",
                                               arguments: [id.uuidString]) ?? 0
            // 审查修复：提交凭据冻结的是「页文本事实」——失败页重扫只改
            // status（复核过程态），原守卫把任何页面差异一律拒死（重扫成功
            // 也无法落库、该页永久卡失败）。凭据存在时仅拒文本变更/新增页。
            let textChanged = orderedPages.filter { new in
                previousPages.contains { $0.index == new.index && $0.text != new.text }
            }
            guard receiptCount == 0
                    || (textChanged.isEmpty && orderedPages.allSatisfy { p in previousPages.contains { $0.index == p.index } })
            else { throw StoreError.invalidPage }
            var metadata: [String: Any] = [:]
            if let metaJSON {
                guard let decoded = try JSONSerialization.jsonObject(with: Data(metaJSON.utf8)) as? [String: Any] else {
                    throw StoreError.invalidSource
                }
                metadata = decoded
            }
            if let oldJSON: String = document["meta_json"],
               let old = try JSONSerialization.jsonObject(with: Data(oldJSON.utf8)) as? [String: Any] {
                if metaJSON == nil { metadata = old }
                for key in ["original_path", "processed_path"] {
                    if let path = old[key] { metadata[key] = path }
                }
            }
            let storedMeta = metadata.isEmpty ? nil : String(decoding: try JSONSerialization.data(withJSONObject: metadata), as: UTF8.self)
            try db.execute(sql: """
                UPDATE document_file SET doc_type = ?, is_sensitive = ?, meta_json = ?, ocr_text = ?, grade = ?, updated_at = ?
                WHERE id = ? AND patient_id = ?
                """, arguments: [docType, isSensitive ? 1 : 0, storedMeta, ocrText, grade,
                                 Date().timeIntervalSince1970, id.uuidString, patientId.uuidString])
            if previousPages != orderedPages {
                if receiptCount == 0 {
                    // Existing page identities survive; omitted/changed historical pages are not silently erased.
                    guard previousPages.allSatisfy({ old in orderedPages.contains { $0.index == old.index && $0.text == old.text } }) else {
                        throw StoreError.invalidPage
                    }
                }
                for page in orderedPages where !previousPages.contains(where: { $0.index == page.index }) {
                    try db.execute(sql: """
                        INSERT INTO document_page (id, document_file_id, page_index, ocr_text, status, created_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [UUID().uuidString, id.uuidString, page.index, page.text, page.status, Date().timeIntervalSince1970])
                }
            }
            // 审查修复：状态变更（failed→ok 重扫成功等复核过程态）此前被
            // 静默丢弃——补 UPDATE 让复核结论可持久化（文本不变是前提，
            // 已由上方 textChanged 守卫保证）
            for page in orderedPages {
                if let old = previousPages.first(where: { $0.index == page.index }),
                   old.status != page.status {
                    try db.execute(sql: """
                        UPDATE document_page SET status = ? WHERE document_file_id = ? AND page_index = ?
                        """, arguments: [page.status, id.uuidString, page.index])
                }
            }
            try Self.stageReview(db, documentId: id, patientId: patientId, cards: cards, reviewedFields: reviewedFields, now: Date())
        }
    }

    /// A document is not committed without its resumable cards. Re-review never replaces a newer draft.
    private static func stageReview(_ db: Database, documentId: UUID, patientId: UUID, cards: [MatchedCard],
                                    reviewedFields: [Int: [CandidateField]], now: Date) throws {
        guard Set(cards.map(\.id)).count == cards.count,
              Set(cards.map { "\($0.pageIndex):\($0.kind)" }).count == cards.count else { throw StoreError.invalidPage }
        for card in cards {
            try validateSource(db, patientId: patientId, documentId: documentId, pageIndex: card.pageIndex)
            let existing = try Row.fetchAll(db, sql: """
                SELECT * FROM pending_card WHERE source_doc_id = ? AND source_page = ? AND card_kind = ? AND source_type = 'ocr'
                """, arguments: [documentId.uuidString, card.pageIndex, card.kind])
            guard existing.count <= 1 else { throw StoreError.reviewConflict }
            if let row = existing.first {
                let pending = try PendingCardStore.decode(row)
                guard pending.patientId == patientId, try pending.matchedCard() == card else { throw StoreError.reviewConflict }
                continue
            }
            let committed = Set(try String.fetchAll(db, sql: "SELECT row_id FROM ocr_card_commit WHERE card_id = ?",
                                                    arguments: [card.id.uuidString]))
            if !card.rows.isEmpty, card.rows.allSatisfy({ committed.contains($0.id.uuidString) || EntityCardProjection.isDiscarded($0, in: card) }) { continue }
            let raw = try String.fetchOne(db, sql: "SELECT ocr_text FROM document_page WHERE document_file_id = ? AND page_index = ?",
                                          arguments: [documentId.uuidString, card.pageIndex]) ?? ""
            _ = try PendingCardStore.upsert(.init(patientId: patientId, sourceType: "ocr", sourceDocId: documentId,
                sourcePage: card.pageIndex, cardKind: card.kind, incompleteFields: [], partialData: .init(card: card), rawText: raw),
                db: db, now: now)
        }
        for (page, fields) in reviewedFields where !fields.isEmpty {
            try validateSource(db, patientId: patientId, documentId: documentId, pageIndex: page)
            guard fields.allSatisfy(\.isConfirmed) else { throw StoreError.unreviewedField }
            for field in fields {
                let raw = String(decoding: try JSONEncoder().encode(FieldAudit(documentId: documentId, pageIndex: page, field: field)), as: UTF8.self)
                try db.execute(sql: """
                    INSERT INTO ocr_result (id, document_file_id, page_index, raw_blocks, engine_version, created_at)
                    VALUES (?, ?, ?, ?, 'ocr-document-review', ?)
                    """, arguments: [UUID().uuidString, documentId.uuidString, page, raw, now.timeIntervalSince1970])
            }
        }
    }

    /// BR-003 D→C 闸门：用户显式确认机器识别文本后，文档才进入检索与 AI 事实链。
    public func confirmText(id: UUID, patientId: UUID, now: Date = Date()) async throws {
        try await writer.write { db in
            guard try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM document_file d JOIN patient_profile p ON p.id = d.patient_id
                WHERE d.id = ? AND d.patient_id = ? AND p.deleted_at IS NULL AND d.status IN ('active','favorite')
                """, arguments: [id.uuidString, patientId.uuidString]) == 1 else { throw StoreError.invalidSource }
            try db.execute(sql: """
                UPDATE document_file SET grade = 'C', updated_at = ? WHERE id = ? AND patient_id = ? AND grade = 'D'
                """, arguments: [now.timeIntervalSince1970, id.uuidString, patientId.uuidString])
        }
    }

    /// FR6.1 OCR 结果留痕：每已确认字段一行（原文块+置信度+引擎版本，可追溯可重放）。
    /// V3.39 起为唯一写入口——旧 AppState 引擎（经 M1aPersisting）已随向导简化删除，
    /// 活管线 DocumentsState.commitDraft 在确认入库后调用。
    /// 第四轮全仓审查修复（FR6.4）：修订历史随留痕行持久化——用户改值后
    /// 「旧值 → 新值 · 修改人 · 时间」入 raw_blocks 尾部，修订链路可追溯
    /// （此前 revisionHistory 只在内存中、入不了库也无任何渲染）。
    public func saveOCRResult(documentId: UUID, patientId: UUID, pageIndex: Int = 0, fields: [CandidateField],
                              engineVersion: String) async throws {
        let now = Date()
        try await writer.write { db in
            try Self.validateSource(db, patientId: patientId, documentId: documentId, pageIndex: pageIndex)
            guard fields.allSatisfy(\.isConfirmed) else { throw StoreError.unreviewedField }
            for field in fields {
                let audit = FieldAudit(documentId: documentId, pageIndex: pageIndex, field: field)
                let raw = String(decoding: try JSONEncoder().encode(audit), as: UTF8.self)
                // V3.99：留痕写真实页号（此前恒 0——多页文档字段无法回到页）
                try db.execute(sql: """
                    INSERT INTO ocr_result
                      (id, document_file_id, page_index, raw_blocks, engine_version, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, documentId.uuidString, pageIndex,
                                     raw,
                                     engineVersion, now.timeIntervalSince1970])
            }
        }
    }

    private struct FieldAudit: Codable {
        let documentId: UUID
        let pageIndex: Int
        let field: CandidateField
    }

    private static func row(_ row: GRDB.Row) -> DocumentStore.DocumentRow {
        DocumentRow(id: UUID(uuidString: row["id"] as String) ?? UUID(),
            patientId: UUID(uuidString: row["patient_id"] as String) ?? UUID(),
            encounterId: (row["encounter_id"] as String?).flatMap(UUID.init(uuidString:)),
            docType: row["doc_type"] as String,
            sha256: row["sha256"] as String?,
            mimeType: row["mime_type"] as String?,
            origin: row["origin"] as String,
            status: row["status"] as String,
            isSensitive: (row["is_sensitive"] as Int?) == 1,
            title: row["title"] as String?,
            grade: (row["grade"] as String?) ?? "C",
            metaJSON: row["meta_json"] as String?,
            createdAt: Date(timeIntervalSince1970: row["created_at"] as Double))
    }
}
#endif
