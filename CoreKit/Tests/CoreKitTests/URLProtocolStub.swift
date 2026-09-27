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
        /// 第 N 字节后断流（模拟 -1005）。
        var cutAfterBytes: Int? = nil
        /// 收到 Range 请求时仍返回整包 200（吞 Range 场景）。
        var swallowRanges: Bool = false
        /// 重定向目标（自动加 301 + Location）。
        var redirectTo: URL? = nil
    }

    static var scripts: [URL: Script] = [:]
    static var requestLog: [(url: URL, rangeHeader: String?)] = []

    static func reset() {
        scripts = [:]
        requestLog = []
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
        URLProtocolStub.requestLog.append((url, request.value(forHTTPHeaderField: "Range")))

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
        if request.value(forHTTPHeaderField: "Range") != nil, script.swallowRanges {
            headers.removeValue(forKey: "Content-Range")
        } else if let rangeHeader = request.value(forHTTPHeaderField: "Range"), status == 200,
                  let range = parseRange(rangeHeader, total: script.body.count) {
            // 支持 bytes=a-b 形态的精确切片（续传测试）
            body = script.body.subdata(in: range)
            status = 206
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(script.body.count)"
        }
        // cutAfterBytes 为一次性故障注入：同 URL 首请求才断（重试测试第二请求必须成功）
        if let cut = script.cutAfterBytes, body.count > cut, firstRequestForURL {
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
