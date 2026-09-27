import Foundation
import Protocols
import Domain

/// 检查结果：Domain 状态 + 仅在 `updateAvailable` 时携带完整验签候选
/// （安装链路的唯一入口类型——调用方无法自行构造，只能由 resolver 验签后产出）。
public struct MedicalCatalogCheckOutcome: Sendable, Equatable {
    public let state: MedicalCatalogRemoteState
    public let candidate: VerifiedMedicalCatalogCandidate?

    public init(state: MedicalCatalogRemoteState, candidate: VerifiedMedicalCatalogCandidate? = nil) {
        self.state = state
        self.candidate = candidate
    }
}

/// 医疗目录手动检查端口（SP-64 / tech-spec §5.53）：只读 GitHub public Release
/// inventory 与被选中的小 pointer，绝不下载 `.bin` 包体；请求不携带任何凭据。
/// 唯一可抛错误 = CancellationError（任务取消）；其余失败全部归约进 outcome 状态。
public protocol MedicalCatalogReleaseResolving: Sendable {
    func check() async throws -> MedicalCatalogCheckOutcome
}

/// 检查链模块内错误：调用面以 `MedicalCatalogRemoteState` 表达结果，不外泄传输细节。
/// 2026-09-27 评审修复：`tooLarge` 曾挪作非尺寸语义（终点主机越界/inventory 畸形），
/// 错误词汇失真会误导调试与未来 UI 细分——按 throw 现场语义拆分。
enum MedicalCatalogResolveError: Error, Equatable {
    /// 响应体超过声明上限（inventory 4 MB / pointer 2 MB），传输已中止。
    case tooLarge
    /// 终点/资产 URL 不在检查面主机门内（scheme/host/端口/userinfo 任一不符）。
    case hostMismatch
    /// inventory JSON 形状/资产表畸形（fail-closed，不猜测部分解析）。
    case malformedInventory
}

/// SP-64 检查实现（tech-spec §5.53）：
/// 1. GET 固定 public Release inventory（ETag 配对、有界读取、逐跳主机门）；
/// 2. 资产表里选**最高** `installable` pointer（progress 永不进入候选）；
/// 3. 只下载被选中的小 pointer（≤2 MB），pinned root 验签后才构造候选；
/// 4. 反回退 floor（`MedicalCatalogTrustStore`）：验签通过即推进，更低版本/同版本异
///    摘要就地拒绝——「metadata 信任地板」与安装结果无关（TrustStore 契约）；
/// 5. 与本机 `(schemaVersion,dataVersion)` 比较：一致 → upToDate，否则 updateAvailable。
///
/// pinned root 缺失（发布配置尚未 provisioning）时 fail-closed **不联网**——
/// 未配置≠网络错误，UI 呈「暂不可用」；检查永不自动重试限流（§5.53 限流纪律）。
public actor MedicalCatalogReleaseResolver: MedicalCatalogReleaseResolving {
    /// 检查面固定地址（GitHub public API；无 Authorization/cookie/令牌）。
    public static let inventoryURL = URL(string: "https://api.github.com/repos/"
        + MedicalCatalogReleaseProtocol.repository + "/releases/tags/"
        + MedicalCatalogReleaseProtocol.releaseTag)!
    /// inventory 上界（覆盖 1000 资产上限内的 Release 元数据）。
    static let maxInventoryBytes = 4 << 20
    /// 检查面允许的逐跳/终点主机 = 下载面三主机 + API 主机。
    static let checkAllowedHosts = MedicalCatalogReleaseProtocol.allowedHosts.union(["api.github.com"])

    /// 检查面 URL 门（2026-09-27 评审修复）：此前三个检查点只查 host，弱于下载面
    /// `allowsTransferURL`（scheme/https/无 userinfo/端口 443 全查）——被篡改的
    /// inventory（本身不签名）可指向 `http://github.com/...` 造成明文请求面。
    /// 与下载面同一强度逐项镜像，ATS 例外场景下依然 fail-closed。
    static func allowsCheckURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return checkAllowedHosts.contains(host)
    }

    private let pinnedRootJSON: Data?
    private let verifier: (any MedicalCatalogTrustVerifying)?
    private let hasher: any ContentHashing
    private let session: URLSession
    private let etagCache: MedicalCatalogETagCache
    private let trust: MedicalCatalogTrustStore?
    private let localVersion: @Sendable () -> MedicalCatalogInstalledVersion?
    private let now: @Sendable () -> Date
    private var isChecking = false

    /// `makeVerifier` 是「verifier 必须由 pinned root 派生」的类型层保证
    /// （2026-09-27 评审修复）：此前 root 数据与 verifier 独立注入，调用方可传错配、
    /// root 数据退化为 nil 哨兵——安全性依赖「生产只有一处构造且同源」的人证。
    /// 现在 resolver 从自己的 root 派生验签器，错配不可表达；测试注入确定性时钟
    /// 也走同一工厂形态（`{ root in CryptoKitMedicalCatalogTrustVerifier(pinnedRootJSON: root, now: ...) }`）。
    public init(pinnedRootJSON: Data?,
                makeVerifier: ((Data) -> any MedicalCatalogTrustVerifying)?,
                hasher: any ContentHashing,
                session: URLSession? = nil,
                etagCache: MedicalCatalogETagCache = MedicalCatalogETagCache(),
                trust: MedicalCatalogTrustStore? = nil,
                localVersion: @escaping @Sendable () -> MedicalCatalogInstalledVersion? = { nil },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.pinnedRootJSON = pinnedRootJSON
        self.verifier = pinnedRootJSON.flatMap { root in makeVerifier?(root) }
        self.hasher = hasher
        self.etagCache = etagCache
        self.trust = trust
        self.localVersion = localVersion
        self.now = now
        if let session {
            self.session = session
        } else {
            // 检查面专有会话：无 cookie/凭据存储、禁用 URLCache（GitHub 响应
            // max-age=60 会让「检查」在 60 秒内被内存缓存应答而非真正联网，
            // 2026-09-27 评审修复）、显式短超时——inventory+pointer 都是小响应，
            // 慢即失败（不设 waitsForConnectivity：检查是用户主动短操作）。
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 60
            self.session = URLSession(configuration: configuration)
        }
    }

    /// 单飞：并发检查请求返回 `checking` 信号，不发起第二条网络链。
    /// 唯一可抛 = CancellationError（调用方取消）；其余失败归约进 outcome。
    public func check() async throws -> MedicalCatalogCheckOutcome {
        guard !isChecking else { return MedicalCatalogCheckOutcome(state: .checking) }
        isChecking = true
        defer { isChecking = false }
        guard pinnedRootJSON != nil, verifier != nil else {
            return MedicalCatalogCheckOutcome(state: .unavailable)
        }
        do {
            try Task.checkCancellation()
            let inventory = try await fetch(Self.inventoryURL, maxBytes: Self.maxInventoryBytes, etag: true)
            try Task.checkCancellation()
            if let failure = Self.failureOutcome(inventory) { return failure }
            guard let inventoryBody = inventory.body else {
                return MedicalCatalogCheckOutcome(state: .verificationFailed)
            }
            let selection = try parseInventory(inventoryBody)
            try Task.checkCancellation()
            guard let pointer = selection.highestInstallable else {
                // 无 installable pointer（仅 progress/无 pointer）：不误报「最新」，
                // 也不把 progress 呈现为更新（§5.53 / ui-ux 5.12.4）。
                return MedicalCatalogCheckOutcome(state: .noInstallableAvailable)
            }
            let pointerResult = try await fetch(pointer.url,
                                                maxBytes: MedicalCatalogReleaseProtocol.maxEnvelopeBytes,
                                                etag: true)
            try Task.checkCancellation()
            // pointer 侧 404/410 = 发布方 inventory 与资产不一致（inventory 200 但
            // 资产缺失），归 verificationFailed 而非「尚未发布」（2026-09-27 评审修复：
            // 共用归约表会让资产缺失被呈现为「暂不可用·未发布」，误导用户等待）。
            if let failure = Self.failureOutcome(pointerResult, pointerAsset: true) { return failure }
            guard let pointerBody = pointerResult.body else {
                return MedicalCatalogCheckOutcome(state: .verificationFailed)
            }
            let expectation = try MedicalCatalogSignedPointerDecoder.expectation(
                catalogJSON: pointerBody, servedAs: pointer.name, now: now(), hasher: hasher)
            try verifier!.verify(catalogJSON: pointerBody, expected: expectation)
            // installable 断言收进 resolver 本地（2026-09-27 评审修复）：不依赖
            // TrustStore 注入在场——`installable-<N>` 资产名下 `installable=false`
            // 内容在此就地拒绝，updater 入口的 guard 仍是第二道。
            guard expectation.installable else {
                return MedicalCatalogCheckOutcome(state: .noInstallableAvailable)
            }
            let candidate = VerifiedMedicalCatalogCandidate(verified: expectation)

            if let trust {
                do {
                    try trust.accept(candidate)
                } catch MedicalCatalogTrustStore.Failure.rollback {
                    // 已见更高版本后被发布方回退：与本机数据一致 → upToDate；
                    // 否则无可安装更新（回退版本被拒，不呈现会被 floor 拒绝的按钮）。
                    return MedicalCatalogCheckOutcome(
                        state: Self.sameData(local: localVersion(), candidate: candidate)
                            ? .upToDate : .noInstallableAvailable)
                } catch {
                    // equivocation（同版本异摘要）/ invalidState：发布方或传输层不可信。
                    return MedicalCatalogCheckOutcome(state: .verificationFailed)
                }
            }
            if Self.sameData(local: localVersion(), candidate: candidate) {
                return MedicalCatalogCheckOutcome(state: .upToDate)
            }
            return MedicalCatalogCheckOutcome(
                state: .updateAvailable(MedicalCatalogUpdateCandidate(
                    catalogVersion: candidate.catalogVersion, dataVersion: candidate.dataVersion,
                    schemaVersion: candidate.schemaVersion, packageSize: candidate.packageSize,
                    expiresAt: candidate.expiresAt)),
                candidate: candidate)
        } catch is CancellationError {
            throw CancellationError()
        } catch is URLError {
            return MedicalCatalogCheckOutcome(state: .networkUnavailable)
        } catch {
            return MedicalCatalogCheckOutcome(state: .verificationFailed)
        }
    }

    private static func sameData(local: MedicalCatalogInstalledVersion?,
                                 candidate: VerifiedMedicalCatalogCandidate) -> Bool {
        guard let local else { return false }
        return MedicalCatalogUpdateService.sameDataVersion(local: local, candidate: candidate)
    }

    /// 把 fetch 的 HTTP 非 2xx/304 结果归约为 Domain 状态（nil = 有可用响应体继续处理）：
    /// 403/429 → rateLimited；404/410 → unavailable；5xx → networkUnavailable；
    /// 其余非 2xx → verificationFailed。`pointerAsset: true` 时 404/410 归
    /// verificationFailed（inventory 已 200 而资产缺失 = 发布方不一致，非「未发布」）。
    private static func failureOutcome(_ result: FetchResult, pointerAsset: Bool = false) -> MedicalCatalogCheckOutcome? {
        switch result.status {
        case 200, 304: return nil
        case 403, 429: return MedicalCatalogCheckOutcome(state: .rateLimited(retryAfter: result.retryAfter))
        case 404, 410: return MedicalCatalogCheckOutcome(
            state: pointerAsset ? .verificationFailed : .unavailable)
        case 500...599: return MedicalCatalogCheckOutcome(state: .networkUnavailable)
        default: return MedicalCatalogCheckOutcome(state: .verificationFailed)
        }
    }

    // MARK: - Transport

    private struct FetchResult {
        let status: Int
        let body: Data?
        let retryAfter: Date?
    }

    private func fetch(_ url: URL, maxBytes: Int, etag: Bool) async throws -> FetchResult {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if etag, let cached = etagCache.entry(for: url) {
            request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }
        let delegate = MedicalCatalogBoundedDataDelegate(maxBytes: maxBytes,
                                                         allowsURL: { Self.allowsCheckURL($0) })
        do {
            let (_, response) = try await session.data(for: request, delegate: delegate)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  let finalURL = response.url, Self.allowsCheckURL(finalURL)
            else {
                throw MedicalCatalogResolveError.hostMismatch
            }
            switch http.statusCode {
            case 200:
                let body = delegate.accumulated
                if let cachedETag = http.value(forHTTPHeaderField: "ETag"), !cachedETag.isEmpty {
                    etagCache.store(etag: cachedETag, body: body, for: url, limit: maxBytes)
                }
                return FetchResult(status: 200, body: body, retryAfter: nil)
            case 304:
                if let cached = etagCache.entry(for: url) {
                    return FetchResult(status: 304, body: cached.body, retryAfter: nil)
                }
                // 304 无缓存：最多一次无条件重试（§5.53）；无条件重试仍 304 =
                // 服务器状态自相矛盾，fail-closed（etag=false 时不再递归）。
                guard etag else { return FetchResult(status: 304, body: nil, retryAfter: nil) }
                return try await fetch(url, maxBytes: maxBytes, etag: false)
            default:
                return FetchResult(status: http.statusCode,
                                   body: nil,
                                   retryAfter: Self.retryAfter(from: http, now: now()))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MedicalCatalogResolveError {
            throw error
        } catch let error as URLError {
            // 任务取消在 URLSession 层表现为 URLError(.cancelled)——还原为
            // CancellationError 让调用面（取消回 idle）拿到统一取消语义。
            if Task.isCancelled { throw CancellationError() }
            if delegate.exceeded { throw MedicalCatalogResolveError.tooLarge }
            throw error
        }
    }

    /// Retry-After（整数秒）优先；x-ratelimit-reset（epoch 秒）兜底。
    /// （GitHub public API 只发整数秒 Retry-After 与 x-ratelimit-reset，HTTP 日期形态
    /// 不在契约内——2026-09-27 评审对齐注释与实现。）
    private static func retryAfter(from response: HTTPURLResponse, now: Date) -> Date? {
        if let value = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = Int64(value), seconds > 0 {
                return now.addingTimeInterval(TimeInterval(seconds))
            }
        }
        if let value = response.value(forHTTPHeaderField: "x-ratelimit-reset"),
           let epoch = TimeInterval(value), epoch > now.timeIntervalSince1970 {
            return Date(timeIntervalSince1970: epoch)
        }
        return nil
    }

    // MARK: - Inventory

    private struct PointerRef {
        let name: String
        let url: URL
        let catalogVersion: Int64
    }

    private func parseInventory(_ data: Data) throws -> (highestInstallable: PointerRef?) {
        guard data.count <= Self.maxInventoryBytes else { throw MedicalCatalogResolveError.tooLarge }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = object["assets"] as? [Any] else {
            throw MedicalCatalogResolveError.malformedInventory
        }
        var highest: PointerRef?
        for asset in assets {
            guard let entry = asset as? [String: Any],
                  let name = entry["name"] as? String,
                  let rawURL = entry["browser_download_url"] as? String,
                  let url = URL(string: rawURL), Self.allowsCheckURL(url),
                  let version = Self.installablePointerVersion(name) else { continue }
            if highest == nil || version > highest!.catalogVersion {
                highest = PointerRef(name: name, url: url, catalogVersion: version)
            }
        }
        return (highestInstallable: highest)
    }

    /// 只认 `medical-data-catalog-installable-<正整数>.json` 文法；
    /// progress / 其它命名一律返回 nil（不进入候选）。
    private static func installablePointerVersion(_ name: String) -> Int64? {
        let prefix = "medical-data-catalog-installable-"
        let suffix = ".json"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let body = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard !body.isEmpty, body.allSatisfy(\.isNumber), let version = Int64(body), version > 0 else { return nil }
        return version
    }
}

// MARK: - Bounded transport delegate

/// 检查面数据委托：逐跳 URL 门（限 5 跳，`allowsCheckURL` 全项校验）+ 硬字节上限
/// （超限即 cancel——4 MB inventory 上限足以覆盖 1000 资产）。
final class MedicalCatalogBoundedDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maxRedirects = 5
    private let maxBytes: Int
    private let allowsURL: @Sendable (URL) -> Bool
    private let lock = NSLock()
    private var data = Data()
    private var tooLarge = false
    private var redirects = 0

    init(maxBytes: Int, allowsURL: @escaping @Sendable (URL) -> Bool) {
        self.maxBytes = maxBytes
        self.allowsURL = allowsURL
    }

    var accumulated: Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }

    var exceeded: Bool {
        lock.lock(); defer { lock.unlock() }
        return tooLarge
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !tooLarge else { lock.unlock(); return }
        self.data.append(data)
        if self.data.count > maxBytes {
            tooLarge = true
            dataTask.cancel()
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock(); redirects += 1; let count = redirects; lock.unlock()
        guard count <= Self.maxRedirects, let url = request.url, allowsURL(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

// MARK: - ETag cache

/// 按 exact URL 配对的 ETag/body 缓存（§5.53）：304 只复用匹配的缓存体并重验签名
/// 与时间窗；304 无缓存时最多一次无条件重试。有界（单条受各 URL 上限约束、总量
/// 受 `maxTotalBytes` 约束）、会话内有效；ETag 只是缓存提示，不是信任信号。
public final class MedicalCatalogETagCache: @unchecked Sendable {
    public static let maxTotalBytes = 8 << 20

    private struct Entry: Sendable {
        let etag: String
        let body: Data
    }

    private let maxTotalBytes: Int
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var totalBytes = 0

    public init(maxTotalBytes: Int = MedicalCatalogETagCache.maxTotalBytes) {
        self.maxTotalBytes = maxTotalBytes
    }

    public func entry(for url: URL) -> (etag: String, body: Data)? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[url.absoluteString] else { return nil }
        return (entry.etag, entry.body)
    }

    /// 单条/总量超限时拒绝（不驱逐旧条目：已缓存 URL 的 304 语义优先稳定）。
    /// 2026-09-27 评审修复：原实现先扣旧条目再判总量、超限时把可用的旧缓存也置 nil——
    /// 与「304 语义优先稳定」自陈矛盾，且丢旧后下次检查退化为全量 200、多烧一次
    /// 未认证额度。现在超限保留旧条目，不做部分替换。
    public func store(etag: String, body: Data, for url: URL, limit: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !etag.isEmpty, body.count <= limit, body.count <= maxTotalBytes else { return }
        let key = url.absoluteString
        if let old = entries[key] {
            guard totalBytes - old.body.count + body.count <= maxTotalBytes else { return }
            totalBytes += body.count - old.body.count
        } else {
            guard totalBytes + body.count <= maxTotalBytes else { return }
            totalBytes += body.count
        }
        entries[key] = Entry(etag: etag, body: body)
    }
}
