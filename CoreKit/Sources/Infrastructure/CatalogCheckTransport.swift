#if os(iOS) || os(macOS)
// linux-blind: URLSession 传输委托与 ETag 缓存 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation

/// 检查面 URL 门（2026-10-28 切片-only 提取）：v4 resolver、切片 resolver 与通告服务
/// 共用同一强度判定（scheme=https / 无 userinfo / 端口 443 / 主机 ∈ 协议白名单）。
/// 自 `MedicalCatalogReleaseResolver.allowsCheckURL` 原样搬出——随 v4 resolver 删除
/// 不能带走检查传输层。
enum CatalogCheckURLGate {
    static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return MedicalCatalogReleaseProtocol.allowedHosts.contains(host)
    }
}

// MARK: - Bounded transport delegate

/// 检查面数据委托：逐跳 URL 门（限 5 跳，URL 门全项校验）+ 硬字节上限
/// （超限即 cancel）。消费方：v4/切片 resolver、UpdateAdviceService。
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
            // completionHandler(nil) 只拒绝重定向，任务会以 301 响应「正常」结束
            // （CI 36325211155 实证）——必须同时取消任务，让拒绝表现为传输失败
            // （下载面 MedicalCatalogPackageTransfer 同款双保险）。
            completionHandler(nil)
            task.cancel()
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

// MARK: - File hashing facade

/// 公开哈希门面（2026-10-28 CI #192 修复）：`StreamingFileHasher` 是 Infrastructure
/// 内部实现（v4 时代只被本层调用）；切片 journal 的 `sha256` 闭包由 App 装配注入，
/// 不得直引内部符号（家族 Q 同族纪律——App 只消费公开门面；Linux 型检对守卫文件
/// 全盲，这类错误只在 macOS CI 首见）。
public enum CatalogFileHashing {
    public static func sha256(of url: URL) throws -> String {
        try StreamingFileHasher.sha256(of: url)
    }
}
#endif
