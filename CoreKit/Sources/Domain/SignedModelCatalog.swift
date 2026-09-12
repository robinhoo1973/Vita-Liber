import Foundation

/// ADR-030 / FR17.17：签名覆盖 payload 原始字节，解码后的字段不参与重序列化验签。
public struct SignedModelEnvelope: Codable, Sendable {
    public struct Signature: Codable, Sendable {
        public let keyId: String
        public let signature: Data
    }
    public let payload: Data
    public let signatures: [Signature]
}

public struct ModelTrustRoot: Codable, Sendable {
    public struct Key: Codable, Sendable {
        public let id: String
        public let publicKey: Data
    }
    public let schemaVersion: Int
    public let role: String
    public let app: String
    public let assetKind: String
    public let version: Int
    public let expiresAt: String
    public let keys: [Key]
    public let rootKeyIDs: [String]
    public let rootThreshold: Int
    public let catalogKeyIDs: [String]
    public let catalogThreshold: Int
    public let assetBaseURL: String
    public let allowedHosts: [String]
}

public struct SignedModelCatalog: Codable, Sendable {
    public let schemaVersion: Int
    public let role: String
    public let app: String
    public let assetKind: String
    public let rootVersion: Int
    public let catalogVersion: Int
    public let issuedAt: String
    public let expiresAt: String
    public let index: ASRModelReleaseIndex
    public let revokedHashes: [String]
}

/// 资源协议上限，不是医疗数值；文件预算与运行时内存预算分别管理。
public enum ModelResourcePolicy {
    public static let metadataBytes = 1_048_576
    public static let packageBytes: Int64 = 2_147_483_647
    public static let expandedBytes: Int64 = 4_294_967_296
    public static let zipEntries = 512
    public static let runtime = "sherpa-onnx-1.13.4"
    public static let allowedHosts: Set<String> = ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]

    public static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    public static func isSlug(_ value: String) -> Bool {
        guard let first = value.utf8.first, value.utf8.count <= 128 else { return false }
        func alphaNumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        return alphaNumeric(first) && value.utf8.allSatisfy { alphaNumeric($0) || $0 == 45 || $0 == 46 || $0 == 95 }
    }
    public static func allowedURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && url.host.map { allowedHosts.contains($0.lowercased()) } == true
    }
}
