#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：内容未在 Linux 编译，盲区） —— Linux 型检编译空单元，改动须经 macOS CI 验证
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
                          progress: (@Sendable (ASRModelDownloadService.DownloadProgress) -> Void)?,
                          resumeOffset: Int64 = 0) async throws {
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

        // 断点续传（2026-09-20 llama 首启下载稳定性）：resumeOffset > 0 时目标文件
        // 已是有效部分文件（调用方保证大小 == resumeOffset），不重建不截断。
        // 非续传路径保持原语义（新建 + 清零）。
        if resumeOffset == 0 {
            fileManager.createFile(atPath: destination.path, contents: nil)
        }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }   // try?-ok: 句柄关闭失败由系统回收，无静默降级风险
        if resumeOffset == 0 { try writer.truncate(atOffset: 0) }

        // 传输形态对本函数**所有**出口可见（含分段退化与单流回退），供上层判定「慢」。
        var mode: ASRModelDownloadService.DownloadMode = .singleStream
        if supportsRanges, total - resumeOffset >= Int64(segmentCount) {
            mode = .segmented(segments: segmentCount)
            let remaining = total - resumeOffset
            let chunk = remaining / Int64(segmentCount)
            let counter = ProgressCounter(total: total, mode: mode, series: 0, callback: progress)
            counter.add(resumeOffset)
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for index in 0..<segmentCount {
                        let start = resumeOffset + Int64(index) * chunk
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
                // 系列换代（审查修复 2026-09-18）：单流重建计数器从 0 重计、
                // totalBytes 与分段系列相同——系列 +1 让消费侧单调守卫跨系列
                // 放行，否则进度条钉死在分段峰值（业主实测「无反应」）。
                try writer.truncate(atOffset: 0)
                mode = .singleStream
                let fallbackCounter = ProgressCounter(total: total, mode: mode, series: 1, callback: progress)
                try await Self.downloadSegment(session: session, url: url, start: 0, end: nil, total: total,
                                               destination: destination, counter: fallbackCounter)
            }
        } else {
            let counter = ProgressCounter(total: total, mode: mode, series: 0, callback: progress)
            counter.add(resumeOffset)
            try await Self.downloadSegment(session: session, url: url, start: resumeOffset, end: nil, total: total,
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
        // 2026-09-19 审查修复：请求级空闲超时 60s → 300s——URLSession 对**排队等连接**
        // 的请求也计请求超时（排队期间不重置计时），GB 级分段在池内排队 >60s 即被
        // -1001 掐断；300s 与「无资源超时天花板」的分段下载语义一致（头部探测仍 30s）。
        request.timeoutInterval = 300
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let end { request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range") }
        let expected = end.map { $0 - start + 1 } ?? total
        let (temporary, response) = try await downloadAttempt(session: session, request: request,
                                                              expected: expected,
                                                              range: end.map { (start, $0, total) },
                                                              counter: counter)
        defer { try? FileManager.default.removeItem(at: temporary) } // try?-ok: URLSession 临时下载文件清理，不掩盖主错误
        try Task.checkCancellation()
        let validator = ModelResourceTransfer(expectedBytes: expected, range: end.map { (start, $0, total) })
        try validator.validate(response)
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

/// 单段下载 + 瞬态错误重试一次（2026-09-19 审查修复）：连接池争用/链路抖动下
/// 段请求超时（-1001）或连接丢失（-1005）会掐断 GB 级分段——重试一次（固定 2s
/// 退避，最简可解释形态）显著降低整装失败率。委托按尝试重建：字节计数不复用
/// （失败尝试的已收字节不得重复累计进进度计数器）。
private func downloadAttempt(session: URLSession, request: URLRequest,
                             expected: Int64, range: (Int64, Int64, Int64)?,
                             counter: ProgressCounter) async throws -> (URL, URLResponse) {
    var lastError: Error = ASRModelDownloadService.Failure.sizeMismatch
    for attempt in 0..<2 {
        // 委托按尝试重建；失败尝试已计入共享计数器的字节在重试前回滚——
        // 2026-09-19 扫尾发现 #4：重试双计会使 fraction > 1（进度条回绕/提前满格）。
        var attemptBytes: Int64 = 0
        let delegate = ModelResourceTransfer(expectedBytes: expected, range: range,
                                             onBytes: { counter.add($0); attemptBytes += $0 })
        do {
            let (temporary, response) = try await session.download(for: request, delegate: delegate)
            return (temporary, response)
        } catch {
            try Task.checkCancellation()
            lastError = delegate.resolve(error)
            guard attempt == 0, let urlError = error as? URLError,
                  [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(urlError.code) else {
                throw lastError
            }
            counter.remove(attemptBytes)
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
    throw lastError
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
    /// 系列代次：同一 totalBytes 的重启系列（退单流 / 段重试回滚）必须换代
    /// （见 DownloadProgress.series）——消费侧单调守卫跨系列一律放行。
    private var series: Int
    private let callback: (@Sendable (ASRModelDownloadService.DownloadProgress) -> Void)?

    init(total: Int64, mode: ASRModelDownloadService.DownloadMode, series: Int,
         callback: (@Sendable (ASRModelDownloadService.DownloadProgress) -> Void)?) {
        self.total = total
        self.mode = mode
        self.series = series
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
            callback?(.init(receivedBytes: snapshot, totalBytes: total, mode: mode, series: series))
        }
    }

    /// 失败尝试字节回滚（重试路径）：扣计数 + **系列换代** + 节流基线回退。
    /// 2026-09-20 修复（业主「语音模型下载进度条无反应」）：旧实现只扣计数——
    /// 消费侧单调守卫（`ASRInstallCenter.Install.submit`）按「同系列 received 不增
    /// 即丢弃」判定，回滚后的每次发射（received 低于已接受峰值）全被丢弃，
    /// 进度条在段重试的整段重下期间钉死在旧峰值（分钟级）。系列换代让消费侧
    /// 跨系列放行；lastEmittedFraction 回退到回滚后分数，重试进度立即恢复发射。
    func remove(_ bytes: Int64) {
        lock.lock()
        received = max(0, received - bytes)
        series &+= 1
        let fraction = total > 0 ? Double(received) / Double(total) : 0
        lastEmittedFraction = max(0, fraction)
        lock.unlock()
    }
}
#endif
