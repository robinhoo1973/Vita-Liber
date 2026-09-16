#if os(iOS) || os(macOS)
import Foundation
import Domain

/// ASR 模型包下载（结构轮 2026-09-15 自 ASRModelDownloadService 拆出）：
/// HEAD 探测（Range 能力/字节数）→ 分段并行（默认 4 路）→ 服务端吞 Range 时
/// 整文件重建退单流 → 终态字节数校验。进度经 `ProgressCounter` 节流聚合。
/// 失败一律抛 `ASRModelDownloadService.Failure`（错误域归门面，消费点零改）。
struct ModelPackageDownloader {
    let session: URLSession
    let segmentCount: Int
    private let fileManager = FileManager.default

    init(session: URLSession, segmentCount: Int) {
        self.session = session
        self.segmentCount = segmentCount
    }

    func download(url: URL,
                          expectedBytes: Int64,
                          to destination: URL,
                          progress: (@Sendable (ASRModelDownloadService.DownloadProgress) -> Void)?) async throws {
        // 纵深防御（安全审查 2026-09-12）：下载目标必须 https——Domain `resolvedURL`
        // 已限相对路径 + https baseUrl，此处兜底任何直构 URL 的调用点。
        guard ModelResourcePolicy.allowedURL(url), expectedBytes > 0,
              expectedBytes <= ModelResourcePolicy.packageBytes else { throw ASRModelDownloadService.Failure.badAddress }
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 30
        head.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let headGuard = ModelResourceTransfer()
        let headResponse: URLResponse
        do {
            (_, headResponse) = try await session.data(for: head, delegate: headGuard)
        } catch {
            try Task.checkCancellation()
            throw headGuard.resolve(error)
        }
        if let failure = headGuard.failure { throw failure }
        guard let headHTTP = headResponse as? HTTPURLResponse else { throw ASRModelDownloadService.Failure.badResponse(-1) }
        let headSupported = (200..<300).contains(headHTTP.statusCode)
        guard headSupported || headHTTP.statusCode == 405 || headHTTP.statusCode == 501 else {
            throw ASRModelDownloadService.Failure.badResponse(headHTTP.statusCode)
        }
        if headSupported, headResponse.expectedContentLength > 0, headResponse.expectedContentLength != expectedBytes { throw ASRModelDownloadService.Failure.sizeMismatch }
        let total = expectedBytes
        let supportsRanges = headSupported && (headHTTP.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") ?? false)

        fileManager.createFile(atPath: destination.path, contents: nil)
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }   // try?-ok: 句柄关闭失败由系统回收，无静默降级风险
        try writer.truncate(atOffset: 0)

        // 传输形态对本函数**所有**出口可见（含分段退化与单流回退），供上层判定「慢」。
        var mode: ASRModelDownloadService.DownloadMode = .singleStream
        if supportsRanges, total >= Int64(segmentCount) {
            mode = .segmented(segments: segmentCount)
            let chunk = total / Int64(segmentCount)
            let counter = ProgressCounter(total: total, mode: mode, callback: progress)
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for index in 0..<segmentCount {
                        let start = Int64(index) * chunk
                        let end = index == segmentCount - 1 ? total - 1 : start + chunk - 1
                        group.addTask {
                            try await Self.downloadSegment(session: self.session, url: url,
                                                           start: start, end: end, total: total,
                                                           destination: destination, counter: counter)
                        }
                    }
                    try await group.waitForAll()
                }
            } catch ASRModelDownloadService.Failure.badResponse(let status) where status == 200 || status == 416 {
                try Task.checkCancellation()
                // Range 被服务端忽略（对 bytes=start-end 返回 200 整包）：分段写坏了文件，
                // 重建空文件后单流重下。进度计数器重建，避免分段字节虚增进度；
                // 形态同步降级为单流（上层据此可见「本可分段却被服务端吞掉 Range」）。
                try writer.truncate(atOffset: 0)
                mode = .singleStream
                let fallbackCounter = ProgressCounter(total: total, mode: mode, callback: progress)
                try await Self.downloadSegment(session: session, url: url, start: 0, end: nil, total: total,
                                               destination: destination, counter: fallbackCounter)
            }
        } else {
            let counter = ProgressCounter(total: total, mode: mode, callback: progress)
            try await Self.downloadSegment(session: session, url: url, start: 0, end: nil, total: total,
                                           destination: destination, counter: counter)
        }

        let attributes = try fileManager.attributesOfItem(atPath: destination.path)
        let written = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard written == total else { throw ASRModelDownloadService.Failure.sizeMismatch }
        progress?(.init(receivedBytes: total, totalBytes: total, mode: mode))
    }

    /// 单个 Range 段：独立 FileHandle 从 start 处顺序写入（互不重叠，无需加锁）。
    private static func downloadSegment(session: URLSession,
                                        url: URL,
                                         start: Int64,
                                         end: Int64?,
                                         total: Int64,
                                        destination: URL,
                                        counter: ProgressCounter) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let end { request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range") }
        let expected = end.map { $0 - start + 1 } ?? total
        let delegate = ModelResourceTransfer(expectedBytes: expected, range: end.map { (start, $0, total) }, onBytes: { counter.add($0) })
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(for: request, delegate: delegate)
        } catch {
            try Task.checkCancellation()
            throw delegate.resolve(error)
        }
        defer { try? FileManager.default.removeItem(at: temporary) } // try?-ok: URLSession 临时下载文件清理，不掩盖主错误
        try Task.checkCancellation()
        if let failure = delegate.failure { throw failure }
        try delegate.validate(response)
        let size = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber
        guard size?.int64Value == expected else { throw ASRModelDownloadService.Failure.sizeMismatch }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }   // try?-ok: 分段写入句柄关闭失败由系统回收
        try handle.seek(toOffset: UInt64(start))
        let input = try FileHandle(forReadingFrom: temporary)
        defer { try? input.close() } // try?-ok: 只读临时文件句柄清理
        var written: Int64 = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            written += Int64(chunk.count)
            guard written <= expected else { throw ASRModelDownloadService.Failure.sizeMismatch }
            try handle.write(contentsOf: chunk)
        }
        guard written == expected else { throw ASRModelDownloadService.Failure.sizeMismatch }
    }
}

/// 多段并发进度聚合（回调可在任意线程调用；调用方自行切主线程）。
/// 节流：每 64KB 块发一次会把主线程淹成数千次 hop——按增量 ≥0.5% 或
/// ≥200ms 发一次；终态由调用方显式补发 1.0。
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var received: Int64 = 0
    private var lastEmittedFraction: Double = 0
    private var lastEmitTime: TimeInterval = 0
    private let total: Int64
    private let mode: ASRModelDownloadService.DownloadMode
    private let callback: (@Sendable (ASRModelDownloadService.DownloadProgress) -> Void)?

    init(total: Int64, mode: ASRModelDownloadService.DownloadMode,
         callback: (@Sendable (ASRModelDownloadService.DownloadProgress) -> Void)?) {
        self.total = total
        self.mode = mode
        self.callback = callback
    }

    func add(_ bytes: Int64) {
        lock.lock()
        received += bytes
        let fraction = total > 0 ? Double(received) / Double(total) : 0
        let now = ProcessInfo.processInfo.systemUptime
        let shouldEmit = fraction - lastEmittedFraction >= 0.005 || now - lastEmitTime >= 0.2
        if shouldEmit {
            lastEmittedFraction = fraction
            lastEmitTime = now
        }
        let snapshot = received
        lock.unlock()
        if shouldEmit {
            callback?(.init(receivedBytes: snapshot, totalBytes: total, mode: mode))
        }
    }
}
#endif
