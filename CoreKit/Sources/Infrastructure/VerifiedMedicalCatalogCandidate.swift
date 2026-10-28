import Foundation
import Protocols

/// 2026-10-28 切片-only B2：本文件收敛为**信任线存活面**（v4 指针/期望/候选/
/// 验签协议已删除——切片候选见 `CatalogSliceManifest.swift`）。保留：
/// - `MedicalCatalogReleaseProtocol` 线协议常量（切片文法与存活传输层共用）；
/// - `MedicalCatalogSignedEnvelope`（切片清单复用的签名信封严格解码）；
/// - `MedicalCatalogTrustRoot` + `MedicalCatalogTrustEvaluator`（pinned root 2-of-2
///   判定；切片 `verifySlice` 与 Go 金样的 pinned-root 测试共用）；
/// - `MedicalCatalogJSON` 严格 JSON 助手。
public enum MedicalCatalogReleaseProtocol {
    public static let repository = "robinhoo1973/Resources"
    public static let releaseTag = "medical-data"
    public static let assetKind = "medical-data"
    public static let app = "vitaliber"
    public static let sqliteSchemaVersion = 9
    /// v8 is a migration work copy, never a release. Legacy signed catalogs remain readable.
    public static let supportedSQLiteSchemaVersions: Set<Int> = [4, 5, 6, 7, 9]
    public static let sqliteEntryName = "medical-catalog.sqlite"
    /// CNB 资源下载基址(与 Go cnbReleaseBaseURL 逐字节一致)。
    public static let releaseBaseURL = "https://cnb.cool/" + repository + "/-/releases/download/" + releaseTag
    /// 基址主机(cnb.cool,常量拼出的首跳)+ 传输主机(asset.cnb.cool,根钉定;
    /// 根 allowedHosts ⊆ 本集仍成立,与 GitHub 时代的基址+CDN 双主机同构)。
    public static let allowedHosts: Set<String> = ["cnb.cool", "asset.cnb.cool"]
    static let signatureThreshold = 2
    static let maxPayloadBytes = 1 << 20
    static let maxEnvelopeBytes = 2 << 20
    static let maxKeys = 16
    static let maxSignatures = 16
    static let pointerValidity: TimeInterval = 31 * 24 * 60 * 60
    static let issuedAtSkew: TimeInterval = 5 * 60

    /// v3 资产白名单（冻结口径 2026-10-07；与 Go `vitaliber/medical-data/go`
    /// `names.go` 及 Resources 仓 readme-sync sections.json 同步）——仅三类：
    /// `manifest.json`（固定名单例，**唯一提交点**）、`overview.json`（固定名
    /// 单例）、`package-<catalogVersion>.bin`（仅追加）。一切其它资产名不进候选。
    public static let manifestAssetName = "manifest.json"
    public static let overviewAssetName = "overview.json"
    private static let packagePrefix = "package-"
    private static let packageSuffix = ".bin"

    /// v3 包资产名：`package-<catalogVersion>.bin`。版本段 `[1-9][0-9]{0,18}`
    /// （与 Go `packageNamePattern` 逐字对齐；版本号 = 首次产出该包的 catalogVersion）。
    public static func packageAssetName(catalogVersion: Int64) -> String {
        packagePrefix + String(catalogVersion) + packageSuffix
    }

    /// v3 包名文法判定（返回版本号；非法即 nil）。v2 的「名内嵌双哈希」不变量与
    /// 时间戳指针文法一并退役——包字节的完整性由**签名载荷 `packageSha256`**
    /// 对下载字节回验承担（同职责换载体）。
    public static func packageAssetVersion(_ name: String) -> Int64? {
        guard name.hasPrefix(packagePrefix), name.hasSuffix(packageSuffix) else { return nil }
        let body = name.dropFirst(packagePrefix.count).dropLast(packageSuffix.count)
        guard (1...19).contains(body.utf8.count), body.first != "0",
              body.utf8.allSatisfy({ (48...57).contains($0) }),
              let version = Int64(body), version > 0 else { return nil }
        return version
    }

    public static func isPackageAssetName(_ name: String) -> Bool {
        packageAssetVersion(name) != nil
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
                                                    integerKeys: ["schemaVersion", "version", "rootThreshold", "catalogThreshold"],
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

/// pinned root 判定 + 签名计数；密码学原语由平台注入（生产 = CryptoKit）。
struct MedicalCatalogTrustEvaluator {
    let hasher: any ContentHashing
    let isValidSignature: @Sendable (_ signature: Data, _ payload: Data, _ publicKey: Data) -> Bool

    func pinnedRoot(_ json: Data, now: Date) throws -> MedicalCatalogTrustRoot {
        let envelope = try MedicalCatalogSignedEnvelope.decode(json)
        let root = try MedicalCatalogTrustRoot.decode(envelope.payload, now: now, hasher: hasher)
        try verifySignatures(envelope, keys: root.keys, allowed: root.rootKeyIDs)
        return root
    }

    /// 只数 `allowed` 内且在 root key 表中的 keyId；未知 keyId 忽略但不计数。
    /// internal（2026-10-28 B0）：切片 `verifySlice` 复用同一计数判定。
    func verifySignatures(_ envelope: MedicalCatalogSignedEnvelope, keys: [String: Data], allowed: [String]) throws {
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
                                     integerKeys: Set<String> = [],
                                     onFailure failure: MedicalCatalogTrustError) throws -> T {
        let raw = try object(data, onFailure: failure)
        guard Set(raw.keys).isSubset(of: keys) else { throw failure }
        try requireIntegers(raw, keys: integerKeys, onFailure: failure)
        do { return try JSONDecoder().decode(type, from: data) } catch { throw failure }
    }

    /// JSONDecoder can coerce integral floats; Go's int64 wire fields cannot.
    static func requireIntegers(_ object: [String: Any], keys: Set<String>,
                                onFailure failure: MedicalCatalogTrustError) throws {
        for key in keys {
            guard let number = object[key] as? NSNumber,
                  ["s", "i", "l", "q", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
                  Int64(number.stringValue) != nil else { throw failure }
        }
    }
}
