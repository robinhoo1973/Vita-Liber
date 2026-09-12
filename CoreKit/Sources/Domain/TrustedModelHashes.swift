import Foundation

/// FR17.15（业主 2026-09-12 决定）：**构建期生成的下载文件哈希信任锚**。
///
/// 安全模型（为什么必须有这张表）：
/// - 运行时索引 `index.json` 来自网络（CDN/对象存储/Release），**可被替换**；
///   若只校验「远端自报的 sha256 == 下载内容的 sha256」，攻击者同时改索引与包即可绕过，
///   等于没有信任根；
/// - 本表由**发布者本地工具** `refactor/scripts/generate-trusted-hashes.sh`（不入库）
///   从仓库索引固化并提交，随包嵌入（`Resources/TrustedModelHashes.json`）；编译期
///   preBuildScripts 对两者做 fail-closed 漂移校验——它随 App 二进制一起被
///   App Store 签名保护，是可信的「已发布版本清单」；
/// - App 安装下载包时以本表为**唯一信任锚**：未登记版本 / 哈希不一致 → 一律拒绝安装
///   （fail closed）。发布新模型版本必须更新索引并重新发版（或在受控流程中扩展本表）。
///
/// 未发布条目（空 sha256/零字节）不入表；空表等价「禁止一切运行时下载」。
public struct TrustedModelHashes: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var version: String
        public var bytes: Int64
        public var sha256: String

        public init(id: String, version: String, bytes: Int64, sha256: String) {
            self.id = id; self.version = version; self.bytes = bytes; self.sha256 = sha256
        }
    }

    public var schemaVersion: Int
    public var generatedAt: String?
    public var sourceIndexSha256: String?
    public var entries: [Entry]

    public init(schemaVersion: Int = 1, generatedAt: String? = nil,
                sourceIndexSha256: String? = nil, entries: [Entry] = []) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.sourceIndexSha256 = sourceIndexSha256
        self.entries = entries
    }

    /// 客户端支持的结构版本；未知版本视为空表（fail closed），不猜测语义。
    public static let supportedSchemaVersion = 1

    public static let empty = TrustedModelHashes()

    public var isEmpty: Bool { entries.isEmpty }

    public func entry(id: String, version: String) -> Entry? {
        entries.first { $0.id == id && $0.version == version }
    }

    /// 该发布条目是否可安装：必须命中信任锚且哈希/字节一致。
    public func isTrusted(_ release: ASRModelRelease) -> Bool {
        guard schemaVersion == Self.supportedSchemaVersion,
              let trusted = entry(id: release.id, version: release.version),
              trusted.sha256.caseInsensitiveCompare(release.sha256) == .orderedSame else {
            return false
        }
        if let declared = release.bytes, declared > 0, trusted.bytes > 0, declared != trusted.bytes {
            return false
        }
        return true
    }
}
