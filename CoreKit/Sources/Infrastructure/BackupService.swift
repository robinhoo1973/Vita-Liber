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

    /// 备份外层（审查修复：二进制 v1 信封替代 JSON+base64——JSON 信封把 payload
    /// 再 base64 复制一份，年久库导出时 payload/编码缓冲/外层 JSON 三份并存，
    /// 内存峰值 ≈ 3×payload；二进制信封 = magic + 版本 + sha256 + 长度 + 原始字节，
    /// 无任何复制，峰值 ≈ 1×payload）。restore 兼容两种格式。
    static let binaryMagic = Data("VLBU1".utf8)

    struct BackupEnvelope: Codable {   // 遗留 JSON 格式（v0 兼容读取用）
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
        var data = Data()
        data.append(Self.binaryMagic)
        data.append(contentsOf: [1])                       // 二进制格式版本
        data.append(contentsOf: digest.utf8)               // 64 字符 sha256 hex
        var length = UInt64(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
        let name = "vitaliber-backup-\(Int(Date().timeIntervalSince1970)).vlbu"
        return BackupPackage(fileName: name, data: data,
                             sha256: digest,
                             exportedAt: envelope.exportedAt)
    }

    /// ADR-019 冲突预览：解码 + 校验 + 冲突清单（UI 逐项呈现裁决）。
    public func analyzeConflicts(from data: Data) async throws -> [ExportService.ConflictItem] {
        let envelope = try await verifiedEnvelope(from: data)
        return try await exporter.conflictReport(envelope)
    }

    /// 恢复：解外层（二进制 v1 / 遗留 JSON 兼容）→ **重算 payload 哈希并比对** →
    /// 解 envelope → 导入。校验失败即抛错，**不做任何部分导入**——半个备份
    /// 比没有备份更危险。返回导入记录计数（FR13.5 恢复后数据校验报告的数据源）。
    /// resolutions = ADR-019 逐项裁决（由 analyzeConflicts 驱动的预览 UI 提供）。
    @discardableResult
    public func restore(from data: Data,
                        resolutions: [UUID: ExportService.ConflictResolution] = [:]) async throws -> Int {
        let envelope = try await verifiedEnvelope(from: data)
        do {
            try await exporter.importJSON(envelope, resolutions: resolutions)
        } catch ExportService.ExportError.conflict {
            throw BackupError.conflictDetected
        }
        return envelope.totalRecords
    }

    /// 解码 + 校验（双格式兼容），返回已校验的 envelope
    private func verifiedEnvelope(from data: Data) async throws -> ExportService.Envelope {
        let (payload, claimedSHA): (Data, String)
        if data.starts(with: Self.binaryMagic) {
            guard data.count > Self.binaryMagic.count + 1 + 64 + 8 else {
                throw BackupError.unsupportedFormat
            }
            let versionStart = Self.binaryMagic.count
            guard data[versionStart] == 1 else { throw BackupError.unsupportedFormat }
            let shaStart = versionStart + 1
            let shaEnd = shaStart + 64
            let lenStart = shaEnd
            let lenEnd = lenStart + 8
            let length = data[lenStart..<lenEnd].withUnsafeBytes {
                $0.loadUnaligned(as: UInt64.self)
            }.bigEndian
            // 审查修复：length 来自用户挑选的文件——UInt64→Int 转换在 ≥2^63 时
            // 直接 trap（"Not enough bits"，do/catch 捕获不到），且 lenEnd + length
            // 可加性溢出同样 trap。先限界再减法比较，损坏文件一律走 unsupportedFormat。
            guard length <= UInt64(Int.max),
                  data.count >= lenEnd,
                  data.count - lenEnd == Int(length) else {
                throw BackupError.unsupportedFormat
            }
            claimedSHA = String(data: data[shaStart..<shaEnd], encoding: .ascii) ?? ""
            payload = data[lenEnd...]
        } else {
            // 遗留 JSON 信封（旧版本导出文件，继续可读）
            let outer: BackupEnvelope
            do {
                outer = try JSONDecoder().decode(BackupEnvelope.self, from: data)
            } catch {
                throw BackupError.unsupportedFormat
            }
            guard outer.formatVersion == 1 else { throw BackupError.unsupportedFormat }
            claimedSHA = outer.sha256
            payload = outer.payload
        }
        guard Self.sha256(payload) == claimedSHA else {
            throw BackupError.checksumMismatch
        }
        return try await exporter.decode(payload)
    }

    static func sha256(_ data: Data) -> String {
        // 收敛到 ContentHashing 单实现（CryptoKitContentHasher）——
        // 全仓哈希不再各自内联 CryptoKit 表达式
        CryptoKitContentHasher().sha256Hex(data)
    }
}
#endif
