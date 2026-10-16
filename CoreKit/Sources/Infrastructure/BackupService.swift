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
    /// 媒体根（local-storage-layout-council §7.1 单点定义）：原件/敏感目录的落盘根。
    /// nil = 媒体随包禁用（旧测试路径/预览）——信封仍带 originalSha256 元数据。
    private let mediaBase: URL?
    /// 载具暂存目录（Caches——不进 Documents 明文）。
    private let stagingRoot: URL?

    public init(writer: any DatabaseWriter, keyRing: (any DeviceKeyRing)? = nil,
                mediaBase: URL? = nil, stagingRoot: URL? = nil) {
        self.exporter = ExportService(writer: writer)
        self.keyRing = keyRing
        self.mediaBase = mediaBase
        self.stagingRoot = stagingRoot
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
        /// 媒体载具（.vlbm）：与信封成对导出/恢复；nil = 本库无媒体或明文模式
        public var mediaCarrier: URL?
        public var mediaManifest: MediaManifest?
        public init(fileName: String, data: Data, sha256: String, exportedAt: TimeInterval,
                    recoveryCode: String? = nil, mediaCarrier: URL? = nil,
                    mediaManifest: MediaManifest? = nil) {
            self.fileName = fileName; self.data = data; self.sha256 = sha256; self.exportedAt = exportedAt
            self.recoveryCode = recoveryCode
            self.mediaCarrier = mediaCarrier
            self.mediaManifest = mediaManifest
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

    /// 装配点媒体枚举（local-storage-layout-council §8 切片 11）：每条 (entry, 源文件)，
    /// 附带 NULL 行的现场哈希回写集（doc id → sha）——供 createBackup 回写信封。
    /// 列 original_sha256 在 → 直接用（单点转换纪律：不重复哈希）；
    /// NULL 行 → 现场哈希一次（legacy 旧库过渡；懒回填属切片 13 对账职责）。
    /// 文件不可达 → 跳过该文档（恢复报告 missing 如实呈现，绝不伪造）。
    private func buildMediaEntries(envelope: ExportService.Envelope) throws -> (items: [(entry: MediaManifestEntry, sourceURL: URL)], updates: [UUID: String]) {
        guard let mediaBase else { return ([], [:]) }
        let fm = FileManager.default
        var result: [(entry: MediaManifestEntry, sourceURL: URL)] = []
        var updates: [UUID: String] = [:]
        for doc in envelope.documents ?? [] {
            let meta = doc.metaJson.flatMap { json -> [String: Any]? in
                try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] // try?-ok: meta 损坏=无路径候选，该文档跳过（missing 报告如实呈现）
            } ?? [:]
            let candidates = MediaPathResolver.candidates(storedPath: meta["original_path"] as? String,
                                                          originalSha256: doc.originalSha256)
            var source: URL?
            for candidate in candidates {
                let url = candidate.hasPrefix("/") ? URL(fileURLWithPath: candidate) : mediaBase.appendingPathComponent(candidate)
                if fm.fileExists(atPath: url.path) { source = url; break }
            }
            guard let source, let patientId = doc.patientId else { continue }
            let size = ((try? fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value) ?? 0 // try?-ok: 属性读取失败按 0 计，不阻断备份
            let sha: String
            if let original = doc.originalSha256, MediaDestinationRules.isLowercaseHex64(original) {
                sha = original
            } else {
                sha = CryptoKitContentHasher().sha256Hex(try Data(contentsOf: source))
                updates[doc.id] = sha
            }
            let relative = doc.isSensitive
                ? MediaDestinationRules.sensitiveOriginalRelativePath(memberId: patientId, sha256: sha)
                : MediaDestinationRules.originalRelativePath(sha256: sha)
            let entry = MediaManifestEntry(sha256: sha, size: size,
                                           mime: doc.mimeType ?? "application/octet-stream",
                                           relativePath: relative, isSensitive: doc.isSensitive,
                                           memberId: doc.isSensitive ? patientId : nil, kind: .original)
            result.append((entry, source))
        }
        // F8 照片随包（local-storage-layout-council 切片 14，业主裁决入批）：
        // 只带 photo 原件（blur 派生可再生，恢复后按需重建）；成员身份由
        // observation.media_asset_ids 反查；相对路径剥「MedicalNotes/」前缀对齐媒体根。
        let memberByAsset = Dictionary(uniqueKeysWithValues:
            (envelope.observations).flatMap { obs in
                obs.mediaAssetIds.compactMap { id in obs.patientId.map { ($0, id) } }
            }.map { ($0.1, $0.0) })
        for asset in envelope.assets ?? [] where asset.kind == "photo" {
            guard let memberId = memberByAsset[asset.id.uuidString] else { continue }
            let stripped = asset.relativePath.hasPrefix("MedicalNotes/")
                ? String(asset.relativePath.dropFirst("MedicalNotes/".count)) : asset.relativePath
            let source = mediaBase.appendingPathComponent(stripped)
            guard fm.fileExists(atPath: source.path) else { continue }
            let data = try Data(contentsOf: source)
            let sha = CryptoKitContentHasher().sha256Hex(data)
            let entry = MediaManifestEntry(sha256: sha, size: Int64(data.count),
                                           mime: "image/jpeg", relativePath: stripped,
                                           isSensitive: true, memberId: memberId, kind: .photo)
            result.append((entry, source))
        }
        return (result, updates)
    }

    /// syncIdentity 非 nil = 同步信封（批次 2）：envelope 写 syncRealmId/deviceId/seq，
    /// 加密 realm 锚改用显式 syncRealmId（跨设备同一同步域解封密钥一致）；
    /// 其余管线（媒体载具/加密段/恢复码链）与普通备份完全同构，零重复实现。
    public func createBackup(encrypted: Bool = false,
                             syncIdentity: SyncFileNaming.Identity? = nil) async throws -> BackupPackage {
        var envelope = try await exporter.exportJSON()
        if let syncIdentity {
            envelope.syncRealmId = syncIdentity.realmId
            envelope.deviceId = syncIdentity.deviceId
            envelope.seq = syncIdentity.seq
        }
        // 媒体随包（local-storage-layout-council §8 切片 11）：仅加密路径携带载具
        // （明文模式 = 旧过渡行为，media 留 nil 不承诺字节）；entries 在装配点
        // 单点计算（列在则直接用，NULL 行现场哈希一次——绝不把「处理后哈希」当原件身份）；
        // 现场哈希**回写信封 originalSha256**（恢复侧 normalizeMediaPaths 依列归一，
        // legacy 行不写回则恢复后仍是悬空绝对路径）。
        var mediaItems: [(entry: MediaManifestEntry, sourceURL: URL)] = []
        if encrypted, mediaBase != nil, stagingRoot != nil {
            let built = try buildMediaEntries(envelope: envelope)
            mediaItems = built.items
            if var docs = envelope.documents, !built.updates.isEmpty {
                for index in docs.indices {
                    if let sha = built.updates[docs[index].id] { docs[index].originalSha256 = sha }
                }
                envelope.documents = docs
            }
        }
        envelope.media = mediaItems.isEmpty ? nil : mediaItems.map(\.entry)
        let payload = try await exporter.encode(envelope)
        let data: Data
        let digest: String
        if encrypted {
            // iCloud 落点默认加密（tech V3.170）：主密钥经每设备子密钥包裹进帧头（信封自足）；
            // 主密钥缺失 → 生成并持久化（首启注册语义，realm 锚 = owner/本人档案 id，syncRealmId 前身）
            guard let keyRing else { throw BackupError.encryptionUnavailable }
            // 同步信封的加密 realm 锚 = 显式 syncRealmId（跨设备同域解封一致）；
            // 普通备份锚 = owner/本人档案 id（syncRealmId 前身）
            let realmId = envelope.syncRealmId ?? envelope.owner?.id ?? envelope.selfProfile?.id ?? UUID()
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
            // 媒体载具：blob 先加密后入包（媒体密钥 HKDF 派生自主密钥），
            // 清单明文哈希；暂存目录每次重建（stale staged 不残留、stage 按 sha 幂等）
            let mediaCarrier: URL?
            let mediaManifest: MediaManifest?
            if !mediaItems.isEmpty, let stagingRoot {
                try? FileManager.default.removeItem(at: stagingRoot)   // try?-ok: 首备无暂存目录，删除失败=按「重建」处理
                let sealing = try CryptoKitMediaBlobSealing(masterKey: masterData)
                let packager = MediaCarrierPackager(mediaBase: mediaBase!, stagingRoot: stagingRoot, sealing: sealing)
                for item in mediaItems {
                    _ = try await packager.stage(sourceURL: item.sourceURL, entry: item.entry)
                }
                let carrierURL = stagingRoot.appendingPathComponent(
                    "vitaliber-media-\(Int(Date().timeIntervalSince1970)).vlbm")
                mediaManifest = try await packager.commit(to: carrierURL, entries: mediaItems.map(\.entry))
                mediaCarrier = carrierURL
            } else {
                mediaCarrier = nil
                mediaManifest = nil
            }
            return BackupPackage(fileName: "vitaliber-backup-\(Int(Date().timeIntervalSince1970)).vlbu",
                                 data: data, sha256: digest, exportedAt: envelope.exportedAt,
                                 recoveryCode: recoveryCode,
                                 mediaCarrier: mediaCarrier, mediaManifest: mediaManifest)
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
        /// v2 加密帧解封后的主密钥（Data 形态）——媒体载具解密依赖
        /// （媒体密钥 = HKDF-SHA256(masterKey,"vlbm-media-v1")，切片 12）；
        /// 明文/遗留包 nil（无载具可解）。
        public var masterKey: Data?
        public init(conflicts: [ExportService.ConflictItem], envelope: ExportService.Envelope,
                    masterKey: Data? = nil) {
            self.conflicts = conflicts
            self.envelope = envelope
            self.masterKey = masterKey
        }
    }
    public func analyzeConflicts(from data: Data, recoveryCode: String? = nil) async throws -> ConflictAnalysis {
        let verified = try await verifiedEnvelope(from: data, recoveryCode: recoveryCode)
        return ConflictAnalysis(conflicts: try await exporter.conflictReport(verified.envelope),
                                envelope: verified.envelope,
                                masterKey: verified.masterKey)
    }

    /// 媒体载具导入（local-storage-layout-council §8 切片 12）：**必须先于 DB 事务**
    /// （文件先行、行后行——最坏为不可见孤儿，GC 宽限清；反向窗口对读路径可见）。
    /// 幂等可重入：重复导入全 alreadyPresent。返回三分项报告（imported/alreadyPresent/missing）。
    public func importMediaCarrier(from url: URL, masterKey: Data) async throws -> MediaImportReport {
        guard let mediaBase, let stagingRoot else { throw BackupError.encryptionUnavailable }
        let sealing = try CryptoKitMediaBlobSealing(masterKey: masterKey)
        let packager = MediaCarrierPackager(mediaBase: mediaBase, stagingRoot: stagingRoot, sealing: sealing)
        return try await packager.importMedia(url)
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
        let verified = try await verifiedEnvelope(from: data, recoveryCode: recoveryCode)
        return try await restore(envelope: verified.envelope, resolutions: resolutions)
    }

    /// 解码 + 校验（三格式兼容：v1 明文帧 / v2 加密段帧 / 遗留 JSON），返回已校验的 envelope
    /// 与主密钥（v2 帧解封可得；v1/JSON 为 nil——无载具可解）
    private func verifiedEnvelope(from data: Data, recoveryCode: String? = nil) async throws -> (envelope: ExportService.Envelope, masterKey: Data?) {
        let (payload, claimedSHA): (Data, String)
        var masterKey: Data?
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
                masterKey = opened.masterKey
            } catch BackupCrypto.CryptoError.tamperOrKeyMismatch, BackupCrypto.CryptoError.malformed {
                guard let code = recoveryCode else { throw BackupError.checksumMismatch }
                do {
                    let opened = try BackupCrypto.openWithRecoveryCode(data, code: code)
                    payload = opened.payload
                    claimedSHA = opened.aadHash
                    masterKey = opened.masterKey
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
        return (try await exporter.decode(payload), masterKey)
    }

    static func sha256(_ data: Data) -> String {
        // 收敛到 ContentHashing 单实现（CryptoKitContentHasher）——
        // 全仓哈希不再各自内联 CryptoKit 表达式
        CryptoKitContentHasher().sha256Hex(data)
    }
}
#endif
