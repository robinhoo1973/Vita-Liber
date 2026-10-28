import Domain
import Foundation

// 目录包传输共享件（2026-10-28 切片-only B2 提取）：v4 `MedicalCatalogUpdateService` /
// `+Install` 即将删除，但下列端口/预算/尺寸门被切片链与存活传输层共用——
// 随 v4 文件不能带走。纯 Foundation、无平台守卫，Linux 可编译可测。

/// 包解密 + 解包端口；identity 由调用方从**已验签的候选**传入，更新服务本身不保存/生成私钥。
/// 实现须把解出的 SQLite 限制在 `maxSQLiteBytes` 内。
///
/// `entryName` = 包内唯一普通成员的期望名（v4 = `medical-catalog.sqlite`；
/// 切片 = `<stem>.sqlite`，由验签后的载荷 `sqliteEntryName` 传入——
/// 2026-10-28 B0 参数化，取代写死单名）。
public protocol MedicalCatalogPackageOpening: Sendable {
    func open(packageURL: URL, sqliteURL: URL, identity: String, entryName: String,
              maxSQLiteBytes: Int64) async throws
}

/// 按签名的 packageAssetName 取密文包；实现须把落盘字节限制在 `expectedSize` 内。
public protocol MedicalCatalogPackageFetching: Sendable {
    func fetch(assetName: String, expectedSize: Int64, to destination: URL,
               progress: @escaping @Sendable (Int64) -> Void) async throws
}

/// 资源预算（字节数上限，不是医疗数值）。
public struct MedicalCatalogUpdateLimits: Sendable, Equatable {
    public let maxPackageBytes: Int64
    public let maxSQLiteBytes: Int64

    public init(maxPackageBytes: Int64, maxSQLiteBytes: Int64) {
        self.maxPackageBytes = maxPackageBytes
        self.maxSQLiteBytes = maxSQLiteBytes
    }

    public static let standard = MedicalCatalogUpdateLimits(maxPackageBytes: 2_147_483_647,
                                                            maxSQLiteBytes: 4_294_967_296)
}

public typealias MedicalCatalogUpdateProgress = MedicalCatalogDownloadProgress  // P3c 升层 Domain，别名兼容

public typealias MedicalCatalogUpdateError = MedicalCatalogDownloadError  // P3c 升层 Domain，别名兼容

/// 文件尺寸门（目录包/SQLite 共用；自 v4 `MedicalCatalogUpdateService.fileSize` 原样搬出）。
public enum CatalogPackageFiles {
    public static func size(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            throw MedicalCatalogUpdateError.packageInvalid
        }
        return size.int64Value
    }
}
