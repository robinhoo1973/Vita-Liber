import Foundation

/// 媒体载具清单（discussions/2026-10-16-backup-sync-share-design.md §8.5）：
/// `.vlbm` 载具 = manifest.json + media/{sha256 前 2}/{sha256}.bin 的目录容器；
/// 条目哈希 = **明文原件哈希语义**（document_file.sha256/去重/restoreOCRPages 守卫依赖，
/// 加密不得改清单哈希）。与 Infrastructure `Envelope.media` 条目（同三字段形状）等价——
/// 清单是打包契约，信封是随包 DTO。
public struct MediaManifestEntry: Sendable, Codable, Equatable {
    public var sha256: String
    public var size: Int64
    public var mime: String
    public init(sha256: String, size: Int64, mime: String) {
        self.sha256 = sha256
        self.size = size
        self.mime = mime
    }
}

public struct MediaManifest: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1
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
    case sourceMissing(String)       // 原件库无此 sha——stage 拒绝（绝不打包不存在字节）
    case carrierCorrupt              // 载具打不开/清单解析失败/manifest 缺失
    case entryTraversal(String)      // 条目路径非法（绝对路径/`..`）——zip-slip 防御
}
