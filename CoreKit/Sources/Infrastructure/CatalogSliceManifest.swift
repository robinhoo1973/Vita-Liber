import Domain
import Foundation
import Protocols

/// 切片清单解码与密封候选（2026-10-28 切片-only 批次 B0：契约件，无行为变化）。
///
/// 载荷 22 键（f7 发布器与 App 同源冻结；前 21 键为 2026-10-28 07:22 实测形，
/// 同日晚二轮质询增设 `rootVersion`——只做 1...pinned root.version 界限与回执审计，
/// 不要求等值；`sourceSha256` 被否决：源库不随包，签不可验证字段=假保证）：
/// `app` / `assetKind` / `assetName` / `catalogVersion` / `containerFormat` /
/// `contentSha256` / `counts` / `createdAt` / `format` / `installable` /
/// `minAppBuild` / `minAppMarketingVersion` / `note` / `packageSha256` /
/// `packageSize` / `regionScope` / `rootVersion` / `schemaVersion` /
/// `sqliteEntryName` / `sqliteSha256` / `sqliteSize` / `tables`。
///
/// 冻结口径：
/// - 无 `issuedAt`/`expiresAt`——真实性 = 2-of-2 签名 + 包/成员双 SHA；
///   新鲜度仅受 pinned root 到期（2028-10-05）约束；防回滚由每片 trust floor 承担。
/// - 无 `containerVersion`——容器版本随 `containerFormat` 冻结（`zip+aes256gcm-v1`）。
/// - `contentSha256 == sqliteSha256`（f7 发布器逐字节同值）。
/// - `createdAt` 为 RFC3339（f7 实测形如 `2026-10-27T23:16:56+00:00`，非 Go Z 形）。
public enum CatalogSliceManifestError: Error, Equatable {
    case invalidField
    case invalidScope
    case unsupportedSliceSchemaVersion
    case unsupportedContainerFormat
    case assetNameMismatch
    case notInstallable
    /// 载荷 `rootVersion` 超出 pinned root 版本（1...root.version）。
    case rootVersionOutOfRange
}

/// 通过 pinned root 验签后的切片候选。memberwise init 为模块内可见：
/// 只有 `CatalogSliceManifestDecoder`（聚合于 `verifySlice`）能产出。
public struct VerifiedCatalogSliceCandidate: Sendable, Equatable {
    public let kind: CatalogSliceKind
    /// 签名载荷声明的信任根版本（只做 1...pinned root.version 界限 + 回执审计；
    /// 不要求与 pinned 等值——固定名资产在 root 轮换窗口需同时服务新旧 rootVersion）。
    public let rootVersion: Int64
    public let catalogVersion: Int64
    public let assetName: String
    public let sqliteEntryName: String
    public let sqliteSHA256: String
    public let sqliteSize: Int64
    public let contentSHA256: String
    public let packageSHA256: String
    public let packageSize: Int64
    public let regionScope: [String]
    public let tables: [String]
    public let counts: [String: Int64]
    public let minAppMarketingVersion: String
    public let minAppBuild: Int64
    public let createdAt: Date
    public let note: String?
    /// 已签载荷原始字节的 SHA-256（journal 审计锚 / 回执）。
    public let signedPayloadDigest: String

    /// minApp 门（build 单调；marketing 比较在 resolver 组装时用）。
    public func isSupported(byAppBuild build: Int64) -> Bool {
        CatalogSliceProtocol.supportsAppBuild(minAppBuild: minAppBuild, currentBuild: build)
    }
}

public enum CatalogSliceManifestDecoder {
    /// 载荷严格键集（DisallowUnknownFields 语义；`note` 为唯一可缺省键）。
    public static let payloadKeys: Set<String> = [
        "app", "assetKind", "assetName", "catalogVersion", "containerFormat",
        "contentSha256", "counts", "createdAt", "format", "installable",
        "minAppBuild", "minAppMarketingVersion", "note", "packageSha256",
        "packageSize", "regionScope", "rootVersion", "schemaVersion", "sqliteEntryName",
        "sqliteSha256", "sqliteSize", "tables",
    ]

    /// 每片 schemaVersion 冻结表集（新增表必须升 schemaVersion 并重签；未知版本 nil）。
    public static func expectedTables(_ kind: CatalogSliceKind, schemaVersion: Int) -> Set<String>? {
        guard schemaVersion == CatalogSliceProtocol.supportedSliceSchemaVersion else { return nil }
        switch kind {
        case .drug: return ["drug", "drug_detail", "drug_reference"]
        case .facility: return ["department", "hospital"]
        case .reference: return ["diagnosis", "exam_item"]
        case .profile:
            // profile 第四切片 13 表冻结集（v3 实发包；`extension_meta` 永久剔除
            // 不发布；视图 active_*/published_top10 不入表集）。
            return ["body_organ", "common_rank", "condition_department", "condition_organ",
                    "condition_profile", "ext_department", "ext_document", "ext_evidence",
                    "ext_source", "kg_extension_release", "surgery", "surgery_department",
                    "surgery_organ"]
        }
    }

    /// 安装期允许的表集 = 数据表 ∪ {`slice_meta`}（禁 `catalog_meta`/FTS/其它表）。
    public static func installedTableSet(_ kind: CatalogSliceKind, schemaVersion: Int) -> Set<String>? {
        expectedTables(kind, schemaVersion: schemaVersion).map { $0.union(["slice_meta"]) }
    }

    /// 解码 + 全字段校验（不含密码学验签；验签入口是 `verifySlice`）。
    public static func candidate(manifestJSON: Data, kind: CatalogSliceKind,
                                 servedAs assetName: String,
                                 hasher: any ContentHashing) throws -> VerifiedCatalogSliceCandidate {
        let envelope = try MedicalCatalogSignedEnvelope.decode(manifestJSON)
        let raw = try MedicalCatalogJSON.object(envelope.payload, onFailure: .invalidField)
        guard Set(raw.keys).isSubset(of: payloadKeys),
              payloadKeys.subtracting(["note"]).isSubset(of: Set(raw.keys)) else {
            throw CatalogSliceManifestError.invalidField
        }
        try MedicalCatalogJSON.requireIntegers(
            raw, keys: ["schemaVersion", "rootVersion", "catalogVersion", "packageSize",
                        "sqliteSize", "minAppBuild"],
            onFailure: .invalidField)
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: envelope.payload) } catch {
            throw CatalogSliceManifestError.invalidField
        }

        guard payload.schemaVersion == CatalogSliceProtocol.supportedSliceSchemaVersion else {
            throw CatalogSliceManifestError.unsupportedSliceSchemaVersion
        }
        guard payload.app == MedicalCatalogReleaseProtocol.app,
              payload.assetKind == CatalogSliceProtocol.manifestAssetKind,
              payload.format == CatalogSliceProtocol.manifestFormat else {
            throw CatalogSliceManifestError.invalidScope
        }
        // 名字即身份：served 名、载荷包名、包内成员名三者与 kind 精确绑定。
        guard assetName == kind.manifestAssetName,
              payload.assetName == kind.packageAssetName,
              payload.sqliteEntryName == kind.sqliteEntryName else {
            throw CatalogSliceManifestError.assetNameMismatch
        }
        guard payload.installable else { throw CatalogSliceManifestError.notInstallable }
        guard payload.catalogVersion > 0, payload.rootVersion >= 1, payload.packageSize > 0,
              payload.sqliteSize > 0, payload.minAppBuild > 0,
              !payload.minAppMarketingVersion.isEmpty else {
            throw CatalogSliceManifestError.invalidField
        }
        guard [payload.sqliteSHA256, payload.packageSHA256, payload.contentSHA256]
                .allSatisfy(MedicalCatalogReleaseProtocol.isLowercaseSHA256),
              payload.contentSHA256 == payload.sqliteSHA256 else {
            throw CatalogSliceManifestError.invalidField
        }
        guard payload.containerFormat == CatalogSliceProtocol.containerFormat else {
            throw CatalogSliceManifestError.unsupportedContainerFormat
        }
        guard !payload.regionScope.isEmpty,
              Set(payload.regionScope).count == payload.regionScope.count,
              payload.regionScope.allSatisfy({ !$0.isEmpty }) else {
            throw CatalogSliceManifestError.invalidField
        }
        let tableSet = Set(payload.tables)
        guard let expected = expectedTables(kind, schemaVersion: payload.schemaVersion),
              payload.tables.count == tableSet.count,
              tableSet == expected,
              Set(payload.counts.keys) == tableSet,
              payload.counts.values.allSatisfy({ $0 > 0 }) else {
            throw CatalogSliceManifestError.invalidField
        }
        guard let created = rfc3339(payload.createdAt) else {
            throw CatalogSliceManifestError.invalidField
        }
        return VerifiedCatalogSliceCandidate(
            kind: kind,
            rootVersion: payload.rootVersion,
            catalogVersion: payload.catalogVersion,
            assetName: payload.assetName,
            sqliteEntryName: payload.sqliteEntryName,
            sqliteSHA256: payload.sqliteSHA256,
            sqliteSize: payload.sqliteSize,
            contentSHA256: payload.contentSHA256,
            packageSHA256: payload.packageSHA256,
            packageSize: payload.packageSize,
            regionScope: payload.regionScope,
            tables: payload.tables,
            counts: payload.counts,
            minAppMarketingVersion: payload.minAppMarketingVersion,
            minAppBuild: payload.minAppBuild,
            createdAt: created,
            note: payload.note,
            signedPayloadDigest: hasher.sha256Hex(envelope.payload))
    }

    /// RFC3339（接受 `+00:00` 与 `Z` 两种零时区书写；f7 发布器输出前者）。
    static func rfc3339(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: value)
    }

    private struct Payload: Decodable {
        let app: String
        let assetKind: String
        let assetName: String
        let catalogVersion: Int64
        let containerFormat: String
        let contentSHA256: String
        let counts: [String: Int64]
        let createdAt: String
        let format: String
        let installable: Bool
        let minAppBuild: Int64
        let minAppMarketingVersion: String
        let note: String?
        let packageSHA256: String
        let packageSize: Int64
        let regionScope: [String]
        let rootVersion: Int64
        let schemaVersion: Int
        let sqliteEntryName: String
        let sqliteSHA256: String
        let sqliteSize: Int64
        let tables: [String]

        enum CodingKeys: String, CodingKey {
            case app, assetKind, assetName, catalogVersion, containerFormat
            case contentSHA256 = "contentSha256"
            case counts, createdAt, format, installable, minAppBuild, minAppMarketingVersion
            case note, packageSize, regionScope, rootVersion, schemaVersion, sqliteEntryName,
                 sqliteSize, tables
            case packageSHA256 = "packageSha256"
            case sqliteSHA256 = "sqliteSha256"
        }
    }
}

extension MedicalCatalogTrustEvaluator {
    /// 切片清单验签入口：pinned root（catalogKeyIDs 2-of-2）+ 严格载荷解码。
    func verifySlice(pinnedRootJSON: Data, manifestJSON: Data, kind: CatalogSliceKind,
                     servedAs assetName: String, hasher: any ContentHashing,
                     now: Date) throws -> VerifiedCatalogSliceCandidate {
        let root = try pinnedRoot(pinnedRootJSON, now: now)
        let envelope = try MedicalCatalogSignedEnvelope.decode(manifestJSON)
        try verifySignatures(envelope, keys: root.keys, allowed: root.catalogKeyIDs)
        let candidate = try CatalogSliceManifestDecoder.candidate(
            manifestJSON: manifestJSON, kind: kind, servedAs: assetName, hasher: hasher)
        // 界限门（非等值）：root 轮换窗口内固定名资产可同时服务新旧 rootVersion。
        guard (1...root.version).contains(candidate.rootVersion) else {
            throw CatalogSliceManifestError.rootVersionOutOfRange
        }
        return candidate
    }
}
