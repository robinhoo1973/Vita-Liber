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

    /// 备份文件外层信封：`payload` 是 ExportService.Envelope 的编码，`sha256` 是
    /// **payload 字节的哈希**。恢复时重算并比对——这样校验才是真的。
    ///
    /// 旧实现把 sha256 只写进内存里的 `BackupPackage`、落盘时丢弃，`restore`
    /// 压根不比对，而注释却写着「校验和校验（完整性）」。**注释声称做了、代码没做**
    /// 与 ERR#27/#30 同族：把承诺当成证据。改为自包含外层信封后，
    /// 截断/位翻转在导入前必被拒，且不需要任何 sidecar 文件。
    struct BackupEnvelope: Codable {
        var formatVersion: Int
        var sha256: String
        var exportedAt: TimeInterval
        var payload: Data
    }

    public enum BackupError: Error, Sendable, Equatable {
        case checksumMismatch      // 文件损坏——一律拒绝导入，绝不「尽力恢复」
        case unsupportedFormat
        case conflictDetected      // ADR-019：目标库已有同名数据——不静默覆盖/丢弃
    }

    public func createBackup() async throws -> BackupPackage {
        let envelope = try await exporter.exportJSON()
        let payload = try await exporter.encode(envelope)
        let digest = Self.sha256(payload)
        let outer = BackupEnvelope(formatVersion: 1, sha256: digest,
                                   exportedAt: envelope.exportedAt, payload: payload)
        let data = try JSONEncoder().encode(outer)
        let name = "vitaliber-backup-\(Int(Date().timeIntervalSince1970)).json"
        return BackupPackage(fileName: name, data: data,
                             sha256: digest,
                             exportedAt: envelope.exportedAt)
    }

    /// 恢复：解外层 → **重算 payload 哈希并比对** → 解 envelope → 导入。
    /// 校验失败即抛错，**不做任何部分导入**——半个备份比没有备份更危险。
    /// 返回导入记录计数（FR13.5 恢复后数据校验报告的数据源）。
    @discardableResult
    public func restore(from data: Data) async throws -> Int {
        let outer: BackupEnvelope
        do {
            outer = try JSONDecoder().decode(BackupEnvelope.self, from: data)
        } catch {
            throw BackupError.unsupportedFormat
        }
        guard outer.formatVersion == 1 else { throw BackupError.unsupportedFormat }
        guard Self.sha256(outer.payload) == outer.sha256 else {
            throw BackupError.checksumMismatch
        }
        let envelope = try await exporter.decode(outer.payload)
        do {
            try await exporter.importJSON(envelope)
        } catch ExportService.ExportError.conflict {
            throw BackupError.conflictDetected
        }
        return envelope.totalRecords
    }

    static func sha256(_ data: Data) -> String {
        // 审查修复（P0）：显式限定 CryptoKit.SHA256——同名 Domain.SHA256（非泛型）
        // 在重载决议中胜出，其 Digest 未声明 Sequence 一致，.map 无法编译
        // （Apple 平台编译失败，Linux L0 因 #if 守卫扫不到）
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
