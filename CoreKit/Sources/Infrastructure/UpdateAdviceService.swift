#if os(iOS) || os(macOS)
// linux-blind: URLSession/Vision/ZIPFoundation 通告链 —— Linux 编译空单元，行为须经 macOS CI 验证。
import Foundation
import Domain
import ZIPFoundation

/// 通告读取结果：R2.1 封闭集映射到各域行（`payloadVersion/generatedAt` 仅用于
/// 「未校验 · 载荷时间」标注，R2.7/R2.8——绝不产出数量或「已最新」结论）。
public struct UpdateAdviceOutcome: Sendable, Equatable {
    public let rows: [UpdateAdviceDomain: UpdateAdviceRowState]
    public let payloadVersion: Int?
    public let generatedAt: String?

    public init(rows: [UpdateAdviceDomain: UpdateAdviceRowState],
                payloadVersion: Int? = nil, generatedAt: String? = nil) {
        self.rows = rows
        self.payloadVersion = payloadVersion
        self.generatedAt = generatedAt
    }

    public static func unavailable() -> UpdateAdviceOutcome {
        var rows: [UpdateAdviceDomain: UpdateAdviceRowState] = [:]
        for domain in UpdateAdviceDomain.allCases { rows[domain] = .unavailable }
        return UpdateAdviceOutcome(rows: rows)
    }
}

/// SP-64 通告面读取端口（README VL-INDEX 二维码；仅显式用户动作触发，零隐式联网 R2.6）。
public protocol UpdateAdviceProviding: Sendable {
    func read() async -> UpdateAdviceOutcome
}

/// 读取实现：固定 PNG URL → 有界拉取（逐跳主机门）→ Vision 双路径解码 →
/// 信封解密（ASR 域同密钥，identity=`update-payload-<64hex>`）→ 单 entry ZIP →
/// sha256 回验 → floor → 行态。
///
/// **任何失败归约 `.unavailable`**：载荷是提示面，域链（签名目录/信任根）不受
/// 任何影响（R2.5/R2.6）；读取中的并发请求单飞（同 MedicalCatalogReleaseResolver 先例）。
public actor UpdateAdviceService: UpdateAdviceProviding {
    private static let payloadEntryName = "payload.json"
    private static let maxPlaintextBytes = 1 << 20

    private let floorStore: UpdateAdviceFloorStore?
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var isReading = false

    public init(floorStore: UpdateAdviceFloorStore?, session: URLSession? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.floorStore = floorStore
        self.now = now
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: configuration)
        }
    }

    public func read() async -> UpdateAdviceOutcome {
        guard !isReading else { return .unavailable() }
        isReading = true
        defer { isReading = false }
        do {
            let png = try await fetchPNG()
            let payloadBytes = try UpdatePayloadQRDecoder.payloadBytes(fromPNGData: png)
            let identity = try Self.identity(from: payloadBytes)
            let envelope = Data(payloadBytes.dropFirst(UpdateAdvicePayloadContract.identityPrefixLength))
            let plaintext = try Self.decrypt(envelope: envelope, identity: identity)
            let payloadJSON = try Self.unzipPayload(from: plaintext)
            guard CryptoKitContentHasher().sha256Hex(payloadJSON) == String(identity.suffix(64)) else {
                return .unavailable()
            }
            let payload: UpdateAdvicePayload
            do {
                payload = try JSONDecoder().decode(UpdateAdvicePayload.self, from: payloadJSON)
            } catch {
                return .unavailable()
            }
            guard payload.schemaVersion == UpdateAdvicePayloadContract.schemaVersion,
                  payload.payloadVersion > 0 else {
                return .unavailable()
            }
            return settledOutcome(payload: payload, identityHex: String(identity.suffix(64)))
        } catch {
            return .unavailable()
        }
    }

    // MARK: - 链

    private func fetchPNG() async throws -> Data {
        var request = URLRequest(url: UpdateAdvicePayloadContract.pngURL)
        request.setValue("image/png", forHTTPHeaderField: "Accept")
        let delegate = MedicalCatalogBoundedDataDelegate(
            maxBytes: UpdateAdvicePayloadContract.maxPNGBytes,
            allowsURL: { ASRModelReleaseProtocol.allowsTransferURL($0) })
        let (tupleBody, response) = try await session.data(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = response.url, ASRModelReleaseProtocol.allowsTransferURL(finalURL) else {
            throw UpdatePayloadQRDecoder.Failure.noCode
        }
        let body = delegate.accumulated.isEmpty ? tupleBody : delegate.accumulated
        guard body.count >= 8, body.count <= UpdateAdvicePayloadContract.maxPNGBytes else {
            throw UpdatePayloadQRDecoder.Failure.noCode
        }
        return body
    }

    /// 79B 前缀 → 完整 identity（`update-payload-<64hex>`）；非法 = 抛错。
    private static func identity(from payloadBytes: Data) throws -> String {
        guard let identity = UpdateAdvicePayloadContract.identity(
            fromPrefix: payloadBytes.prefix(UpdateAdvicePayloadContract.identityPrefixLength)) else {
            throw UpdatePayloadQRDecoder.Failure.malformed
        }
        return identity
    }

    private static func decrypt(envelope: Data, identity: String) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-advice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) } // try?-ok: 临时件清理
        let envelopeURL = directory.appendingPathComponent("envelope.bin")
        let plaintextURL = directory.appendingPathComponent("payload.zip")
        try envelope.write(to: envelopeURL)
        try ASRPackageCrypto.decryptUpdatePayloadEnvelope(at: envelopeURL, to: plaintextURL,
                                                          identity: identity)
        return try Data(contentsOf: plaintextURL)
    }

    /// 单 entry ZIP（严格）：恰一个 `payload.json`，尺寸有界；其余形状 = 抛错。
    private static func unzipPayload(from archiveData: Data) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-advice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) } // try?-ok: 临时件清理
        let archiveURL = directory.appendingPathComponent("payload.zip")
        try archiveData.write(to: archiveURL)
        let archive = try Archive(url: archiveURL, accessMode: .read, pathEncoding: nil)
        var entry: Entry?
        for candidate in archive.makeIterator() {
            guard entry == nil, candidate.path == payloadEntryName,
                  candidate.uncompressedSize > 0,
                  candidate.uncompressedSize <= UInt64(maxPlaintextBytes) else {
                throw UpdatePayloadQRDecoder.Failure.malformed
            }
            entry = candidate
        }
        guard let payloadEntry = entry else { throw UpdatePayloadQRDecoder.Failure.malformed }
        var out = Data()
        _ = try archive.extract(payloadEntry) { chunk in out.append(chunk) }
        guard out.count <= maxPlaintextBytes, out.count == Int(payloadEntry.uncompressedSize) else {
            throw UpdatePayloadQRDecoder.Failure.malformed
        }
        return out
    }

    // MARK: - floor → 行态

    private func settledOutcome(payload: UpdateAdvicePayload, identityHex: String) -> UpdateAdviceOutcome {
        var baseline: UpdateAdviceRowState?
        if let floorStore {
            let observed = floorStore.observedFloor
            if let state = UpdateAdviceFloorRules.baselineState(
                observedVersion: payload.payloadVersion, observedIdentity: identityHex,
                floorVersion: observed?.payloadVersion, floorIdentity: observed?.identityHex) {
                baseline = state
            } else {
                do {
                    try floorStore.accept(payloadVersion: payload.payloadVersion, identityHex: identityHex)
                } catch UpdateAdviceFloorStore.Failure.rollback {
                    baseline = .stale
                } catch {
                    baseline = .unavailable // equivocation / invalidState
                }
            }
        }
        var rows: [UpdateAdviceDomain: UpdateAdviceRowState] = [:]
        for domain in UpdateAdviceDomain.allCases {
            if let baseline {
                rows[domain] = baseline
            } else {
                rows[domain] = payload.releases.contains { $0.tag == domain.rawValue }
                    ? .announced : .notMentioned
            }
        }
        return UpdateAdviceOutcome(rows: rows, payloadVersion: payload.payloadVersion,
                                   generatedAt: payload.generatedAt)
    }
}
#endif
