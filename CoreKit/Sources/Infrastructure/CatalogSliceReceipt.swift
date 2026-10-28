import Domain
import Foundation

/// 切片安装回执（派生数据）。
///
/// `slice_meta` 没有 catalogVersion，装后「当前版本」只能落在包外回执：
/// `…/catalog/v5/receipts/app-catalog-<kind>.json`，复用与 floor/journal
/// 相同的原子落盘原语（`MedicalCatalogSupportFile`）。
///
/// 语义约束（2026-10-28 二轮质询裁决 7）：
/// - 回执是**派生数据**：写失败不得回滚已成功的激活——`write` 以 Bool 返回，
///   调用方只记诊断；缺失时由 journal `Record`（已含 candidateCatalogVersion/
///   candidateSQLiteSHA256/candidateSignedPointerDigest）重建。
/// - 读侧严格：schemaVersion/kind/摘要形态任一不符按「无回执」处理。
public struct CatalogSliceReceipt: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maxBytes = 16 * 1024

    public let schemaVersion: Int
    public let kind: String
    public let catalogVersion: Int64
    public let rootVersion: Int64
    public let sqliteSHA256: String
    public let sqliteSize: Int64
    public let signedPayloadDigest: String
    public let installedAt: Date

    public init(candidate: VerifiedCatalogSliceCandidate, installedAt: Date) {
        schemaVersion = Self.schemaVersion
        kind = candidate.kind.rawValue
        catalogVersion = candidate.catalogVersion
        rootVersion = candidate.rootVersion
        sqliteSHA256 = candidate.sqliteSHA256
        sqliteSize = candidate.sqliteSize
        signedPayloadDigest = candidate.signedPayloadDigest
        self.installedAt = installedAt
    }

    public static func productionURL(kind: CatalogSliceKind, directory: URL) -> URL {
        directory.appendingPathComponent("receipts")
            .appendingPathComponent(kind.stem + ".json")
    }

    /// 读回执：任一不合法即 nil（按「无回执」处理，调用方走 journal 重建路径）。
    public static func read(kind: CatalogSliceKind, directory: URL) -> CatalogSliceReceipt? {
        guard let data = MedicalCatalogSupportFile.read(productionURL(kind: kind, directory: directory),
                                                        maxBytes: maxBytes) else { return nil }
        guard let decoded = try? JSONDecoder().decode(CatalogSliceReceipt.self, from: data),   // try?-ok: 损坏回执按无回执处理
              decoded.schemaVersion == Self.schemaVersion,
              decoded.kind == kind.rawValue,
              decoded.catalogVersion > 0,
              decoded.rootVersion >= 1,
              decoded.sqliteSize > 0,
              MedicalCatalogReleaseProtocol.isLowercaseSHA256(decoded.sqliteSHA256),
              MedicalCatalogReleaseProtocol.isLowercaseSHA256(decoded.signedPayloadDigest) else {
            return nil
        }
        return decoded
    }

    /// 写回执：返回成败，绝不抛出——回执写失败不得影响已成功的激活路径。
    @discardableResult
    public static func write(_ receipt: CatalogSliceReceipt, directory: URL) -> Bool {
        guard let kind = CatalogSliceKind(rawValue: receipt.kind),
              let data = try? JSONEncoder().encode(receipt), data.count <= maxBytes else {   // try?-ok: 编码失败按写失败处理
            return false
        }
        do {
            try MedicalCatalogSupportFile.write(data, to: productionURL(kind: kind, directory: directory))
            return true
        } catch {
            return false
        }
    }
}
