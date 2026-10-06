#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import Domain

/// URLSession 提供下载、落盘与进度；本层仅约束已授权资源的地址、响应和字节预算。
final class ModelResourceTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedBytes: Int64?
    private let range: (start: Int64, end: Int64, total: Int64)?
    private let onBytes: (@Sendable (Int64) -> Void)?
    /// 停止查询（2026-10-06 暂停语义）：委托层每个写回调检查一次，命中即
    /// `task.cancel()`——iOS 26 的续跑任务由系统持有，调用方 Task 取消够不到请求，
    /// **传输层主动中断是暂停唯一有效的落点**（等待该请求自然收尾可达分钟级）。
    private let shouldCancel: (@Sendable () -> Bool)?
    private let lock = NSLock()
    private var storedFailure: ASRModelDownloadService.Failure?
    /// 重定向上限(2026-10-05 委员会):医疗线同款守卫——重定向循环/无限逐跳
    /// 在委托层直接终止;每跳仍过 allowedURL 主机门(含端口检查)。
    private var redirectHops = 0
    private static let maxRedirectHops = 5
    var failure: ASRModelDownloadService.Failure? { lock.lock(); defer { lock.unlock() }; return storedFailure }

    init(expectedBytes: Int64? = nil, range: (Int64, Int64, Int64)? = nil,
         onBytes: (@Sendable (Int64) -> Void)? = nil,
         shouldCancel: (@Sendable () -> Bool)? = nil) {
        self.expectedBytes = expectedBytes; self.range = range; self.onBytes = onBytes
        self.shouldCancel = shouldCancel
    }
    private func record(_ failure: ASRModelDownloadService.Failure) {
        lock.lock(); if storedFailure == nil { storedFailure = failure }; lock.unlock()
    }
    /// 守卫在委托回调里拒绝重定向/超预算时会 `task.cancel()`，URLSession 随之抛
    /// `URLError.cancelled`——调用方必须优先暴露守卫记录的真实原因（S-M4），
    /// 否则「重定向到非白名单主机」在日志/界面里都只剩一个「已取消」。
    func resolve(_ error: Error) -> Error { failure ?? error }
    #if DEBUG
    func recordForTesting(_ failure: ASRModelDownloadService.Failure) { record(failure) }
    #endif
    func validate(_ response: URLResponse) throws {
        guard let url = response.url, ModelResourcePolicy.allowedURL(url) else { throw ASRModelDownloadService.Failure.badAddress }
        guard let http = response as? HTTPURLResponse else { throw ASRModelDownloadService.Failure.badResponse(-1) }
        if let range {
            guard http.statusCode == 206 else { throw ASRModelDownloadService.Failure.badResponse(http.statusCode) }
            let expected = "bytes \(range.start)-\(range.end)/\(range.total)"
            guard http.value(forHTTPHeaderField: "Content-Range")?.trimmingCharacters(in: .whitespacesAndNewlines) == expected else {
                throw ASRModelDownloadService.Failure.sizeMismatch
            }
        } else if expectedBytes != nil {
            guard http.statusCode == 200 else { throw ASRModelDownloadService.Failure.badResponse(http.statusCode) }
        }
        if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" {
            throw ASRModelDownloadService.Failure.sizeMismatch
        }
        if let expectedBytes, response.expectedContentLength >= 0, response.expectedContentLength != expectedBytes {
            throw ASRModelDownloadService.Failure.sizeMismatch
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        redirectHops += 1
        guard redirectHops <= Self.maxRedirectHops,
              let url = request.url, ModelResourcePolicy.allowedURL(url) else {
            record(.badAddress); completionHandler(nil); task.cancel(); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if shouldCancel?() == true {
            downloadTask.cancel()   // 暂停请求：中断本段请求（调用方把 URLError.cancelled 翻译回取消语义）
            return
        }
        do {
            if let response = downloadTask.response { try validate(response) }
            if let expectedBytes, totalBytesWritten > expectedBytes { throw ASRModelDownloadService.Failure.sizeMismatch }
            onBytes?(max(0, bytesWritten))
        } catch {
            record(error as? ASRModelDownloadService.Failure ?? .sizeMismatch)
            downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
#endif
