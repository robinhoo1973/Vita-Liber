#if os(iOS) || os(macOS)
import Foundation
import CryptoKit
import Domain

/// ADR-030：App 根公钥 → 连续根轮换 → 签名目录。网络目录不能自己建立信任。
/// 锁保护根/目录/落盘事务；签名只针对原始 payload，绝不重序列化后验证。
public final class ModelCatalogTrustStore: @unchecked Sendable {
    public enum Failure: Error { case unavailable, invalidMetadata, invalidSignature, expired, rollback }
    public static let shared = ModelCatalogTrustStore()
    public let baselineIndex: ASRModelReleaseIndex?
    private let lock = NSLock()
    private let stateURL: URL?
    private var root: ModelTrustRoot?
    private var roots: [SignedModelEnvelope] = []
    private var catalog: SignedModelCatalog?
    private var catalogEnvelope: SignedModelEnvelope?
    private var revokedHashes = Set<String>()
    private struct Baseline: Decodable {
        let schemaVersion: Int
        let entries: [ASRModelRelease]
        let rootVersion: Int?
        let catalogVersion: Int?
        let catalogSHA256: String?
    }
    private var baselineFloor: (root: Int, catalog: Int, digest: String)?
    private struct State: Codable { let roots: [SignedModelEnvelope]; let catalog: SignedModelEnvelope?; let revokedHashes: [String]? }

    public convenience init(bundle: Bundle = .main) {
        let bootstrap = bundle.url(forResource: "ModelTrustRoot", withExtension: "json").flatMap(Self.read)
        let baseline = bundle.url(forResource: "TrustedModelHashes", withExtension: "json").flatMap(Self.read)
        let state = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ModelTrust/asr.json")
        self.init(bootstrapData: bootstrap, baselineData: baseline, stateURL: state)
    }

    public init(bootstrapData: Data?, baselineData: Data?, stateURL: URL?) {
        self.stateURL = stateURL
        var initial: ModelTrustRoot?
        do {
            if let bootstrapData {
                let envelope = try Self.envelope(bootstrapData)
                let value = try JSONDecoder().decode(ModelTrustRoot.self, from: envelope.payload)
                try Self.validateRoot(value)
                try Self.verify(envelope, root: value, role: "root")
                initial = value
            }
        } catch { initial = nil }
        root = initial
        if let initial, let baselineData,
           let baseline = try? JSONDecoder().decode(Baseline.self, from: baselineData), baseline.schemaVersion == 1 { // try?-ok: 签名 App 资源缺失/损坏则无离线基线授权
            baselineIndex = ASRModelReleaseIndex(baseUrl: initial.assetBaseURL, models: baseline.entries)
            if let root = baseline.rootVersion, let catalog = baseline.catalogVersion,
               let digest = baseline.catalogSHA256, root > 0, catalog > 0, ModelResourcePolicy.isSHA256(digest) {
                baselineFloor = (root, catalog, digest)
            }
        } else { baselineIndex = nil }
        guard var current = initial, let stateURL, let data = Self.read(stateURL) else { return }
        do {
            let saved = try JSONDecoder().decode(State.self, from: data)
            guard saved.roots.count <= 256 else { throw Failure.invalidMetadata }
            revokedHashes = Set((saved.revokedHashes ?? []).filter(ModelResourcePolicy.isSHA256))
            var accepted: [SignedModelEnvelope] = []
            for envelope in saved.roots {
                let next = try JSONDecoder().decode(ModelTrustRoot.self, from: envelope.payload)
                if next.version <= current.version { continue } // 新 App 可内嵌更高的信任根。
                try Self.validateRoot(next)
                guard next.version == current.version + 1 else { throw Failure.rollback }
                try Self.verify(envelope, root: current, role: "root")
                try Self.verify(envelope, root: next, role: "root")
                current = next; accepted.append(envelope)
            }
            root = current; roots = accepted
            if let envelope = saved.catalog {
                let value = try Self.catalog(envelope, root: current, checkTime: false)
                try checkBaselineFloor(value, envelope: envelope)
                catalog = value; catalogEnvelope = envelope
                revokedHashes.formUnion(value.revokedHashes)
            }
        } catch {
            // 损坏缓存不能授权任何新增包；App 内根/哈希基线仍有效。
            catalog = nil; catalogEnvelope = nil
        }
    }

    public var nextRootURL: URL? {
        lock.lock(); defer { lock.unlock() }
        guard let root, root.version < Int.max,
              let base = URL(string: root.assetBaseURL) else { return nil }
        return base.appendingPathComponent("\(root.version + 1).root.json")
    }

    public func acceptRoot(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard let current = root else { throw Failure.unavailable }
        let envelope = try Self.envelope(data)
        let next = try JSONDecoder().decode(ModelTrustRoot.self, from: envelope.payload)
        try Self.validateRoot(next)
        guard next.version == current.version + 1 else { throw Failure.rollback }
        try Self.verify(envelope, root: current, role: "root")
        try Self.verify(envelope, root: next, role: "root")
        // 最终根有效期在 acceptCatalog 检查；允许经已过期中间根完成合法轮换。
        let updated = roots + [envelope]
        try persist(State(roots: updated, catalog: nil, revokedHashes: revokedHashes.sorted()))
        roots = updated; root = next; catalog = nil; catalogEnvelope = nil
    }

    @discardableResult public func acceptCatalog(_ data: Data) throws -> ASRModelReleaseIndex {
        lock.lock(); defer { lock.unlock() }
        guard let root else { throw Failure.unavailable }
        let envelope = try Self.envelope(data)
        let next = try Self.catalog(envelope, root: root, checkTime: true)
        try checkBaselineFloor(next, envelope: envelope)
        if let catalog, catalog.rootVersion == next.rootVersion {
            guard next.catalogVersion >= catalog.catalogVersion else { throw Failure.rollback }
            if next.catalogVersion == catalog.catalogVersion, catalogEnvelope?.payload != envelope.payload {
                throw Failure.rollback
            }
        }
        let revoked = revokedHashes.union(next.revokedHashes)
        try persist(State(roots: roots, catalog: envelope, revokedHashes: revoked.sorted()))
        catalog = next; catalogEnvelope = envelope
        revokedHashes = revoked
        return next.index
    }

    private func checkBaselineFloor(_ value: SignedModelCatalog, envelope: SignedModelEnvelope) throws {
        guard let floor = baselineFloor else { return }
        guard value.rootVersion >= floor.root else { throw Failure.rollback }
        if value.rootVersion == floor.root {
            guard value.catalogVersion >= floor.catalog else { throw Failure.rollback }
            if value.catalogVersion == floor.catalog {
                let digest = SHA256.hash(data: envelope.payload).map { String(format: "%02x", $0) }.joined()
                guard digest == floor.digest else { throw Failure.rollback }
            }
        }
    }

    public func isAuthorized(_ release: ASRModelRelease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return authorizedBaseURL(release) != nil
    }

    public func baseURL(for release: ASRModelRelease) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return authorizedBaseURL(release)
    }

    public func isRevoked(_ packageSHA256: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return revokedHashes.contains(packageSHA256.lowercased())
    }

    /// 调用者已持锁。地址与包描述来自同一授权，UI 不能另塞一个 baseURL。
    private func authorizedBaseURL(_ release: ASRModelRelease) -> URL? {
        guard release.isPublished else { return nil }
        if revokedHashes.contains(release.sha256.lowercased()) { return nil }
        if let catalog, let expiry = Self.date(catalog.expiresAt), expiry > Date(),
           let root, let rootExpiry = Self.date(root.expiresAt), rootExpiry > Date(),
           catalog.index.models.contains(release) { return URL(string: root.assetBaseURL) }
        // 完整描述相等：不能只核 SHA 却信任网络自报 minAppVersion/预算/地址。
        guard baselineIndex?.models.contains(release) == true else { return nil }
        return baselineIndex?.baseUrl.flatMap(URL.init(string:))
    }

    private func persist(_ state: State) throws {
        guard let stateURL else { return }
        let parent = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var directory = parent
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let data = try JSONEncoder().encode(state)
        guard data.count <= ModelResourcePolicy.metadataBytes else { throw Failure.invalidMetadata }
        try data.write(to: stateURL, options: .atomic)
    }

    private static func read(_ url: URL) -> Data? {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= ModelResourcePolicy.metadataBytes else { return nil }
            return try Data(contentsOf: url)
        } catch { return nil }
    }
    private static func envelope(_ data: Data) throws -> SignedModelEnvelope {
        guard data.count <= ModelResourcePolicy.metadataBytes else { throw Failure.invalidMetadata }
        let result = try JSONDecoder().decode(SignedModelEnvelope.self, from: data)
        guard !result.payload.isEmpty, result.payload.count <= ModelResourcePolicy.metadataBytes,
              (1...16).contains(result.signatures.count) else { throw Failure.invalidMetadata }
        return result
    }
    private static func date(_ value: String) -> Date? {
        guard value.count == 20, value.hasSuffix("Z") else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
    private static func validateRoot(_ value: ModelTrustRoot) throws {
        guard value.schemaVersion == 1, value.role == "root", value.app == "vitaliber", value.assetKind == "asr",
              value.version > 0, value.version < Int.max, date(value.expiresAt) != nil,
              (1...16).contains(value.keys.count), Set(value.keys.map(\.id)).count == value.keys.count,
              Set(value.rootKeyIDs).isDisjoint(with: value.catalogKeyIDs),
              let base = URL(string: value.assetBaseURL), base.scheme == "https", base.host == "github.com",
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              base.path.hasSuffix("/releases/download/asr-models"),
              !value.allowedHosts.isEmpty, Set(value.allowedHosts).isSubset(of: ModelResourcePolicy.allowedHosts) else {
            throw Failure.invalidMetadata
        }
        let ids = Set(value.keys.map(\.id))
        for (keys, threshold) in [(value.rootKeyIDs, value.rootThreshold), (value.catalogKeyIDs, value.catalogThreshold)] {
            guard threshold > 0, threshold <= keys.count, Set(keys).count == keys.count,
                  Set(keys).isSubset(of: ids) else { throw Failure.invalidMetadata }
        }
        for key in value.keys {
            let digest = SHA256.hash(data: key.publicKey).map { String(format: "%02x", $0) }.joined()
            guard key.publicKey.count == 32, digest == key.id else { throw Failure.invalidMetadata }
        }
    }
    private static func verify(_ envelope: SignedModelEnvelope, root: ModelTrustRoot, role: String) throws {
        guard (1...16).contains(envelope.signatures.count), envelope.payload.count <= ModelResourcePolicy.metadataBytes else { throw Failure.invalidMetadata }
        let allowed = Set(role == "root" ? root.rootKeyIDs : root.catalogKeyIDs)
        let threshold = role == "root" ? root.rootThreshold : root.catalogThreshold
        var seen = Set<String>(), accepted = Set<String>()
        for signature in envelope.signatures {
            guard seen.insert(signature.keyId).inserted else { throw Failure.invalidSignature }
            guard allowed.contains(signature.keyId), let key = root.keys.first(where: { $0.id == signature.keyId }) else { continue }
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey)
            if signature.signature.count == 64, publicKey.isValidSignature(signature.signature, for: envelope.payload) {
                accepted.insert(signature.keyId)
            }
        }
        guard accepted.count >= threshold else { throw Failure.invalidSignature }
    }
    private static func catalog(_ envelope: SignedModelEnvelope, root: ModelTrustRoot, checkTime: Bool) throws -> SignedModelCatalog {
        try verify(envelope, root: root, role: "catalog")
        let value = try JSONDecoder().decode(SignedModelCatalog.self, from: envelope.payload)
        guard value.schemaVersion == 1, value.role == "catalog", value.app == "vitaliber", value.assetKind == "asr",
              value.rootVersion == root.version, value.catalogVersion > 0,
              let issued = date(value.issuedAt), let expiry = date(value.expiresAt), let rootExpiry = date(root.expiresAt),
              expiry > issued, expiry.timeIntervalSince(issued) <= 31 * 86400,
              value.index.isSupported, value.index.baseUrl == root.assetBaseURL,
              (1...128).contains(value.index.models.count), value.revokedHashes.count <= 128,
              value.revokedHashes.allSatisfy(ModelResourcePolicy.isSHA256) else { throw Failure.invalidMetadata }
        if checkTime {
            let now = Date()
            guard expiry > now, rootExpiry > now, issued <= now.addingTimeInterval(300) else { throw Failure.expired }
        }
        var identities = Set<String>()
        for model in value.index.models {
            guard model.isPublished, model.packaging == "zip", model.runtime.map(ModelResourcePolicy.isSlug) == true,
                  let expanded = model.expandedBytes, expanded > 0, expanded <= ModelResourcePolicy.expandedBytes,
                  let minimum = model.minAppVersion, minimum.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
                  model.resolvedURL(baseURL: URL(string: root.assetBaseURL)) != nil,
                  !value.revokedHashes.contains(model.sha256.lowercased()),
                  identities.insert("\(model.id)/\(model.version)/\(model.artifactRevision ?? 0)").inserted else { throw Failure.invalidMetadata }
        }
        return value
    }
}
#endif
