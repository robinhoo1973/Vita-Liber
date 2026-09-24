#if os(iOS) || os(macOS)
// linux-blind: URLSession/AgeKit 更新链路 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import CryptoKit
import Foundation
import Domain
import AgeKit
import ZIPFoundation

/// AgeKit 解密 + ZIP 解包适配器；identity 由 App 发布配置注入，
/// 更新服务本身不保存/生成私钥。
public protocol MedicalCatalogPackageOpening: Sendable {
    func open(packageURL: URL, sqliteURL: URL) async throws
}

public struct MedicalCatalogRelease: Sendable, Equatable {
    public let packageURL: URL
    public let sqliteSHA256: String
    public let catalogVersion: Int64
    public let changeNote: String?
    public let contentSHA256: String
    public let manifestSHA256: String
    public let trustRootJSON: Data
    public let signedCatalogJSON: Data

    public init(packageURL: URL, sqliteSHA256: String, catalogVersion: Int64,
                contentSHA256: String, manifestSHA256: String,
                trustRootJSON: Data, signedCatalogJSON: Data,
                changeNote: String? = nil) {
        self.packageURL = packageURL
        self.sqliteSHA256 = sqliteSHA256.lowercased()
        self.catalogVersion = catalogVersion
        self.changeNote = changeNote
        self.contentSHA256 = contentSHA256.lowercased()
        self.manifestSHA256 = manifestSHA256.lowercased()
        self.trustRootJSON = trustRootJSON
        self.signedCatalogJSON = signedCatalogJSON
    }
}

public protocol MedicalCatalogTrustVerifying: Sendable {
    func verify(rootJSON: Data, catalogJSON: Data, expectedContentSHA256: String,
                expectedManifestSHA256: String, expectedCatalogVersion: Int64) throws
}

public enum MedicalCatalogTrustError: Error, Equatable {
    case malformedEnvelope
    case invalidScope
    case invalidKeySet
    case invalidSignature
    case signatureThreshold
    case expired
    case catalogVersionMismatch
    case contentHashMismatch
    case manifestHashMismatch
}

/// CryptoKit verifier for the independent `assetKind=medical-data` trust chain.
/// The root/catalog JSON is public Release metadata; no private signing key is
/// ever loaded by the App.
public struct CryptoKitMedicalCatalogTrustVerifier: MedicalCatalogTrustVerifying, Sendable {
    public init() {}

    public func verify(rootJSON: Data, catalogJSON: Data, expectedContentSHA256: String,
                       expectedManifestSHA256: String, expectedCatalogVersion: Int64) throws {
        let rootEnvelope = try Self.object(rootJSON)
        let (rootBytes, root) = try Self.payload(from: rootEnvelope)
        try Self.checkScope(root, role: "root")
        let rootInfo = try Self.rootInfo(root)
        try Self.verifySignatures(rootEnvelope, payload: rootBytes, keys: rootInfo.keys,
                                  allowed: rootInfo.rootKeyIDs, threshold: rootInfo.rootThreshold)
        guard let rootVersion = Self.int64(root["version"]), rootVersion > 0,
              let rootExpires = Self.date(root["expiresAt"]), rootExpires > Date(),
              Self.isReleaseBaseURL(root["assetBaseURL"]) else {
            throw MedicalCatalogTrustError.expired
        }

        let catalogEnvelope = try Self.object(catalogJSON)
        let (catalogBytes, catalog) = try Self.payload(from: catalogEnvelope)
        try Self.checkScope(catalog, role: "catalog")
        try Self.verifySignatures(catalogEnvelope, payload: catalogBytes, keys: rootInfo.keys,
                                  allowed: rootInfo.catalogKeyIDs, threshold: rootInfo.catalogThreshold)
        guard Self.int64(catalog["rootVersion"]) == rootVersion,
              Self.int64(catalog["catalogVersion"]) == expectedCatalogVersion else {
            throw MedicalCatalogTrustError.catalogVersionMismatch
        }
        guard Self.lowerHex(catalog["contentSha256"]) == expectedContentSHA256.lowercased() else {
            throw MedicalCatalogTrustError.contentHashMismatch
        }
        guard Self.lowerHex(catalog["manifestSha256"]) == expectedManifestSHA256.lowercased() else {
            throw MedicalCatalogTrustError.manifestHashMismatch
        }
        guard let issued = Self.date(catalog["issuedAt"]),
              let expires = Self.date(catalog["expiresAt"]),
              expires > Date(), issued <= Date().addingTimeInterval(5 * 60),
              expires > issued, expires.timeIntervalSince(issued) <= 31 * 24 * 60 * 60 else {
            throw MedicalCatalogTrustError.expired
        }
    }

    private struct RootInfo {
        let keys: [String: Data]
        let rootKeyIDs: Set<String>
        let catalogKeyIDs: Set<String>
        let rootThreshold: Int
        let catalogThreshold: Int
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data), // try?-ok: malformed public metadata maps to a typed trust error
              let object = value as? [String: Any] else { throw MedicalCatalogTrustError.malformedEnvelope }
        return object
    }

    private static func payload(from envelope: [String: Any]) throws -> (Data, [String: Any]) {
        guard let encoded = envelope["payload"] as? String,
              let data = Data(base64Encoded: encoded),
              let object = try? object(data) else { throw MedicalCatalogTrustError.malformedEnvelope } // try?-ok: malformed public metadata maps to a typed trust error
        return (data, object)
    }

    private static func checkScope(_ object: [String: Any], role: String) throws {
        guard int64(object["schemaVersion"]) == 1,
              object["role"] as? String == role,
              object["app"] as? String == "vitaliber",
              object["assetKind"] as? String == "medical-data" else {
            throw MedicalCatalogTrustError.invalidScope
        }
    }

    private static func rootInfo(_ root: [String: Any]) throws -> RootInfo {
        guard let values = root["keys"] as? [[String: Any]], !values.isEmpty,
              let rootIDs = root["rootKeyIDs"] as? [String],
              let catalogIDs = root["catalogKeyIDs"] as? [String],
              let rootThreshold = int64(root["rootThreshold"]).flatMap(Int.init),
              let catalogThreshold = int64(root["catalogThreshold"]).flatMap(Int.init),
              rootThreshold > 0, catalogThreshold > 0,
              Set(rootIDs).isDisjoint(with: catalogIDs) else {
            throw MedicalCatalogTrustError.invalidKeySet
        }
        var keys: [String: Data] = [:]
        for value in values {
            guard let id = value["id"] as? String,
                  let encoded = value["publicKey"] as? String,
                  let data = Data(base64Encoded: encoded), data.count == 32,
                  SHA256.hash(data: data).hexString == id, keys[id] == nil else {
                throw MedicalCatalogTrustError.invalidKeySet
            }
            keys[id] = data
        }
        guard rootThreshold <= rootIDs.count, catalogThreshold <= catalogIDs.count,
              Set(rootIDs).isSubset(of: keys.keys), Set(catalogIDs).isSubset(of: keys.keys) else {
            throw MedicalCatalogTrustError.invalidKeySet
        }
        return RootInfo(keys: keys, rootKeyIDs: Set(rootIDs), catalogKeyIDs: Set(catalogIDs),
                        rootThreshold: rootThreshold, catalogThreshold: catalogThreshold)
    }

    private static func verifySignatures(_ envelope: [String: Any], payload: Data,
                                         keys: [String: Data], allowed: Set<String>, threshold: Int) throws {
        guard let values = envelope["signatures"] as? [[String: Any]], !values.isEmpty else {
            throw MedicalCatalogTrustError.invalidSignature
        }
        var seen = Set<String>()
        var verified = Set<String>()
        for value in values {
            guard let keyID = value["keyId"] as? String,
                  seen.insert(keyID).inserted else { throw MedicalCatalogTrustError.invalidSignature }
            guard allowed.contains(keyID), let publicData = keys[keyID],
                  let encoded = value["signature"] as? String,
                  let signature = Data(base64Encoded: encoded), signature.count == 64 else { continue }
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
            if key.isValidSignature(signature, for: payload) { verified.insert(keyID) }
        }
        guard verified.count >= threshold else { throw MedicalCatalogTrustError.signatureThreshold }
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    private static func lowerHex(_ value: Any?) -> String? {
        guard let string = value as? String, string.count == 64,
              string.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) || ("A"..."F").contains($0) }) else { return nil }
        return string.lowercased()
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func isReleaseBaseURL(_ value: Any?) -> Bool {
        guard let value = value as? String, let url = URL(string: value),
              url.scheme == "https", url.host == "github.com",
              url.path.contains("/releases/download/") else { return false }
        return true
    }
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

public enum MedicalCatalogUpdateError: Error, Equatable {
    case invalidSHA256
    case downloadFailed
    case checksumMismatch
    case catalogIntegrityFailed
    case replacementFailed
    case trustVerificationFailed
}

/// 下载/校验/原子替换独立目录；患者主库完全不参与。
public actor MedicalCatalogUpdateService {
    private let destination: URL
    private let session: URLSession
    private let trustVerifier: any MedicalCatalogTrustVerifying

    public init(destination: URL, session: URLSession = .shared,
                trustVerifier: any MedicalCatalogTrustVerifying = CryptoKitMedicalCatalogTrustVerifier()) {
        self.destination = destination
        self.session = session
        self.trustVerifier = trustVerifier
    }

    public func update(_ release: MedicalCatalogRelease,
                       opener: any MedicalCatalogPackageOpening) async throws {
        guard release.sqliteSHA256.count == 64,
              release.sqliteSHA256.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) }) else {
            throw MedicalCatalogUpdateError.invalidSHA256
        }
        do {
            try trustVerifier.verify(rootJSON: release.trustRootJSON, catalogJSON: release.signedCatalogJSON,
                                    expectedContentSHA256: release.contentSHA256,
                                    expectedManifestSHA256: release.manifestSHA256,
                                    expectedCatalogVersion: release.catalogVersion)
        } catch {
            throw MedicalCatalogUpdateError.trustVerificationFailed
        }
        guard let packageHost = release.packageURL.host,
              release.packageURL.scheme == "https",
              ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(packageHost) else {
            throw MedicalCatalogUpdateError.downloadFailed
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
            try MedicalCatalogStore.integrityCheck(path: decrypted)
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

/// AgeKit + ZIPFoundation adapter. The identity text is supplied by the App
/// build configuration; no private key is stored in this repository.
public struct AgeKitMedicalCatalogPackageOpening: MedicalCatalogPackageOpening, Sendable {
    private let identityText: Data

    public init(identityText: String) {
        self.identityText = Data(identityText.utf8)
    }

    public func open(packageURL: URL, sqliteURL: URL) async throws {
        let zipURL = sqliteURL.deletingPathExtension().appendingPathExtension("zip")
        defer { try? FileManager.default.removeItem(at: zipURL) } // try?-ok: staging cleanup
        guard let input = InputStream(url: packageURL) else { throw MedicalCatalogUpdateError.downloadFailed }
        input.open()
        let keyInput = InputStream(data: identityText)
        keyInput.open()
        defer { input.close(); keyInput.close() }
        let identities = try Age.parseIdentities(input: keyInput)
        guard identities.count == 1, let identity = identities.first else {
            throw MedicalCatalogUpdateError.downloadFailed
        }
        var reader = try Age.decrypt(src: input, identities: identity)
        guard let output = OutputStream(url: zipURL, append: false) else { throw MedicalCatalogUpdateError.downloadFailed }
        output.open()
        defer { output.close() }
        var buffer = Data(count: 64 * 1024)
        while true {
            let count = try reader.read(&buffer)
            if count == 0 { break }
            try Self.write(buffer, to: output)
        }
        try Self.extractSQLite(from: zipURL, to: sqliteURL)
    }

    private static func write(_ data: Data, to stream: OutputStream) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var offset = 0
            while offset < data.count {
                let count = stream.write(base.advanced(by: offset), maxLength: data.count - offset)
                guard count > 0 else { throw MedicalCatalogUpdateError.downloadFailed }
                offset += count
            }
        }
    }

    private static func extractSQLite(from zipURL: URL, to sqliteURL: URL) throws {
        let archive = try Archive(url: zipURL, accessMode: .read, pathEncoding: nil)
        let entries = Array(archive)
        guard entries.count == 1, let entry = entries.first,
              entry.path == "medical-catalog.sqlite", entry.type == .file else {
            throw MedicalCatalogUpdateError.downloadFailed
        }
        let parent = sqliteURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: sqliteURL.path, contents: nil) else {
            throw MedicalCatalogUpdateError.downloadFailed
        }
        let handle = try FileHandle(forWritingTo: sqliteURL)
        defer { try? handle.close() } // try?-ok: staging handle cleanup
        var received: UInt64 = 0
        let crc = try archive.extract(entry) { data in
            received += UInt64(data.count)
            guard received <= UInt64(entry.uncompressedSize) else { throw MedicalCatalogUpdateError.downloadFailed }
            try handle.write(contentsOf: data)
        }
        guard received == UInt64(entry.uncompressedSize), crc == entry.checksum else {
            throw MedicalCatalogUpdateError.downloadFailed
        }
    }
}
#endif
