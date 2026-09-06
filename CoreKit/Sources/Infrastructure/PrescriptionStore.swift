#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols

/// F9 处方数据仓（actor，GRDB）：拍处方 OCR 确认后落库的最小可行入口。
///
/// **口径说明**：`prescription` 表当前 schema 只有 hospital/doctor/advice_text 等
/// 列，没有药名/剂量/频次的独立结构化列——`PrescriptionFieldMapper.buildAdviceText`
/// 把用户确认过的全部字段折叠进一段带标签文本写入 `advice_text`，避免因为暂无列
/// 可落而静默丢弃已确认内容。后续如需独立结构化列，需要一次单独的 schema 迁移。
public actor PrescriptionStore {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    /// BR-003：OCR 来源写入时已经过用户逐字段确认（调用方只在确认完成后才调用本方法），
    /// 故 `confirmed` 恒为 true——未确认草稿不建议持久化本表，留在确认卡内存态即可。
    @discardableResult
    public func create(patientId: UUID, documentFileId: UUID?, hospital: String?, doctor: String?,
                       adviceText: String, source: PrescriptionSource = .ocr,
                       now: Date = Date()) async throws -> UUID {
        let id = UUID()
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO prescription
                  (id, patient_id, document_file_id, source, hospital, doctor,
                   prescribed_at, advice_text, confirmed, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                """, arguments: [id.uuidString, patientId.uuidString, documentFileId?.uuidString,
                                 source.rawValue, hospital, doctor, now.timeIntervalSince1970,
                                 adviceText, now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
        return id
    }
}
#endif
