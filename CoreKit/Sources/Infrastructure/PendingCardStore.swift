#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain

/// FR6.9 待办卡（pending_card 表，data-flow §3.5/§18 单一事实源）：
/// 「跳过稍后」暂存的 D 级草稿卡。本仓承载建卡/查询/生命周期推进/级联移除；
/// 提醒链（1h 通知 → 24h 后每 12h → 72h 置顶）由聚合中心投影 + 通知调度
/// 消费本仓状态（FR6.9 待办队列纪律）。
///
/// BR-003 红线（表级排除）：本表数据绝不进入搜索索引/FTS 投影/AI 检索/
/// 导出——只允许经 `AggregatedReminderItem`（非敏感摘要标题）投影到
/// 首页聚合中心与通知中心；raw_text/partial_data 不外泄到任何事实链。

/// 待办卡读取值对象（写侧入参见 `PendingCardDraft`）。
public struct PendingCard: Sendable, Equatable, Identifiable {
    public var id: String
    public var patientId: UUID
    public var sourceType: String          // ocr/voice/manual
    public var sourceDocId: UUID?
    /// 所属页号（V3.99 页级多卡；与 sourceDocId 配对，单图 0；旧行 nil）
    public var sourcePage: Int?
    public var cardKind: String
    public var incompleteFields: [IncompleteField]
    /// 共享字段 + 多行（旧行纯字典 → shared）
    public var partialData: PendingCardPayload
    public var rawText: String
    public var attemptCount: Int
    public var status: String              // pending/in_progress/resolved/expired/archived
    public var createdAt: Date
    public var updatedAt: Date
    public var resolvedAt: Date?
    public var resolvedBy: String?         // user/llm/expired
    public var note: String?

    public init(id: String, patientId: UUID, sourceType: String, sourceDocId: UUID?,
                sourcePage: Int? = nil,
                cardKind: String, incompleteFields: [IncompleteField],
                partialData: PendingCardPayload, rawText: String, attemptCount: Int,
                status: String, createdAt: Date, updatedAt: Date,
                resolvedAt: Date?, resolvedBy: String?, note: String?) {
        self.id = id
        self.patientId = patientId
        self.sourceType = sourceType
        self.sourceDocId = sourceDocId
        self.sourcePage = sourcePage
        self.cardKind = cardKind
        self.incompleteFields = incompleteFields
        self.partialData = partialData
        self.rawText = rawText
        self.attemptCount = attemptCount
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resolvedAt = resolvedAt
        self.resolvedBy = resolvedBy
        self.note = note
    }

    public func matchedCard() throws -> MatchedCard {
        guard sourceDocId != nil, let sourcePage, let id = UUID(uuidString: id) else {
            throw PendingCardPayload.PayloadError.identityMismatch
        }
        return try partialData.matchedCard(kind: cardKind, pageIndex: sourcePage, id: id)
    }
}

/// incomplete_fields JSON 行形态（data-flow §18.1.2）。
public struct IncompleteField: Codable, Sendable, Equatable {
    public var key: String
    public var rowId: UUID?
    public var label: String?
    public var rawText: String?
    public var confidence: Double
    public var reason: String?

    public init(key: String, label: String? = nil, rawText: String? = nil,
                confidence: Double = 0, reason: String? = nil, rowId: UUID? = nil) {
        self.key = key
        self.rowId = rowId
        self.label = label
        self.rawText = rawText
        self.confidence = confidence
        self.reason = reason
    }
}

/// 建卡入参。
public struct PendingCardDraft: Sendable, Equatable {
    public var patientId: UUID
    public var sourceType: String
    public var sourceDocId: UUID?
    public var sourcePage: Int?
    public var cardKind: String
    public var incompleteFields: [IncompleteField]
    public var partialData: PendingCardPayload
    public var rawText: String
    public var note: String?

    public init(patientId: UUID, sourceType: String, sourceDocId: UUID?, sourcePage: Int? = nil,
                cardKind: String, incompleteFields: [IncompleteField],
                partialData: PendingCardPayload, rawText: String, note: String? = nil) {
        self.patientId = patientId
        self.sourceType = sourceType
        self.sourceDocId = sourceDocId
        self.sourcePage = sourcePage
        self.cardKind = cardKind
        self.incompleteFields = incompleteFields
        self.partialData = partialData
        self.rawText = rawText
        self.note = note
    }

    /// 旧调用点兼容：键→值字典视为共享字段
    public init(patientId: UUID, sourceType: String, sourceDocId: UUID?,
                cardKind: String, incompleteFields: [IncompleteField],
                partialData: [String: String], rawText: String, note: String? = nil) {
        self.init(patientId: patientId, sourceType: sourceType, sourceDocId: sourceDocId, sourcePage: nil,
                  cardKind: cardKind, incompleteFields: incompleteFields,
                  partialData: PendingCardPayload(shared: partialData), rawText: rawText, note: note)
    }
}

public actor PendingCardStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    /// 建卡（§21.1 同源去重：同 source_doc_id + card_kind 已有未完结卡 →
    /// 更新快照复用，不重复创建；source_doc_id 缺失时——确认卡阶段尚未
    /// 建档/手工/语音源——按 同成员+卡种+原文 复用活跃卡，重复跳过不建
    /// 重复卡（fr69-aggregation-round1 二轮复核 A 项）。返回生效卡 id。
    @discardableResult
    public func upsert(_ draft: PendingCardDraft) async throws -> String {
        try await writer.write { db in try Self.upsert(draft, db: db, now: Date()) }
    }

    static func upsert(_ draft: PendingCardDraft, db: Database, now date: Date) throws -> String {
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM patient_profile WHERE id = ? AND deleted_at IS NULL",
                               arguments: [draft.patientId.uuidString]) == 1 else { throw DocumentStore.StoreError.invalidMember }
        if draft.sourceType == "ocr" {
            guard let document = draft.sourceDocId, let page = draft.sourcePage,
                  OCRCardStore.supportedKinds.contains(draft.cardKind) else { throw DocumentStore.StoreError.invalidSource }
            try DocumentStore.validateSource(db, patientId: draft.patientId, documentId: document,
                                             pageIndex: page, requireRecognizedPage: false)
            if let card = draft.partialData.card, card.kind != draft.cardKind || card.pageIndex != page {
                throw PendingCardPayload.PayloadError.identityMismatch
            }
            let sourceCards = try String.fetchAll(db, sql: "SELECT DISTINCT card_id FROM ocr_card_commit WHERE document_file_id = ? AND page_index = ? AND card_kind = ?",
                                                 arguments: [document.uuidString, page, draft.cardKind])
            if !sourceCards.isEmpty, !sourceCards.contains(draft.partialData.card?.id.uuidString ?? "") {
                throw PendingCardPayload.PayloadError.identityMismatch
            }
        }
        let incompleteJSON = String(data: try JSONEncoder().encode(draft.incompleteFields),
                                    encoding: .utf8) ?? "[]"
        let partialJSON = try draft.partialData.json
        let now = date.timeIntervalSince1970
        let updateSnapshot = { (db: Database, id: String) throws -> Void in
            guard let existing = try Row.fetchOne(db, sql: "SELECT * FROM pending_card WHERE id = ?", arguments: [id]) else {
                throw StoreError.inactive
            }
            let old = try Self.decode(existing)
            if let previous = old.partialData.card, let next = draft.partialData.card, previous.id != next.id {
                throw PendingCardPayload.PayloadError.identityMismatch
            }
            var snapshotJSON = partialJSON
            if draft.sourceType == "ocr" {
                let committed = Set(try String.fetchAll(db, sql: "SELECT row_id FROM ocr_card_commit WHERE card_id = ?",
                                                       arguments: [old.partialData.card?.id.uuidString ?? id]))
                if !committed.isEmpty {
                    guard let previous = old.partialData.card, let next = draft.partialData.card else { throw StoreError.useOCRCardStore }
                    snapshotJSON = try PendingCardPayload(card: OCRCardStore.mergeDraft(next, previous: previous, committed: committed)).json
                }
            }
            try db.execute(sql: """
                UPDATE pending_card
                SET incomplete_fields = ?, partial_data = ?, raw_text = ?,
                    updated_at = ?, note = ?
                WHERE id = ?
                """, arguments: [incompleteJSON, snapshotJSON, draft.rawText, now,
                                 draft.note ?? NSNull(), id])
        }
        if let docId = draft.sourceDocId?.uuidString {
            let existing = try Row.fetchAll(db, sql: """
                SELECT id, status FROM pending_card
                WHERE source_doc_id = ? AND card_kind = ? AND source_page IS ? AND patient_id = ? AND source_type = ?
                  AND (status IN ('pending','in_progress') OR source_type = 'ocr')
                """, arguments: [docId, draft.cardKind, draft.sourcePage, draft.patientId.uuidString, draft.sourceType])
            guard existing.count <= 1 else { throw PendingCardPayload.PayloadError.identityMismatch }
            if let row = existing.first {
                guard ["pending", "in_progress"].contains(row["status"] as String) else { throw StoreError.inactive }
                let id: String = row["id"]
                try updateSnapshot(db, id)
                return id
            }
        } else {
            let existing: String? = try String.fetchOne(db, sql: """
                SELECT id FROM pending_card
                WHERE patient_id = ? AND card_kind = ? AND raw_text = ? AND source_doc_id IS NULL AND source_type = ?
                  AND status IN ('pending','in_progress') LIMIT 1
                """, arguments: [draft.patientId.uuidString, draft.cardKind, draft.rawText, draft.sourceType])
            if let id = existing {
                try updateSnapshot(db, id)
                return id
            }
        }
        let id = draft.partialData.card?.id.uuidString ?? UUID().uuidString
        try db.execute(sql: """
            INSERT INTO pending_card
              (id, patient_id, source_type, source_doc_id, source_page, card_kind,
               incomplete_fields, partial_data, raw_text, attempt_count,
               status, created_at, updated_at, resolved_at, resolved_by, note)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 'pending', ?, ?, NULL, NULL, ?)
            """, arguments: [id, draft.patientId.uuidString, draft.sourceType,
                             draft.sourceDocId?.uuidString ?? NSNull(), draft.sourcePage ?? NSNull(),
                             draft.cardKind, incompleteJSON, partialJSON, draft.rawText, now, now, draft.note ?? NSNull()])
        return id
    }

    /// 列出成员待办卡（默认活跃态 pending/in_progress；`statuses` 显式指定）。
    public func list(patientId: UUID,
                     statuses: [String] = ["pending", "in_progress"]) async throws -> [PendingCard] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM pending_card
                WHERE patient_id = ? AND status IN (\(statuses.map { _ in "?" }.joined(separator: ",")))
                ORDER BY created_at DESC
                """, arguments: StatementArguments([patientId.uuidString] + statuses))
            return try rows.map(Self.decode)
        }
    }

    /// 用户/LLM 补全后完结（§21.2：status=resolved + resolved_by）。
    public func markResolved(id: String, by: String, note: String? = nil) async throws {
        let now = Date().timeIntervalSince1970
        try await writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT source_type, status FROM pending_card WHERE id = ?", arguments: [id]),
                  ["pending", "in_progress"].contains(row["status"] as String) else { throw StoreError.inactive }
            if (row["source_type"] as String) == "ocr", note != "discarded" { throw StoreError.useOCRCardStore }
            try db.execute(sql: """
                UPDATE pending_card
                SET status = 'resolved', resolved_at = ?, resolved_by = ?, updated_at = ?, note = ?
                WHERE id = ? AND status IN ('pending','in_progress')
                """, arguments: [now, by, now, note ?? NSNull(), id])
        }
    }

    /// 生命周期推进（FR6.9/§21.3）：7 天未处理 → expired（通知用户）；
    /// 30 天 → archived（不再提醒、移出活跃投影）。
    /// 幂等：只推进未完结卡；返回 (过期数, 归档数) 供提醒链消费。
    public func advanceLifecycle(now: Date = Date()) async throws -> (expired: Int, archived: Int) {
        let nowEpoch = now.timeIntervalSince1970
        let expiredCutoff = nowEpoch - 7 * 86400
        let archivedCutoff = nowEpoch - 30 * 86400
        return try await writer.write { db -> (Int, Int) in
            try db.execute(sql: """
                UPDATE pending_card SET status = 'expired', updated_at = ?
                WHERE status IN ('pending','in_progress') AND created_at < ?
                """, arguments: [nowEpoch, expiredCutoff])
            let expired = db.changesCount
            try db.execute(sql: """
                UPDATE pending_card SET status = 'archived', resolved_at = ?,
                    resolved_by = 'expired', updated_at = ?
                WHERE status = 'expired' AND created_at < ?
                """, arguments: [nowEpoch, nowEpoch, archivedCutoff])
            let archived = db.changesCount
            return (expired, archived)
        }
    }

    /// 单卡读取（待办卡详情 sheet）。
    public func card(id: String) async throws -> PendingCard? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM pending_card WHERE id = ?",
                                             arguments: [id]) else { return nil }
            return try Self.decode(row)
        }
    }

    /// 来源文档删除级联移除（§21.3）。
    public func removeForSourceDoc(_ sourceDocId: UUID) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM pending_card WHERE source_doc_id = ?",
                           arguments: [sourceDocId.uuidString])
        }
    }

    /// 聚合中心待办投影（data-flow §20.1）：仅活跃态；非敏感摘要标题，
    /// dueDate = created_at + 24h。BR-003：raw_text/partial_data 不外泄。
    public func aggregationItems(patientId: UUID) async throws -> [AggregatedReminderItem] {
        let cards = try await list(patientId: patientId)
        return cards.map {
            ReminderAggregationCenter.pendingCardItem(
                cardId: $0.id, cardKind: $0.cardKind, patientId: $0.patientId,
                createdAt: $0.createdAt, status: $0.status)
        }
    }

    public enum StoreError: Error, Sendable { case inactive, useOCRCardStore }

    static func decode(_ row: Row) throws -> PendingCard {
        let incomplete: [IncompleteField]
        do { incomplete = try JSONDecoder().decode([IncompleteField].self, from: Data((row["incomplete_fields"] as String).utf8)) }
        catch { throw PendingCardPayload.PayloadError.corrupt }
        let partial = try PendingCardPayload.decode(row["partial_data"] as String, cardKind: row["card_kind"])
        guard let patientId = UUID(uuidString: row["patient_id"]) else { throw PendingCardPayload.PayloadError.corrupt }
        let source: String? = row["source_doc_id"]
        if let source, UUID(uuidString: source) == nil { throw PendingCardPayload.PayloadError.corrupt }
        return PendingCard(
            id: row["id"],
            patientId: patientId,
            sourceType: row["source_type"],
            sourceDocId: (row["source_doc_id"] as String?).flatMap(UUID.init(uuidString:)),
            sourcePage: row["source_page"] as Int?,
            cardKind: row["card_kind"],
            incompleteFields: incomplete,
            partialData: partial,
            rawText: row["raw_text"],
            attemptCount: row["attempt_count"],
            status: row["status"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            resolvedAt: (row["resolved_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            resolvedBy: row["resolved_by"] as String?,
            note: row["note"] as String?)
    }
}

import Observation

/// App 层环境注入门面（同 NotificationCenterState 纪律）：@Environment 要求
/// @Observable 类型，actor 不可直接注入——本门面把 FR6.9 待办队列暴露为
/// 可观察投影（ReminderAggregationCenter.pendingCardItem 非敏感摘要，
/// BR-003：raw_text/partial_data 绝不外泄到视图），供首页聚合中心消费。
@MainActor
@Observable
public final class PendingCardCenterState {
    public private(set) var items: [AggregatedReminderItem] = []
    /// 详情 sheet 用（D 级草稿详情仅用户本人可见；不进入任何事实链投影）
    public private(set) var detail: PendingCard?
    public private(set) var loadError: String?
    private let store: PendingCardStore
    private var loadedPatientId: UUID?

    public init(store: PendingCardStore) { self.store = store }

    public func load(patientId: UUID) async {
        loadedPatientId = patientId
        loadError = nil
        do {
            let projected = try await store.aggregationItems(patientId: patientId)
            guard loadedPatientId == patientId else { return }   // BR-001 竞态守卫
            items = projected
        } catch {
            guard loadedPatientId == patientId else { return }
            loadError = String(describing: error)
            items = []   // try?-ok 同族：读取失败按空态渲染，不静默假数据
        }
    }

    public func refresh(patientId: UUID) {
        Task { await load(patientId: patientId) }
    }

    public func loadDetail(id: String) async {
        // 先清旧详情（fr69-aggregation-round1 二轮复核 B 项）：连开第二张卡
        // 时旧卡详情短暂闪现——详情 sheet 与列表项不同步的错位观感
        detail = nil
        loadError = nil
        do { detail = try await store.card(id: id) }
        catch { loadError = String(describing: error) }
    }

    /// 用户补全完结（期一无 LLM 补全；resolved_by=user）后刷新投影。
    public func resolve(patientId: UUID, id: String) {
        Task {
            do {
                try await store.markResolved(id: id, by: "user")
                await load(patientId: patientId)
            } catch { loadError = String(describing: error) }
        }
    }
}
#endif
