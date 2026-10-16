#if os(iOS) || os(macOS)
// linux-blind: CryptoKit 哈希（Apple 专属模块，Linux 不可用） —— Linux 型检编译空单元，改动须经 macOS CI 验证
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
    /// 设备密钥环（可选注入）：加密备份（iCloud 落点默认加密，comercial/tech V3.170）
    /// 与加密信封恢复依赖；nil = 明文模式（本地落点过渡/旧测试路径）
    private let keyRing: (any DeviceKeyRing)?

    public init(writer: any DatabaseWriter, keyRing: (any DeviceKeyRing)? = nil) {
        self.exporter = ExportService(writer: writer)
        self.keyRing = keyRing
    }

    /// 备份包（含文件名建议与校验和——完整性由 sha256 承担）
    public struct BackupPackage: Sendable, Equatable {
        public var fileName: String
        public var data: Data
        public var sha256: String
        public var exportedAt: TimeInterval
        /// 首次启用加密时新生成的恢复码（一次性展示；非 nil 即 UI 必须展示——
        /// 码原文零存储，展示即最后机会；后续备份此字段恒 nil）
        public var recoveryCode: String?
        public init(fileName: String, data: Data, sha256: String, exportedAt: TimeInterval,
                    recoveryCode: String? = nil) {
            self.fileName = fileName; self.data = data; self.sha256 = sha256; self.exportedAt = exportedAt
            self.recoveryCode = recoveryCode
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
        case encryptionUnavailable // 请求加密/解密但密钥环未注入
    }

    public func createBackup(encrypted: Bool = false) async throws -> BackupPackage {
        let envelope = try await exporter.exportJSON()
        let payload = try await exporter.encode(envelope)
        let data: Data
        let digest: String
        if encrypted {
            // iCloud 落点默认加密（tech V3.170）：主密钥经每设备子密钥包裹进帧头（信封自足）；
            // 主密钥缺失 → 生成并持久化（首启注册语义，realm 锚 = owner/本人档案 id，syncRealmId 前身）
            guard let keyRing else { throw BackupError.encryptionUnavailable }
            let realmId = envelope.owner?.id ?? envelope.selfProfile?.id ?? UUID()
            let masterData: Data
            let recoveryCode: String?
            let recoveryWrapped: Data?
            if let existing = try await keyRing.masterKey(realmId: realmId) {
                masterData = existing
                recoveryWrapped = try await keyRing.recoveryWrapped(realmId: realmId)   // 既有包裹段随帧走（信封自足）
                recoveryCode = nil
            } else {
                masterData = try keyRing.generateMasterKey()
                try await keyRing.storeMasterKey(masterData, realmId: realmId)
                // 恢复码零知识链路：码 → HKDF KEK → 包裹主密钥；码原文不入任何存储
                let code = RecoveryCode.generate()
                let kek = BackupCrypto.recoveryKEK(code: code, realmId: realmId)
                let wrapped = try BackupCrypto.wrapKey(SymmetricKey(data: masterData), using: kek)
                try await keyRing.storeRecoveryWrapped(wrapped, realmId: realmId)
                recoveryWrapped = wrapped
                recoveryCode = code
            }
            let deviceKey = try await keyRing.deviceSubKey()
            data = try BackupCrypto.sealFrame(payload: payload,
                                              masterKey: SymmetricKey(data: masterData),
                                              wrappingKey: SymmetricKey(data: deviceKey),
                                              keyRef: UUID(),
                                              realmId: realmId,
                                              recoveryWrapped: recoveryWrapped)
            digest = BackupCrypto.sha256Hex(payload)   // 明文 payload 哈希——清单哈希语义延续（加密不改清单哈希纪律）
            return BackupPackage(fileName: "vitaliber-backup-\(Int(Date().timeIntervalSince1970)).vlbu",
                                 data: data, sha256: digest, exportedAt: envelope.exportedAt,
                                 recoveryCode: recoveryCode)
        } else {
            digest = Self.sha256(payload)
            var frame = Data()
            frame.append(Self.binaryMagic)
            frame.append(contentsOf: [1])               // 二进制格式版本
            frame.append(contentsOf: digest.utf8)       // 64 字符 sha256 hex
            var length = UInt64(payload.count).bigEndian
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
            frame.append(payload)
            data = frame
        }
        let name = "vitaliber-backup-\(Int(Date().timeIntervalSince1970)).vlbu"
        return BackupPackage(fileName: name, data: data,
                             sha256: digest,
                             exportedAt: envelope.exportedAt)
    }

    /// ADR-019 冲突预览：解码 + 校验 + 冲突清单（UI 逐项呈现裁决）。
    /// 返回已校验的 envelope 随预览一起给调用方——恢复时直接复用，
    /// 避免同一包在预览→恢复两步间被完整哈希+解码两遍（大档案数百 MB 时
    /// 2× 全文件 SHA-256 + 2× 全量解码 + 28 次冲突 IN 扫描）。
    public struct ConflictAnalysis: Sendable {
        public var conflicts: [ExportService.ConflictItem]
        public var envelope: ExportService.Envelope
    }
    public func analyzeConflicts(from data: Data, recoveryCode: String? = nil) async throws -> ConflictAnalysis {
        let envelope = try await verifiedEnvelope(from: data, recoveryCode: recoveryCode)
        return ConflictAnalysis(conflicts: try await exporter.conflictReport(envelope),
                                envelope: envelope)
    }

    /// 恢复（已校验 envelope 直用）：导入失败即抛错，**不做任何部分导入**——
    /// 半个备份比没有备份更危险。返回导入记录计数（FR13.5 恢复后数据校验
    /// 报告的数据源）。resolutions = ADR-019 逐项裁决（预览 UI 提供）。
    @discardableResult
    public func restore(envelope: ExportService.Envelope,
                        resolutions: [UUID: ExportService.ConflictResolution] = [:]) async throws -> Int {
        do {
            try await exporter.importJSON(envelope, resolutions: resolutions)
        } catch ExportService.ExportError.conflict {
            throw BackupError.conflictDetected
        }
        return envelope.totalRecords
    }

    /// 恢复（原始 Data 入口）：解外层（二进制 v1 / 遗留 JSON 兼容）→
    /// **重算 payload 哈希并比对** → 解 envelope → 委托上一重载。供无预览的
    /// 直接恢复路径使用（预览流程请用 analyzeConflicts 拿 envelope 复用，
    /// 避免整包被哈希+解码两遍）。
    @discardableResult
    public func restore(from data: Data,
                        resolutions: [UUID: ExportService.ConflictResolution] = [:],
                        recoveryCode: String? = nil) async throws -> Int {
        let envelope = try await verifiedEnvelope(from: data, recoveryCode: recoveryCode)
        return try await restore(envelope: envelope, resolutions: resolutions)
    }

    /// 解码 + 校验（三格式兼容：v1 明文帧 / v2 加密段帧 / 遗留 JSON），返回已校验的 envelope
    private func verifiedEnvelope(from data: Data, recoveryCode: String? = nil) async throws -> ExportService.Envelope {
        let (payload, claimedSHA): (Data, String)
        switch EnvelopeFrame.binaryFormatVersion(data) {
        case 2:
            // v2 加密段帧（tech V3.170）：AEAD 认证 + aadHash 双保险；
            // 设备子密钥不可达（换机/钥匙串重置）→ 恢复码逃生舱（码错=checksumMismatch 零部分导入）
            guard let keyRing else { throw BackupError.encryptionUnavailable }
            do {
                let deviceKey = try await keyRing.deviceSubKey()
                let opened = try BackupCrypto.openFrame(data, unwrapWith: SymmetricKey(data: deviceKey))
                payload = opened.payload
                claimedSHA = opened.aadHash
            } catch BackupCrypto.CryptoError.tamperOrKeyMismatch, BackupCrypto.CryptoError.malformed {
                guard let code = recoveryCode else { throw BackupError.checksumMismatch }
                do {
                    let opened = try BackupCrypto.openWithRecoveryCode(data, code: code)
                    payload = opened.payload
                    claimedSHA = opened.aadHash
                } catch {
                    throw BackupError.checksumMismatch
                }
            } catch {
                throw BackupError.unsupportedFormat
            }
        case 1:
            guard let frame = EnvelopeFrame.parseBinary(data) else {
                throw BackupError.unsupportedFormat
            }
            claimedSHA = frame.claimedSHA
            payload = frame.payload
        default:
            // 二进制魔数但版本未知/结构不足 → unsupportedFormat，绝不落入 JSON 分支误读
            if EnvelopeFrame.isBinary(data) {
                throw BackupError.unsupportedFormat
            }
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
