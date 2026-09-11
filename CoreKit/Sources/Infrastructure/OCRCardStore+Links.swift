#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain

extension OCRCardStore {
    public struct SourcePage: Sendable, Identifiable {
        public let documentId: UUID
        public let pageIndex: Int
        public let title: String?
        public var id: String { "\(documentId.uuidString)#p\(pageIndex)" }
    }
    public struct CardDetail: Sendable {
        public let kind: String
        public let entityId: UUID
        public let patientId: UUID
        public let fields: [FieldDraft]
        public let sources: [SourcePage]
        public let encounterIDs: [UUID]
        public let relationshipEditable: Bool
    }

    /// 已确认卡的真实字段 + 独立原件页链接；D级草稿不参与该读面。
    public func detail(kind: String, entityId: UUID, patientId: UUID) async throws -> CardDetail {
        guard Self.supportedKinds.contains(kind) else { throw StoreError.invalidCard }
        return try await writer.read { db in
            guard let fact = try Row.fetchOne(db, sql: "SELECT * FROM \(kind) WHERE id = ? AND patient_id = ?",
                                             arguments: [entityId.uuidString, patientId.uuidString]) else { throw StoreError.invalidCard }
            if ["prescription", "claim_item", "immunization"].contains(kind), (fact["confirmed"] as Int?) != 1 { throw StoreError.invalidCard }
            if kind == "encounter", (fact["deleted_at"] as Double?) != nil { throw StoreError.invalidCard }
            let receipts = try Row.fetchAll(db, sql: "SELECT * FROM ocr_card_commit WHERE card_kind = ? AND entity_id = ? AND patient_id = ? ORDER BY document_file_id, page_index, row_id",
                                           arguments: [kind, entityId.uuidString, patientId.uuidString])
            var sources: [SourcePage] = [], encounters = Set<UUID>()
            for receipt in receipts {
                try Self.validateReceipt(receipt, db: db)
                guard let document = UUID(uuidString: receipt["document_file_id"] as String) else { throw StoreError.corruptReceipt }
                let page = SourcePage(documentId: document, pageIndex: receipt["page_index"],
                    title: try String.fetchOne(db, sql: "SELECT title FROM document_file WHERE id = ? AND patient_id = ?", arguments: [document.uuidString, patientId.uuidString]))
                if !sources.contains(where: { $0.id == page.id }) { sources.append(page) }
                if let id = (receipt["encounter_id"] as String?).flatMap(UUID.init(uuidString:)) { encounters.insert(id) }
            }
            if kind == "encounter" { encounters.insert(entityId) }
            if ["prescription", "claim_item", "immunization"].contains(kind), let id = (fact["encounter_id"] as String?).flatMap(UUID.init(uuidString:)) { encounters.insert(id) }
            var fields: [FieldDraft] = []
            func append(_ key: String, _ value: String?) {
                if let value, !value.isEmpty { fields.append(.init(key: key, value: value, grade: .userConfirmed)) }
            }
            let keys: [String]
            switch kind {
            case "prescription": keys = ["hospital", "doctor", "advice_text"]
            case "claim_item": keys = ["item_type", "currency", "merchant", "summary"]
            case "medication": keys = ["generic_name", "brand_name", "spec", "unit_kind"]
            case "immunization": keys = ["vaccine_name", "provider", "lot_number"]
            case "metric_sample": keys = ["raw_label", "unit", "ref_source_label"]
            case "encounter": keys = ["hospital", "department", "doctor", "chief_complaint", "diagnosis_text", "advice_text"]
            default: keys = []
            }
            for key in keys { append(key, fact[key] as String?) }
            if kind == "claim_item" { append("amount", (fact["amount"] as Double?).map(String.init(describing:))) }
            if kind == "metric_sample" {
                for key in ["value", "ref_low", "ref_high"] { append(key, (fact[key] as Double?).map(String.init(describing:))) }
            }
            if kind == "immunization" { append("dose_number", (fact["dose_number"] as Int?).map(String.init)) }
            let pending = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM pending_card p JOIN ocr_card_commit c ON c.card_id = p.id
                WHERE c.entity_id = ? AND c.card_kind = ? AND c.patient_id = ? AND p.status IN ('pending','in_progress')
                """, arguments: [entityId.uuidString, kind, patientId.uuidString]) ?? 0
            let active = try encounters.filter { id in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM encounter WHERE id = ? AND patient_id = ? AND deleted_at IS NULL", arguments: [id.uuidString, patientId.uuidString]) == 1
            }.sorted { $0.uuidString < $1.uuidString }
            return .init(kind: kind, entityId: entityId, patientId: patientId, fields: fields, sources: sources,
                         encounterIDs: active, relationshipEditable: kind != "encounter" && pending == 0)
        }
    }

    /// 原件的所有已确认实体卡供反向导航。仅查该原件，不把整库备份查询用于详情热路径。
    public func cards(documentId: UUID, patientId: UUID) async throws -> [(kind: String, id: UUID)] {
        try await writer.read { db in
            guard try String.fetchOne(db, sql: "SELECT patient_id FROM document_file WHERE id = ?", arguments: [documentId.uuidString]) == patientId.uuidString else { throw StoreError.invalidCard }
            return try Row.fetchAll(db, sql: "SELECT DISTINCT card_kind, entity_id FROM ocr_card_commit WHERE document_file_id = ? AND patient_id = ? ORDER BY card_kind, entity_id",
                                   arguments: [documentId.uuidString, patientId.uuidString]).compactMap { row in
                guard let id = UUID(uuidString: row["entity_id"] as String) else { return nil }
                return (row["card_kind"] as String, id)
            }
        }
    }

    public func associatedEncounters(documentId: UUID, patientId: UUID) async throws -> [UUID] {
        try await writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT e.id FROM encounter e JOIN (
                  SELECT encounter_id AS id FROM document_file WHERE id = ? AND patient_id = ?
                  UNION SELECT COALESCE(encounter_id, CASE WHEN card_kind = 'encounter' THEN entity_id END) AS id
                    FROM ocr_card_commit WHERE document_file_id = ? AND patient_id = ?
                  UNION SELECT encounter_id AS id FROM prescription WHERE document_file_id = ? AND patient_id = ? AND confirmed = 1
                  UNION SELECT encounter_id AS id FROM claim_item WHERE document_file_id = ? AND patient_id = ? AND confirmed = 1
                ) r ON r.id = e.id WHERE e.patient_id = ? AND e.deleted_at IS NULL ORDER BY e.date DESC
                """, arguments: [documentId.uuidString, patientId.uuidString, documentId.uuidString, patientId.uuidString,
                    documentId.uuidString, patientId.uuidString, documentId.uuidString, patientId.uuidString, patientId.uuidString])
                .compactMap(UUID.init(uuidString:))
        }
    }

    public func associate(kind: String, entityId: UUID, patientId: UUID, encounterId: UUID?) async throws {
        guard Self.supportedKinds.contains(kind), kind != "encounter" else { throw StoreError.invalidCard }
        try await writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \(kind) WHERE id = ? AND patient_id = ?",
                                            arguments: [entityId.uuidString, patientId.uuidString]) else { throw StoreError.invalidCard }
            if ["prescription", "claim_item", "immunization"].contains(kind), (row["confirmed"] as Int?) != 1 { throw StoreError.invalidCard }
            if let encounterId {
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM encounter WHERE id = ? AND patient_id = ? AND deleted_at IS NULL",
                                       arguments: [encounterId.uuidString, patientId.uuidString]) == 1 else { throw StoreError.invalidAssociation }
            }
            let pending = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM pending_card p JOIN ocr_card_commit c ON c.card_id = p.id
                WHERE c.entity_id = ? AND c.card_kind = ? AND c.patient_id = ? AND p.status IN ('pending','in_progress')
                """, arguments: [entityId.uuidString, kind, patientId.uuidString]) ?? 0
            guard pending == 0 else { throw StoreError.committedDataChanged }
            if ["prescription", "claim_item", "immunization"].contains(kind) {
                try db.execute(sql: "UPDATE \(kind) SET encounter_id = ?, updated_at = ? WHERE id = ? AND patient_id = ?",
                               arguments: [encounterId?.uuidString, Date().timeIntervalSince1970, entityId.uuidString, patientId.uuidString])
            }
            try db.execute(sql: "UPDATE ocr_card_commit SET encounter_id = ? WHERE card_kind = ? AND entity_id = ? AND patient_id = ?",
                           arguments: [encounterId?.uuidString, kind, entityId.uuidString, patientId.uuidString])
            let meta = String(decoding: try JSONEncoder().encode(["relationship": "encounter", "linked": encounterId == nil ? "false" : "true"]), as: UTF8.self)
            try AuditLogWriter.insert(action: "update", entityType: kind, entityId: entityId.uuidString, actorLocal: "owner", meta: meta, db: db)
        }
    }
}
#endif
