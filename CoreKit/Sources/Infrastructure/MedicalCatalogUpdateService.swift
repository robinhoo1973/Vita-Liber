#if os(iOS) || os(macOS)
// linux-blind: URLSession/AgeKit 更新链路 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import CryptoKit
import Foundation
import Domain

/// 平台/密钥实现注入点：AgeKit 解密 + ZIP 解包实现放在发布配置适配器中，
/// 更新服务本身不保存/生成私钥。
public protocol MedicalCatalogPackageOpening: Sendable {
    func open(packageURL: URL, sqliteURL: URL) async throws
}

public struct MedicalCatalogRelease: Sendable, Equatable {
    public let packageURL: URL
    public let sqliteSHA256: String
    public let catalogVersion: String
    public let changeNote: String?

    public init(packageURL: URL, sqliteSHA256: String, catalogVersion: String, changeNote: String? = nil) {
        self.packageURL = packageURL
        self.sqliteSHA256 = sqliteSHA256.lowercased()
        self.catalogVersion = catalogVersion
        self.changeNote = changeNote
    }
}

public enum MedicalCatalogUpdateError: Error, Equatable {
    case invalidSHA256
    case downloadFailed
    case checksumMismatch
    case catalogIntegrityFailed
    case replacementFailed
}

/// 下载/校验/原子替换独立目录；患者主库完全不参与。
public actor MedicalCatalogUpdateService {
    private let destination: URL
    private let session: URLSession

    public init(destination: URL, session: URLSession = .shared) {
        self.destination = destination
        self.session = session
    }

    public func update(_ release: MedicalCatalogRelease,
                       opener: any MedicalCatalogPackageOpening) async throws {
        guard release.sqliteSHA256.count == 64,
              release.sqliteSHA256.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) }) else {
            throw MedicalCatalogUpdateError.invalidSHA256
        }
        let root = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = root.appendingPathComponent("medical-catalog-download-\(UUID().uuidString).bin")
        let decrypted = root.appendingPathComponent("medical-catalog-staging-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: package) // try?-ok: temporary cleanup only
            try? FileManager.default.removeItem(at: decrypted) // try?-ok: temporary cleanup only
        }
        do {
            let (url, response) = try await session.download(from: release.packageURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MedicalCatalogUpdateError.downloadFailed }
            try FileManager.default.copyItem(at: url, to: package)
            try await opener.open(packageURL: package, sqliteURL: decrypted)
        } catch let error as MedicalCatalogUpdateError {
            throw error
        } catch {
            throw MedicalCatalogUpdateError.downloadFailed
        }
        guard try sha256(of: decrypted) == release.sqliteSHA256 else {
            throw MedicalCatalogUpdateError.checksumMismatch
        }
        do {
            _ = try MedicalCatalogStore(path: decrypted)
        } catch {
            throw MedicalCatalogUpdateError.catalogIntegrityFailed
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: decrypted)
            } else {
                try FileManager.default.moveItem(at: decrypted, to: destination)
            }
        } catch {
            throw MedicalCatalogUpdateError.replacementFailed
        }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() } // try?-ok: read-only temporary handle cleanup
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1 << 20) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#endif
