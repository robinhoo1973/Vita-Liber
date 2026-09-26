import Foundation
import Protocols

/// medical-data Release 线协议常量与命名文法；逐项对齐
/// `scripts/medical-data/go/medrelease`（trust.go / names.go），任何一侧改动须同步另一侧。
public enum MedicalCatalogReleaseProtocol {
    public static let repository = "robinhoo1973/Vita-Liber"
    public static let releaseTag = "medical-data"
    public static let assetKind = "medical-data"
    public static let app = "vitaliber"
    public static let sqliteSchemaVersion = 5
    public static let sqliteEntryName = "medical-catalog.sqlite"
    public static let releaseBaseURL = "https://github.com/" + repository + "/releases/download/" + releaseTag
    public static let allowedHosts: Set<String> = [
        "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com",
    ]
    static let signatureThreshold = 2
    static let maxPayloadBytes = 1 << 20
    static let maxEnvelopeBytes = 2 << 20
    static let maxKeys = 16
    static let maxSignatures = 16
    static let pointerValidity: TimeInterval = 31 * 24 * 60 * 60
    static let issuedAtSkew: TimeInterval = 5 * 60

    private static let packagePrefix = "medical-data-package-sqlite-"
    private static let packageInfix = "-cipher-"
    private static let packageSuffix = ".bin"

    public static func pointerAssetName(installable: Bool, catalogVersion: Int64) -> String {
        "medical-data-catalog-" + (installable ? "installable" : "progress") + "-" + String(catalogVersion) + ".json"
    }

    public static func packageAssetName(sqliteSHA256: String, packageSHA256: String) -> String {
        packagePrefix + sqliteSHA256 + packageInfix + packageSHA256 + packageSuffix
    }

    public static func isPackageAssetName(_ name: String) -> Bool {
        guard name.hasPrefix(packagePrefix), name.hasSuffix(packageSuffix) else { return false }
        let body = name.dropFirst(packagePrefix.count).dropLast(packageSuffix.count)
        let parts = body.components(separatedBy: packageInfix)
        return parts.count == 2 && parts.allSatisfy(isLowercaseSHA256)
    }

    /// 包下载地址只由签名的 packageAssetName 拼出，不接受任何网络给出的 URL。
    public static func packageURL(assetName: String) -> URL? {
        guard isPackageAssetName(assetName) else { return nil }
        return URL(string: releaseBaseURL + "/" + assetName)
    }

    /// 下载与每一跳 redirect 的地址门：HTTPS、固定 Release 主机、无凭据、默认端口。
    public static func allowsTransferURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    public static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// 仅接受 Go `TimeLayout`（`2006-01-02T15:04:05Z`）的逐字节回环形式。
    static func timestamp(_ value: String) -> Date? {
        guard value.utf8.count == 20 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    static func strictBase64(_ value: String) -> Data? {
        guard let data = Data(base64Encoded: value), data.base64EncodedString() == value else { return nil }
        return data
    }
}

public enum MedicalCatalogTrustError: Error, Equatable {
    case malformedEnvelope
    case invalidScope
    case invalidKeySet
    case signatureThreshold
    case expired
    case rootMismatch
    case invalidField
    case assetNameMismatch
    case expectationMismatch
}

/// 从 signed pointer 解出的期望值（`schemaVersion` = 签名字段 `sqliteSchemaVersion`）。
/// 只由 `MedicalCatalogSignedPointerDecoder` 构造；pinned verifier 按原 payload 重算并逐字段比对。
public struct MedicalCatalogSignedExpectation: Sendable, Equatable {
    public let catalogVersion: Int64
    public let dataVersion: String
    public let schemaVersion: Int
    public let packageAssetName: String
    public let packageSize: Int64
    public let packageSHA256: String
    public let sqliteSHA256: String
    public let installable: Bool
    public let issuedAt: Date
    public let expiresAt: Date
    public let repository: String
    public let releaseTag: String
    /// 已签 payload 原始字节的 SHA-256。
    public let signedPointerDigest: String

    init(_ pointer: MedicalCatalogSignedPointer, signedPointerDigest: String) {
        catalogVersion = pointer.catalogVersion
        dataVersion = pointer.dataVersion
        schemaVersion = pointer.sqliteSchemaVersion
        packageAssetName = pointer.packageAssetName
        packageSize = pointer.packageSize
        packageSHA256 = pointer.packageSHA256
        sqliteSHA256 = pointer.sqliteSHA256
        installable = pointer.installable
        issuedAt = pointer.issuedDate
        expiresAt = pointer.expiresDate
        repository = pointer.repository
        releaseTag = pointer.releaseTag
        self.signedPointerDigest = signedPointerDigest
    }
}

/// 通过 pinned root 验签后的安装候选。initializer 为模块内可见：App 与调用方
/// 无法手工拼出候选，只有 Release resolver 在 `verify(catalogJSON:expected:)` 通过后创建。
public struct VerifiedMedicalCatalogCandidate: Sendable, Equatable {
    public let catalogVersion: Int64
    public let dataVersion: String
    public let schemaVersion: Int
    public let packageAssetName: String
    public let packageSize: Int64
    public let packageSHA256: String
    public let sqliteSHA256: String
    public let installable: Bool
    public let issuedAt: Date
    public let expiresAt: Date
    public let repository: String
    public let releaseTag: String
    public let signedPointerDigest: String

    init(verified expectation: MedicalCatalogSignedExpectation) {
        catalogVersion = expectation.catalogVersion
        dataVersion = expectation.dataVersion
        schemaVersion = expectation.schemaVersion
        packageAssetName = expectation.packageAssetName
        packageSize = expectation.packageSize
        packageSHA256 = expectation.packageSHA256
        sqliteSHA256 = expectation.sqliteSHA256
        installable = expectation.installable
        issuedAt = expectation.issuedAt
        expiresAt = expectation.expiresAt
        repository = expectation.repository
        releaseTag = expectation.releaseTag
        signedPointerDigest = expectation.signedPointerDigest
    }
}

public protocol MedicalCatalogTrustVerifying: Sendable {
    func verify(catalogJSON: Data, expected: MedicalCatalogSignedExpectation) throws
}

/// 未验签的 pointer 解码：字段/时间窗/资产名绑定。签名与 pin 由 verifier 负责。
public enum MedicalCatalogSignedPointerDecoder {
    public static func expectation(catalogJSON: Data, servedAs assetName: String, now: Date,
                                   hasher: any ContentHashing) throws -> MedicalCatalogSignedExpectation {
        let envelope = try MedicalCatalogSignedEnvelope.decode(catalogJSON)
        let pointer = try MedicalCatalogSignedPointer.decode(envelope.payload)
        try pointer.checkWindow(now: now)
        guard assetName == MedicalCatalogReleaseProtocol.pointerAssetName(installable: pointer.installable,
                                                                         catalogVersion: pointer.catalogVersion) else {
            throw MedicalCatalogTrustError.assetNameMismatch
        }
        return MedicalCatalogSignedExpectation(pointer, signedPointerDigest: hasher.sha256Hex(envelope.payload))
    }
}

// MARK: - Wire documents

struct MedicalCatalogSignedEnvelope {
    struct Signature {
        let keyID: String
        let raw: Data
    }

    let payload: Data
    let signatures: [Signature]

    static func decode(_ json: Data) throws -> Self {
        let malformed = MedicalCatalogTrustError.malformedEnvelope
        guard json.count <= MedicalCatalogReleaseProtocol.maxEnvelopeBytes else { throw malformed }
        let object = try MedicalCatalogJSON.object(json, onFailure: malformed)
        guard Set(object.keys).isSubset(of: ["payload", "signatures"]),
              let encoded = object["payload"] as? String, !encoded.isEmpty,
              encoded.utf8.count <= MedicalCatalogReleaseProtocol.maxPayloadBytes * 4 / 3 + 4,
              let payload = MedicalCatalogReleaseProtocol.strictBase64(encoded),
              !payload.isEmpty, payload.count <= MedicalCatalogReleaseProtocol.maxPayloadBytes,
              let values = object["signatures"] as? [Any],
              (1...MedicalCatalogReleaseProtocol.maxSignatures).contains(values.count) else { throw malformed }
        var seen = Set<String>()
        var signatures: [Signature] = []
        for value in values {
            guard let entry = value as? [String: Any], Set(entry.keys).isSubset(of: ["keyId", "signature"]),
                  let keyID = entry["keyId"] as? String, seen.insert(keyID).inserted,
                  let encodedSignature = entry["signature"] as? String,
                  let raw = MedicalCatalogReleaseProtocol.strictBase64(encodedSignature), raw.count == 64 else {
                throw malformed
            }
            signatures.append(Signature(keyID: keyID, raw: raw))
        }
        return Self(payload: payload, signatures: signatures)
    }
}

struct MedicalCatalogSignedPointer: Decodable, Equatable {
    let schemaVersion: Int
    let role: String
    let app: String
    let assetKind: String
    let rootVersion: Int64
    let catalogVersion: Int64
    let issuedAt: String
    let expiresAt: String
    let sqliteSHA256: String
    let packageSHA256: String
    let packageSize: Int64
    let packageAssetName: String
    let fetchStateSHA256: String
    let installable: Bool
    let contentSHA256: String
    let manifestSHA256: String
    let dataVersion: String
    let sqliteSchemaVersion: Int
    let releaseTag: String
    let repository: String

    private(set) var issuedDate = Date.distantPast
    private(set) var expiresDate = Date.distantPast

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, role, app, assetKind, rootVersion, catalogVersion, issuedAt, expiresAt
        case sqliteSHA256 = "sqliteSha256"
        case packageSHA256 = "packageSha256"
        case packageSize, packageAssetName
        case fetchStateSHA256 = "fetchStateSha256"
        case installable
        case contentSHA256 = "contentSha256"
        case manifestSHA256 = "manifestSha256"
        case dataVersion, sqliteSchemaVersion, releaseTag, repository
    }

    /// Go `validatePointerFields` 的 Swift 镜像（解码失败同 Go 归 invalidField）。
    static func decode(_ payload: Data) throws -> Self {
        var pointer = try MedicalCatalogJSON.strict(Self.self, from: payload,
                                                   keys: Set(CodingKeys.allCases.map(\.rawValue)),
                                                   onFailure: .invalidField)
        guard pointer.schemaVersion == 1, pointer.role == "catalog", pointer.app == MedicalCatalogReleaseProtocol.app,
              pointer.assetKind == MedicalCatalogReleaseProtocol.assetKind else {
            throw MedicalCatalogTrustError.invalidScope
        }
        let digests = [pointer.sqliteSHA256, pointer.packageSHA256, pointer.fetchStateSHA256,
                       pointer.contentSHA256, pointer.manifestSHA256, pointer.dataVersion]
        guard pointer.rootVersion > 0, pointer.catalogVersion > 0,
              digests.allSatisfy(MedicalCatalogReleaseProtocol.isLowercaseSHA256),
              pointer.packageSize > 0,
              pointer.sqliteSchemaVersion == MedicalCatalogReleaseProtocol.sqliteSchemaVersion else {
            throw MedicalCatalogTrustError.invalidField
        }
        guard pointer.repository == MedicalCatalogReleaseProtocol.repository,
              pointer.releaseTag == MedicalCatalogReleaseProtocol.releaseTag else {
            throw MedicalCatalogTrustError.invalidScope
        }
        guard pointer.packageAssetName == MedicalCatalogReleaseProtocol.packageAssetName(
            sqliteSHA256: pointer.sqliteSHA256, packageSHA256: pointer.packageSHA256) else {
            throw MedicalCatalogTrustError.assetNameMismatch
        }
        guard let issued = MedicalCatalogReleaseProtocol.timestamp(pointer.issuedAt),
              let expires = MedicalCatalogReleaseProtocol.timestamp(pointer.expiresAt) else {
            throw MedicalCatalogTrustError.invalidField
        }
        guard expires > issued, expires.timeIntervalSince(issued) <= MedicalCatalogReleaseProtocol.pointerValidity else {
            throw MedicalCatalogTrustError.expired
        }
        pointer.issuedDate = issued
        pointer.expiresDate = expires
        return pointer
    }

    /// App 永不接受过期 pointer（Go `allowExpired` 仅供 CI checkpoint 恢复）。
    func checkWindow(now: Date) throws {
        guard issuedDate <= now.addingTimeInterval(MedicalCatalogReleaseProtocol.issuedAtSkew), expiresDate > now else {
            throw MedicalCatalogTrustError.expired
        }
    }
}

struct MedicalCatalogTrustRoot {
    let version: Int64
    let keys: [String: Data]
    let rootKeyIDs: [String]
    let catalogKeyIDs: [String]

    private struct Document: Decodable {
        struct Key: Decodable {
            let id: String
            let publicKey: String
        }

        let schemaVersion: Int
        let role: String
        let app: String
        let assetKind: String
        let version: Int64
        let expiresAt: String
        let keys: [Key]
        let rootKeyIDs: [String]
        let rootThreshold: Int
        let catalogKeyIDs: [String]
        let catalogThreshold: Int
        let assetBaseURL: String
        let allowedHosts: [String]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case schemaVersion, role, app, assetKind, version, expiresAt, keys, rootKeyIDs, rootThreshold
            case catalogKeyIDs, catalogThreshold, assetBaseURL, allowedHosts
        }
    }

    /// Go `validateRoot` 的 Swift 镜像（不含根签名，由 evaluator 验）。
    static func decode(_ payload: Data, now: Date, hasher: any ContentHashing) throws -> Self {
        let malformed = MedicalCatalogTrustError.malformedEnvelope
        let document = try MedicalCatalogJSON.strict(Document.self, from: payload,
                                                    keys: Set(Document.CodingKeys.allCases.map(\.rawValue)),
                                                    onFailure: malformed)
        let rawKeys = try MedicalCatalogJSON.object(payload, onFailure: malformed)["keys"] as? [Any] ?? []
        guard rawKeys.allSatisfy({ ($0 as? [String: Any]).map { Set($0.keys).isSubset(of: ["id", "publicKey"]) } == true }) else {
            throw malformed
        }
        guard document.schemaVersion == 1, document.role == "root", document.app == MedicalCatalogReleaseProtocol.app,
              document.assetKind == MedicalCatalogReleaseProtocol.assetKind else {
            throw MedicalCatalogTrustError.invalidScope
        }
        guard document.version > 0, let expires = MedicalCatalogReleaseProtocol.timestamp(document.expiresAt) else {
            throw MedicalCatalogTrustError.invalidField
        }
        guard expires > now else { throw MedicalCatalogTrustError.expired }
        guard (1...MedicalCatalogReleaseProtocol.maxKeys).contains(document.keys.count) else {
            throw MedicalCatalogTrustError.invalidKeySet
        }
        var keys: [String: Data] = [:]
        for key in document.keys {
            guard let raw = MedicalCatalogReleaseProtocol.strictBase64(key.publicKey), raw.count == 32,
                  hasher.sha256Hex(raw) == key.id, keys[key.id] == nil else {
                throw MedicalCatalogTrustError.invalidKeySet
            }
            keys[key.id] = raw
        }
        let threshold = MedicalCatalogReleaseProtocol.signatureThreshold
        let rootIDs = Set(document.rootKeyIDs)
        let catalogIDs = Set(document.catalogKeyIDs)
        guard document.rootThreshold == threshold, document.rootKeyIDs.count == threshold,
              document.catalogThreshold == threshold, document.catalogKeyIDs.count == threshold,
              rootIDs.count == threshold, catalogIDs.count == threshold,
              rootIDs.isDisjoint(with: catalogIDs),
              rootIDs.union(catalogIDs).isSubset(of: keys.keys) else {
            throw MedicalCatalogTrustError.invalidKeySet
        }
        guard document.assetBaseURL == MedicalCatalogReleaseProtocol.releaseBaseURL,
              !document.allowedHosts.isEmpty,
              Set(document.allowedHosts).count == document.allowedHosts.count,
              Set(document.allowedHosts).isSubset(of: MedicalCatalogReleaseProtocol.allowedHosts) else {
            throw MedicalCatalogTrustError.invalidScope
        }
        return Self(version: document.version, keys: keys,
                    rootKeyIDs: document.rootKeyIDs, catalogKeyIDs: document.catalogKeyIDs)
    }
}

/// pinned root → signed pointer → 期望比对的完整判定；密码学原语由平台注入
/// （生产 = CryptoKit，见 `CryptoKitMedicalCatalogTrustVerifier`）。
struct MedicalCatalogTrustEvaluator {
    let hasher: any ContentHashing
    let isValidSignature: @Sendable (_ signature: Data, _ payload: Data, _ publicKey: Data) -> Bool

    func pinnedRoot(_ json: Data, now: Date) throws -> MedicalCatalogTrustRoot {
        let envelope = try MedicalCatalogSignedEnvelope.decode(json)
        let root = try MedicalCatalogTrustRoot.decode(envelope.payload, now: now, hasher: hasher)
        try verifySignatures(envelope, keys: root.keys, allowed: root.rootKeyIDs)
        return root
    }

    func verify(pinnedRootJSON: Data, catalogJSON: Data, expected: MedicalCatalogSignedExpectation, now: Date) throws {
        let root = try pinnedRoot(pinnedRootJSON, now: now)
        let envelope = try MedicalCatalogSignedEnvelope.decode(catalogJSON)
        try verifySignatures(envelope, keys: root.keys, allowed: root.catalogKeyIDs)
        let pointer = try MedicalCatalogSignedPointer.decode(envelope.payload)
        guard pointer.rootVersion == root.version else { throw MedicalCatalogTrustError.rootMismatch }
        try pointer.checkWindow(now: now)
        let signed = MedicalCatalogSignedExpectation(pointer, signedPointerDigest: hasher.sha256Hex(envelope.payload))
        guard signed == expected else { throw MedicalCatalogTrustError.expectationMismatch }
    }

    /// 只数 `allowed` 内且在 root key 表中的 keyId；未知 keyId 忽略但不计数。
    private func verifySignatures(_ envelope: MedicalCatalogSignedEnvelope, keys: [String: Data], allowed: [String]) throws {
        let permitted = Set(allowed)
        var verified = 0
        for signature in envelope.signatures {
            guard permitted.contains(signature.keyID), let key = keys[signature.keyID] else { continue }
            if isValidSignature(signature.raw, envelope.payload, key) { verified += 1 }
        }
        guard verified >= MedicalCatalogReleaseProtocol.signatureThreshold else {
            throw MedicalCatalogTrustError.signatureThreshold
        }
    }
}

enum MedicalCatalogJSON {
    static func object(_ data: Data, onFailure failure: MedicalCatalogTrustError) throws -> [String: Any] {
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) } catch { throw failure }
        guard let object = value as? [String: Any] else { throw failure }
        return object
    }

    /// 等价 Go `DisallowUnknownFields`：顶层出现未声明字段即拒绝。
    static func strict<T: Decodable>(_ type: T.Type, from data: Data, keys: Set<String>,
                                     onFailure failure: MedicalCatalogTrustError) throws -> T {
        guard Set(try object(data, onFailure: failure).keys).isSubset(of: keys) else { throw failure }
        do { return try JSONDecoder().decode(type, from: data) } catch { throw failure }
    }
}
