#if os(iOS) || os(macOS)
import Foundation
import Domain

/// URLSession 提供下载、落盘与进度；本层仅约束已授权资源的地址、响应和字节预算。
final class ModelResourceTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedBytes: Int64?
    private let range: (start: Int64, end: Int64, total: Int64)?
    private let onBytes: (@Sendable (Int64) -> Void)?
    private let lock = NSLock()
    private var storedFailure: ASRModelDownloadService.Failure?
    var failure: ASRModelDownloadService.Failure? { lock.lock(); defer { lock.unlock() }; return storedFailure }

    init(expectedBytes: Int64? = nil, range: (Int64, Int64, Int64)? = nil,
         onBytes: (@Sendable (Int64) -> Void)? = nil) {
        self.expectedBytes = expectedBytes; self.range = range; self.onBytes = onBytes
    }
    private func record(_ failure: ASRModelDownloadService.Failure) {
        lock.lock(); if storedFailure == nil { storedFailure = failure }; lock.unlock()
    }
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
        guard let url = request.url, ModelResourcePolicy.allowedURL(url) else {
            record(.badAddress); completionHandler(nil); task.cancel(); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
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
