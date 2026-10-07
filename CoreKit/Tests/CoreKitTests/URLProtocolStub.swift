import Foundation

#if os(iOS) || os(macOS)
// linux-blind: URLProtocol 在 Linux 属 FoundationNetworking 且传输语义不在 Linux 真跑

/// 脚本化 URLProtocol 传输桩（2026-09-27 委员会测试席 Top1，WWDC18-417
/// requestHandler 模式）：单例注册表把 URL 映射到脚本化响应——分块延时下发、
/// 第 N 字节断流、状态码、Accept-Ranges/ETag 头、重定向逐项可控。
/// 仅测试目标使用；传输语义断言在 macOS CI 真跑（linux-blind 纪律）。
final class URLProtocolStub: URLProtocol {
    struct Script {
        var statusCode: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
        /// 每块字节数与每块间延时（秒）；空 = 整包一次下发。
        var chunkBytes: Int? = nil
        var chunkDelay: TimeInterval = 0
        /// 第 N 字节后断流（模拟 -1005）；与 URLSession 部分响应状态机相克，
        /// 重试注入优先用 failBeforeResponse。
        var cutAfterBytes: Int? = nil
        /// 首个下载请求响应前即失败（干净连接失败——重试**恢复**测试的注入形态；
        /// HEAD 探测不占「首请求」名额，见 startLoading 的 isHead 排除）。
        var failBeforeResponse: Bool = false
        /// 每个下载请求都失败（重试也失败——确定性**失败路径**钉用；
        /// 一次注入会被生产重试消化，钉不住失败态）。
        var failEveryRequest: Bool = false
        /// 收到 Range 请求时仍返回整包 200（吞 Range 场景）。
        var swallowRanges: Bool = false
        /// 重定向目标（自动加 301 + Location）。
        var redirectTo: URL? = nil
        /// ETag/304 语义（2026-09-27 SP-64 检查链测试）：收到与 `headers["ETag"]`
        /// 匹配的 If-None-Match 时返回 304 空体。
        var etag304: Bool = false
    }

    /// 2026-09-27 CI 36302543076 实证：.serialized 只串行套件内——两传输套件之间仍并行，
    /// 共享静态字典的并发变异导致进程级内存损坏（SIGSEGV 落在无关测试上）。锁保护。
    private static let lock = NSLock()
    private static var _scripts: [URL: Script] = [:]
    private static var _requestLog: [(url: URL, rangeHeader: String?)] = []

    static var scripts: [URL: Script] {
        get { lock.lock(); defer { lock.unlock() }; return _scripts }
        set { lock.lock(); defer { lock.unlock() }; _scripts = newValue }
    }
    static var requestLog: [(url: URL, rangeHeader: String?)] {
        get { lock.lock(); defer { lock.unlock() }; return _requestLog }
        set { lock.lock(); defer { lock.unlock() }; _requestLog = newValue }
    }

    /// 原子写单键（2026-10-04 CI #645 实证修复）：`scripts[url] = script` 是
    /// getter 拷贝 → 变异 → setter 整表替换的非原子读改写——两个并发套件
    /// 各持旧拷贝，后写者把先写者刚插入的键整个丢掉（丢键 → canInit 否 →
    /// 请求逃逸真实网络 → runner 网关 618 → .badResponse(618) flake）。
    /// 所有测试写入必须走本出口，禁止下标 RMW。
    static func setScript(_ script: Script, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        _scripts[url] = script
    }

    /// 原子追加请求日志（同族 RMW 修复；startLoading 专用）。
    static func appendRequest(url: URL, rangeHeader: String?) {
        lock.lock(); defer { lock.unlock() }
        _requestLog.append((url, rangeHeader))
    }

    /// 2026-09-27 CI 36305107324：两传输套件虽各 .serialized，但**彼此仍并行**且共享
    /// 全表——A 套件 reset 擦掉 B 套件脚本（badResponse(618)=协议类不处理请求的
    /// 合成状态）。改为作用域清表。**作用域属主表（2026-10-07 通道迁移更新）**：
    /// release-assets.githubusercontent.com=ASR 套件（ASR 链仍 GitHub）·
    /// cnb.cool `/releases/download/medical-data/medical-data-package-*`=医疗 fetcher
    /// 套件 · cnb.cool `/releases/tag/medical-data` + `/releases/download/medical-data/
    /// medical-data-catalog-*`=医疗 resolver 套件（2026-10-07 P0：检查面迁至 SSR tag
    /// 页，与 fetcher 同主机不同前缀——**同主机的多套件必须用 URL 前缀作用域**，
    /// 主机作用域会互擦（旧 api.cnb.cool 属主已随匿名 401 修复退役））。
    /// 新套件必须登记新前缀，不得复用已有属主。
    static func reset(host: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let host {
            _scripts = _scripts.filter { $0.key.host?.lowercased() != host.lowercased() }
            _requestLog = _requestLog.filter { $0.url.host?.lowercased() != host.lowercased() }
        } else {
            _scripts = [:]
            _requestLog = []
        }
    }

    /// 前缀作用域清表（2026-10-07）：同一主机上多套件分属不同 URL 前缀时，
    /// 主机作用域会互相清表——按 `absoluteString` 前缀切分属主。
    static func reset(urlPrefixes: [String]) {
        lock.lock(); defer { lock.unlock() }
        _scripts = _scripts.filter { entry in
            !urlPrefixes.contains { entry.key.absoluteString.hasPrefix($0) }
        }
        _requestLog = _requestLog.filter { entry in
            !urlPrefixes.contains { entry.url.absoluteString.hasPrefix($0) }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return scripts[url] != nil || scripts.keys.contains { $0.absoluteString == url.absoluteString }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let script = URLProtocolStub.scripts.first(where: { $0.key.absoluteString == url.absoluteString })?.value else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let firstRequestForURL = !URLProtocolStub.requestLog.contains { $0.url == url }
        URLProtocolStub.appendRequest(url: url, rangeHeader: request.value(forHTTPHeaderField: "Range"))

        if let target = script.redirectTo {
            let response = HTTPURLResponse(url: url, statusCode: 301,
                                           httpVersion: nil,
                                           headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        var headers = script.headers
        var body = script.body
        var status = script.statusCode
        if script.etag304,
           let inm = request.value(forHTTPHeaderField: "If-None-Match"),
           let etag = headers["ETag"], inm == etag {
            let notModified = HTTPURLResponse(url: url, statusCode: 304, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: notModified, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if request.value(forHTTPHeaderField: "Range") != nil, script.swallowRanges {
            headers.removeValue(forKey: "Content-Range")
        } else if let rangeHeader = request.value(forHTTPHeaderField: "Range"), status == 200,
                  let range = parseRange(rangeHeader, total: script.body.count) {
            // 支持 bytes=a-b 形态的精确切片（续传测试）
            body = script.body.subdata(in: range)
            status = 206
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(script.body.count)"
        }
        // cutAfterBytes 为一次性故障注入：只切首个**下载**请求（HEAD 探测不受切——
        // 否则断流落在探测上，段重试语义无从触发）；同 URL 首下载才断。
        let isHead = request.httpMethod?.uppercased() == "HEAD"
        if (script.failEveryRequest || (script.failBeforeResponse && firstRequestForURL)), !isHead {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        if let cut = script.cutAfterBytes, body.count > cut, firstRequestForURL, !isHead {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let chunk = body.prefix(cut)
            client?.urlProtocol(self, didLoad: Data(chunk))
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let chunkBytes = script.chunkBytes, chunkBytes > 0 {
            var offset = 0
            while offset < body.count {
                let end = min(offset + chunkBytes, body.count)
                client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
                offset = end
                if offset < body.count, script.chunkDelay > 0 {
                    Thread.sleep(forTimeInterval: script.chunkDelay)
                }
            }
        } else {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func parseRange(_ header: String, total: Int) -> Range<Int>? {
        guard total > 0, header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        guard let dash = spec.firstIndex(of: "-") else { return nil }
        let startText = spec[..<dash], endText = spec[spec.index(after: dash)...]
        guard let start = Int(startText), start >= 0, start < total else { return nil }
        let end = endText.isEmpty ? total : min(Int(endText) ?? (total - 1), total - 1) + 1
        guard end > start else { return nil }
        return start..<end
    }
}
#endif
