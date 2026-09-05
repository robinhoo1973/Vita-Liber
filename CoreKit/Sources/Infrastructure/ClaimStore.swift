// 平台守卫镜像 Package.swift（ERR#8 纪律）
#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain

/// FR13.7 报销票据仓储（actor）——「聚合整理」语义：
/// 录入发票/费用/收据 → 挂就诊/资料 → 汇总（纯事实求和，不做报销建议）。
public actor ClaimStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public struct ClaimRow: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var itemType: String          // invoice/fee/receipt
        public var amount: Double
        public var currency: String
        public var date: Date
        public var merchant: String
        public var summary: String
        public var confirmed: Bool
        public init(id: UUID, itemType: String, amount: Double, currency: String,
                    date: Date, merchant: String, summary: String, confirmed: Bool) {
            self.id = id; self.itemType = itemType; self.amount = amount
            self.currency = currency; self.date = date; self.merchant = merchant
            self.summary = summary; self.confirmed = confirmed
        }
    }

    public func create(id: UUID = UUID(), patientId: UUID, itemType: String,
                       amount: Double, date: Date, merchant: String,
                       summary: String = "", encounterId: UUID? = nil,
                       documentFileId: UUID? = nil) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO claim_item
                  (id, patient_id, encounter_id, document_file_id, item_type,
                   amount, currency, date, merchant, summary, confirmed,
                   created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                """, arguments: [id.uuidString, patientId.uuidString,
                                 encounterId?.uuidString, documentFileId?.uuidString,
                                 itemType, amount, "CNY",
                                 date.timeIntervalSince1970, merchant, summary,
                                 Date().timeIntervalSince1970, Date().timeIntervalSince1970])
        }
    }

    public func list(patientId: UUID) async throws -> [ClaimRow] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM claim_item WHERE patient_id = ?
                ORDER BY date DESC
                """, arguments: [patientId.uuidString])
            return rows.map { row in
                ClaimRow(id: UUID(uuidString: row["id"] as String) ?? UUID(),
                         itemType: row["item_type"] as String,
                         amount: row["amount"] as Double? ?? 0,
                         currency: row["currency"] as String? ?? "CNY",
                         date: Date(timeIntervalSince1970: row["date"] as Double),
                         merchant: row["merchant"] as String? ?? "",
                         summary: row["summary"] as String? ?? "",
                         confirmed: (row["confirmed"] as Int?) == 1)
            }
        }
    }

    /// 纯事实汇总（FR13.7）：只求和，**不提供报销建议/不评判是否可报**。
    /// 审查修复：移除 Infrastructure 内硬编码 zh-Hans 文案（statement）——
    /// 展示文案由视图层经 L10n 单出口组装（zh-Hant/en 用户此前看到简中句子）
    public struct Totals: Sendable, Equatable {
        public var totalAmount: Double
        public var itemCount: Int
        public var currency: String
        public init(totalAmount: Double, itemCount: Int, currency: String) {
            self.totalAmount = totalAmount; self.itemCount = itemCount; self.currency = currency
        }
    }

    public func totals(patientId: UUID) async throws -> Totals {
        let rows = try await list(patientId: patientId)
        return Totals(totalAmount: rows.reduce(0) { $0 + $1.amount },
                      itemCount: rows.count,
                      currency: rows.first?.currency ?? "CNY")
    }
}
#endif
