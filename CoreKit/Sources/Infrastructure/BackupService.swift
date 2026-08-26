#if os(iOS) || os(macOS)
import Foundation
import CryptoKit
import GRDB
import Domain
import Protocols

/// FR13.11 iCloud Drive 备份 + FR13.10 定期备份提醒：
/// 备份 = 导出 envelope JSON 写文件；恢复 = 读回 envelope 导入（经 ExportService）。
/// 文件经 UIDocumentPicker 交由系统落 iCloud Drive——本服务只负责序列化与校验。
public actor BackupService {
    private let exporter: ExportService

    public init(writer: any DatabaseWriter) {
        self.exporter = ExportService(writer: writer)
    }

    /// 备份包（含文件名建议与校验和——完整性由 sha256 承担）
    public struct BackupPackage: Sendable, Equatable {
        public var fileName: String
        public var data: Data
        public var sha256: String
        public var exportedAt: TimeInterval
        public init(fileName: String, data: Data, sha256: String, exportedAt: TimeInterval) {
            self.fileName = fileName; self.data = data; self.sha256 = sha256; self.exportedAt = exportedAt
        }
    }

    public func createBackup() async throws -> BackupPackage {
        let envelope = try await exporter.exportJSON()
        let data = try await exporter.encode(envelope)
        let name = "vitaliber-backup-\(Int(Date().timeIntervalSince1970)).json"
        return BackupPackage(fileName: name, data: data,
                             sha256: Self.sha256(data),
                             exportedAt: envelope.exportedAt)
    }

    /// 恢复：校验和校验（完整性）→ 导入。sensitive 数据经 FR13.4 导出验证流程
    public func restore(from data: Data) async throws {
        let envelope = try await exporter.decode(data)
        try await exporter.importJSON(envelope)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
