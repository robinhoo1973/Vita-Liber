#if os(iOS) || os(macOS)
// linux-blind: URLSession 传输语义不在 Linux 真跑——Linux 型检编译空单元，改动须经 macOS CI 验证
import Domain
import Foundation

/// 切片清单验签端口：生产 = CryptoKit evaluator 派生（同 v4「verifier 必须由
/// pinned root 派生」的类型层保证）；测试注入确定性桩。
public protocol CatalogSliceTrustVerifying: Sendable {
    func verifySlice(manifestJSON: Data, kind: CatalogSliceKind, servedAs: String) throws
        -> VerifiedCatalogSliceCandidate
}

/// 切片手动检查端口（SP-64 / FR25.13）：一次显式检查扇出三片 manifest（各为
/// ≤2 MB 签名信封，绝不下载 `.bin`），逐片验签/floor/minApp 门后给出每片状态。
/// 唯一可抛 = CancellationError（调用方取消）；其余失败全部归约进 outcome。
/// 零隐式联网：只由用户显式点击触发（ADR-030）。
public protocol CatalogSliceReleaseResolving: Sendable {
    func check() async throws -> CatalogSliceCheckEnvelope
}

/// 检查信封：Domain 呈现面 + **仅在 updateAvailable 时**携带的密封候选
/// （安装链唯一入口类型——调用方无法自行构造，同 v4 `MedicalCatalogCheckOutcome` 纪律）。
public struct CatalogSliceCheckEnvelope: Sendable {
    public let outcome: CatalogSliceCheckOutcome
    private let verified: [CatalogSliceKind: VerifiedCatalogSliceCandidate]

    public init(outcome: CatalogSliceCheckOutcome,
                verified: [CatalogSliceKind: VerifiedCatalogSliceCandidate]) {
        self.outcome = outcome
        self.verified = verified
    }

    public func candidate(_ kind: CatalogSliceKind) -> VerifiedCatalogSliceCandidate? {
        verified[kind]
    }
}

/// 检查链模块内错误（调用面只见 Domain 状态，不泄漏传输细节）。
enum CatalogSliceResolveError: Error, Equatable {
    /// 响应体超过声明上限（manifest 信封 2 MiB），传输已中止。
    case tooLarge
    /// 终点/资产 URL 不在检查面主机门内（scheme/host/端口/userinfo 任一不符）。
    case hostMismatch
}

/// 三切片检查实现（2026-10-28 切片-only）：
/// 1. 每片 GET 固定名清单 `<stem>.json`（地址由 `CatalogSliceProtocol` 常量拼出，
///    不采信任何网络给出的 URL；ETag 配对、有界读取、逐跳主机门）；
/// 2. pinned root 2-of-2 验签 + 22 键严格解码（`verifySlice`）；
/// 3. 每片独立 trust floor（内容身份 = sqliteSha256）：验签通过即推进，
///    低版本/同版异内容就地拒绝；绝不读 v4 floor 文件；
/// 4. minApp 门：`minAppBuild > 当前 build` → `appUpdateRequired`（floor 仍推进）；
/// 5. 与本机回执比较（catalogVersion + sqliteSha256 双一致 → upToDate）。
///
/// pinned root 缺失（未 provisioning）时 fail-closed **不联网**。
public actor CatalogSliceReleaseResolver: CatalogSliceReleaseResolving {
    private let pinnedRootJSON: Data?
    private let verifier: (any CatalogSliceTrustVerifying)?
    private let session: URLSession
    private let etagCache: MedicalCatalogETagCache
    private let trust: CatalogSliceTrust?
    private let localReceipt: @Sendable (CatalogSliceKind) -> CatalogSliceReceipt?
    private let currentBuild: @Sendable () -> Int64
    private let now: @Sendable () -> Date
    private var isChecking = false

    public init(pinnedRootJSON: Data?,
                makeVerifier: ((Data) -> any CatalogSliceTrustVerifying)?,
                session: URLSession? = nil,
                etagCache: MedicalCatalogETagCache = MedicalCatalogETagCache(),
                trust: CatalogSliceTrust? = nil,
                localReceipt: @escaping @Sendable (CatalogSliceKind) -> CatalogSliceReceipt? = { _ in nil },
                currentBuild: @escaping @Sendable () -> Int64 = { 0 },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.pinnedRootJSON = pinnedRootJSON
        self.verifier = pinnedRootJSON.flatMap { root in makeVerifier?(root) }
        self.etagCache = etagCache
        self.trust = trust
        self.localReceipt = localReceipt
        self.currentBuild = currentBuild
        self.now = now
        if let session {
            self.session = session
        } else {
            // 检查面专有会话（同 v4 resolver 纪律）：无 cookie/凭据、禁用 URLCache
            // （响应 max-age 会让「检查」被内存缓存应答）、短超时——小响应慢即失败。
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 60
            self.session = URLSession(configuration: configuration)
        }
    }

    /// 单飞：并发检查请求返回 `checking` 信号，不发第二条网络链。
    public func check() async throws -> CatalogSliceCheckEnvelope {
        guard !isChecking else {
            return CatalogSliceCheckEnvelope(outcome: Self.uniform(.checking), verified: [:])
        }
        isChecking = true
        defer { isChecking = false }
        guard pinnedRootJSON != nil, verifier != nil else {
            return CatalogSliceCheckEnvelope(outcome: Self.uniform(.unavailable), verified: [:])
        }
        var results: [CatalogSliceCheckResult] = []
        var verified: [CatalogSliceKind: VerifiedCatalogSliceCandidate] = [:]
        for kind in CatalogSliceKind.allCases {
            try Task.checkCancellation()
            let local = localReceipt(kind)
            let (state, candidate) = await checkOne(kind, local: local)
            if let candidate, case .updateAvailable = state { verified[kind] = candidate }
            results.append(CatalogSliceCheckResult(kind: kind, state: state,
                                                   localCatalogVersion: local?.catalogVersion))
        }
        return CatalogSliceCheckEnvelope(outcome: CatalogSliceCheckOutcome(results: results),
                                         verified: verified)
    }

    // MARK: - per kind

    private func checkOne(_ kind: CatalogSliceKind, local: CatalogSliceReceipt?) async
        -> (CatalogSliceRemoteState, VerifiedCatalogSliceCandidate?) {
        guard let verifier else { return (.unavailable, nil) }
        let result: FetchResult
        do {
            result = try await fetch(CatalogSliceProtocol.manifestURL(kind),
                                     maxBytes: CatalogSliceProtocol.maxEnvelopeBytes,
                                     etag: true, accept: Self.manifestAccept)
        } catch is CancellationError {
            return (.networkUnavailable, nil)
        } catch is URLError {
            return (.networkUnavailable, nil)
        } catch {
            return (.verificationFailed, nil)
        }
        switch result.status {
        case 200, 304:
            break
        case 403, 429:
            return (.rateLimited(retryAfter: result.retryAfter), nil)
        case 404, 410:
            // 源未提供 / 已移除按本机有无副本区分（不删本地、不回落他片）。
            return (local != nil
                ? .removedFromSource(catalogVersion: local?.catalogVersion)
                : .sourceNotProvided, nil)
        case 300...399, 500...599:
            return (.networkUnavailable, nil)
        default:
            return (.verificationFailed, nil)
        }
        guard let body = result.body else { return (.verificationFailed, nil) }
        let candidate: VerifiedCatalogSliceCandidate
        do {
            candidate = try verifier.verifySlice(manifestJSON: body, kind: kind,
                                                 servedAs: kind.manifestAssetName)
        } catch is CancellationError {
            return (.networkUnavailable, nil)
        } catch {
            // 含 unsupportedSliceSchemaVersion/rootVersionOutOfRange/签名不足：fail-closed。
            return (.verificationFailed, nil)
        }
        if let trust {
            do {
                try trust.accept(candidate)
            } catch MedicalCatalogTrustStore.Failure.rollback {
                // 发布方回退：与本机回执完全一致才认 upToDate，否则拒绝呈现更新。
                if local?.catalogVersion == candidate.catalogVersion,
                   local?.sqliteSHA256 == candidate.sqliteSHA256 {
                    return (.upToDate(catalogVersion: candidate.catalogVersion), nil)
                }
                return (.verificationFailed, nil)
            } catch {
                return (.verificationFailed, nil)   // equivocation / invalidState
            }
        }
        if !candidate.isSupported(byAppBuild: currentBuild()) {
            return (.appUpdateRequired(minAppBuild: candidate.minAppBuild,
                                       minAppMarketingVersion: candidate.minAppMarketingVersion), nil)
        }
        if let local, local.catalogVersion == candidate.catalogVersion,
           local.sqliteSHA256 == candidate.sqliteSHA256 {
            return (.upToDate(catalogVersion: candidate.catalogVersion), nil)
        }
        return (.updateAvailable(CatalogSliceCheckCandidate(
            kind: kind, catalogVersion: candidate.catalogVersion,
            packageSize: candidate.packageSize, sqliteSize: candidate.sqliteSize)), candidate)
    }

    private static func uniform(_ state: CatalogSliceRemoteState) -> CatalogSliceCheckOutcome {
        CatalogSliceCheckOutcome(results: CatalogSliceKind.allCases.map {
            CatalogSliceCheckResult(kind: $0, state: state, localCatalogVersion: nil)
        })
    }

    // MARK: - Transport（镜像 v4 检查面纪律；v4 resolver 在 B2 删除后本段成为唯一检查传输）

    private struct FetchResult {
        let status: Int
        let body: Data?
        let retryAfter: Date?
    }

    static let manifestAccept = "application/json"

    private func fetch(_ url: URL, maxBytes: Int, etag: Bool,
                       accept: String) async throws -> FetchResult {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if etag, let cached = etagCache.entry(for: url) {
            request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }
        let delegate = MedicalCatalogBoundedDataDelegate(
            maxBytes: maxBytes, allowsURL: { MedicalCatalogReleaseResolver.allowsCheckURL($0) })
        do {
            let (tupleBody, response) = try await session.data(for: request, delegate: delegate)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  let finalURL = response.url, MedicalCatalogReleaseResolver.allowsCheckURL(finalURL)
            else {
                throw CatalogSliceResolveError.hostMismatch
            }
            switch http.statusCode {
            case 200:
                let body = delegate.accumulated.isEmpty ? tupleBody : delegate.accumulated
                guard body.count <= maxBytes else { throw CatalogSliceResolveError.tooLarge }
                if let cachedETag = http.value(forHTTPHeaderField: "ETag"), !cachedETag.isEmpty {
                    etagCache.store(etag: cachedETag, body: body, for: url, limit: maxBytes)
                }
                return FetchResult(status: 200, body: body, retryAfter: nil)
            case 304:
                if let cached = etagCache.entry(for: url) {
                    return FetchResult(status: 304, body: cached.body, retryAfter: nil)
                }
                guard etag else { return FetchResult(status: 304, body: nil, retryAfter: nil) }
                return try await fetch(url, maxBytes: maxBytes, etag: false, accept: accept)
            default:
                return FetchResult(status: http.statusCode, body: nil,
                                   retryAfter: Self.retryAfter(from: http, now: now()))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CatalogSliceResolveError {
            throw error
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            if delegate.exceeded { throw CatalogSliceResolveError.tooLarge }
            throw error
        }
    }

    /// Retry-After（整数秒）优先；x-ratelimit-reset（epoch 秒）兜底（与 v4 同口径）。
    private static func retryAfter(from response: HTTPURLResponse, now: Date) -> Date? {
        if let value = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Int64(value), seconds > 0 {
            return now.addingTimeInterval(TimeInterval(seconds))
        }
        if let value = response.value(forHTTPHeaderField: "x-ratelimit-reset"),
           let epoch = TimeInterval(value), epoch > now.timeIntervalSince1970 {
            return Date(timeIntervalSince1970: epoch)
        }
        return nil
    }
}
#endif
