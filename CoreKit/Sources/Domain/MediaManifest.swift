import Foundation

/// 媒体载具清单（discussions/2026-10-16-local-storage-layout-council.md §7.1；
/// 前身见 backup-sync-share-design.md §8.5）：
/// `.vlbm` 载具 = `manifest.json + media/{sha256 前 2}/{sha256}.bin` 的目录容器（zip 内路径）；
/// 条目哈希 = **明文原件哈希语义**——跨设备身份/去重/restoreOCRPages 守卫依赖它，
/// 加密不得改清单哈希（哈希只承担防损坏语义，防篡改由 AES-GCM 承担）。
/// 与 Infrastructure `Envelope.media` 共用同一类型——清单是打包契约，信封是随包 DTO。
public enum MediaKind: String, Sendable, Codable, Equatable, CaseIterable {
    case original   // F5 文档原件（非敏感走 originals/ CAS，敏感走 sensitive/{memberId}/）
    case processed  // F5 处理版（G10 登记：本批只保原件，处理版可回落派生）
    case photo      // F8 观察照片（sensitive/{memberId}/{assetId}.jpg）
    case blur       // F8 模糊版（sensitive/{memberId}/{assetId}.blur.jpg）
}

/// 载具条目——blob 的完整放置信息（v2；v1 仅 {sha256,size,mime}，本批零存量包可收紧）。
/// `relativePath` 相对媒体根（`Documents/MedicalNotes`），落盘前经 MediaDestinationRules
/// 规范形校验（文档条目可重算比对，照片条目按形状校验）——绝不信任清单文本直接拼路径。
public struct MediaManifestEntry: Sendable, Codable, Equatable {
    public var sha256: String            // 明文原件全文件 SHA-256，小写 hex64 无前缀
    public var size: Int64
    public var mime: String
    public var relativePath: String      // originals/{sha2}/{sha}.bin | sensitive/{memberId}/{…}
    public var isSensitive: Bool         // 敏感件直写 sensitive/ 目录（FileProtectionType.complete）
    public var memberId: UUID?           // 敏感件必填（删除/清空按成员边界）
    public var kind: MediaKind
    public init(sha256: String, size: Int64, mime: String, relativePath: String,
                isSensitive: Bool, memberId: UUID? = nil, kind: MediaKind) {
        self.sha256 = sha256
        self.size = size
        self.mime = mime
        self.relativePath = relativePath
        self.isSensitive = isSensitive
        self.memberId = memberId
        self.kind = kind
    }
}

public struct MediaManifest: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 2
    public var schemaVersion: Int
    public var entries: [MediaManifestEntry]
    public init(entries: [MediaManifestEntry], schemaVersion: Int = MediaManifest.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }
}

/// 载具导入结果——恢复报告的数据源（成功/已在库/缺失三分项，FR13.5 恢复后校验报告）。
public struct MediaImportReport: Sendable, Equatable {
    public var imported: Int
    public var alreadyPresent: Int
    public var missing: [String]     // 清单声称但载具缺字节/哈希不符的 sha256（不入恢复库，绝不伪造恢复）
    public init(imported: Int = 0, alreadyPresent: Int = 0, missing: [String] = []) {
        self.imported = imported
        self.alreadyPresent = alreadyPresent
        self.missing = missing
    }
}

/// 载具错误（端口层语义，Linux 可编译）。
public enum MediaPackagingError: Error, Sendable, Equatable {
    case sourceMissing(String)          // 原件库无此 sha——stage 拒绝（绝不打包不存在字节）
    case shaMismatch(String)            // 源字节哈希与条目 sha 不符——stage/import 拒绝
    case carrierCorrupt                 // 载具打不开/清单解析失败/manifest 缺失
    case emptyManifest                  // commit 空清单拒绝（stagedEntries 跨会话丢条目缺陷的防线）
    case stagingIncomplete(String)      // commit 时暂存字节缺失——绝不产出「清单声称而载具无字节」的包
    case entryTraversal(String)         // 条目相对路径非法（绝对路径/`..`/非规范形）——zip-slip 防御
    case unsupportedManifestVersion(Int)
}
