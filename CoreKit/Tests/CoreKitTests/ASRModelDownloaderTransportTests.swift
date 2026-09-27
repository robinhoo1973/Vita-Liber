import Foundation
import Testing

#if os(iOS) || os(macOS)
// linux-blind: URLProtocol/URLSession 传输语义仅在 macOS CI 真跑（家族 N/O/P 同规；
// 新建 macOS-only 测试文件遵守 E10 双运行时矩阵 + .timeLimit 纪律，委员会测试席）。
@testable import Infrastructure

/// SU-M15-ASRTRANSPORT · binds: SU-M15-ASRTRANSPORT
/// ModelPackageDownloader 传输语义（2026-09-27 委员会测试席 Top1：三次进度 bug 的
/// 修复代码至今零直测——分段/206/吞 Range 退单流/段重试回滚/节流在此锁定）。
@Suite("SU-M15-ASRTRANSPORT · ASR 传输层行为钉", .serialized, .timeLimit(.minutes(2)))
struct ASRModelDownloaderTransportTests {

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func makeDownloader(segmentCount: Int = 4) -> ModelPackageDownloader {
        ModelPackageDownloader(session: makeSession(), segmentCount: segmentCount)
    }

    @Test func headProbeAndRangeDownloadSucceed() async throws {
        let body = Data((0..<4096).map { UInt8($0 % 251) })
        let url = URL(string: "https://release-assets.githubusercontent.com/stub/segmented.bin")!
        URLProtocolStub.reset()
        URLProtocolStub.scripts[url] = URLProtocolStub.Script(
            headers: ["Accept-Ranges": "bytes"], body: body)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dest) } // try?-ok: 测试临时文件清理，失败无断言语义
        var progress: [ASRModelDownloadService.DownloadProgress] = []
        try await makeDownloader().download(url: url, expectedBytes: Int64(body.count), to: dest) {
            progress.append($0)
        }
        #expect(try Data(contentsOf: dest) == body)
        let ranged = URLProtocolStub.requestLog.filter { $0.rangeHeader != nil }
        #expect(!ranged.isEmpty, "分段路径必须发 Range 请求")
        // 单调性与终态
        #expect(progress.allSatisfy { $0.fraction <= 1.0 })
        #expect(progress.last?.receivedBytes == Int64(body.count))
    }

    @Test func swallowedRangeFallsBackToSingleStreamWithSeriesBump() async throws {
        let body = Data((0..<8192).map { UInt8($0 % 251) })
        let url = URL(string: "https://release-assets.githubusercontent.com/stub/swallow.bin")!
        URLProtocolStub.reset()
        URLProtocolStub.scripts[url] = URLProtocolStub.Script(
            headers: ["Accept-Ranges": "bytes"], body: body, swallowRanges: true)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dest) } // try?-ok: 测试临时文件清理，失败无断言语义
        var progress: [ASRModelDownloadService.DownloadProgress] = []
        try await makeDownloader().download(url: url, expectedBytes: Int64(body.count), to: dest) {
            progress.append($0)
        }
        #expect(try Data(contentsOf: dest) == body)
        #expect(progress.contains { $0.mode == .singleStream }, "吞 Range 必须退单流（下载器层可观察语义；series 由服务层包装）")
        #expect(progress.allSatisfy { $0.fraction <= 1.0 })
    }

    @Test func segmentRetryRollsBackBytesAndKeepsFractionBounded() async throws {
        // 首段首次请求断流 → 重试成功：字节回滚后 fraction 恒 ≤1（2026-09-19 扫尾 #4 病灶）
        let body = Data((0..<65536).map { UInt8($0 % 251) })
        let url = URL(string: "https://release-assets.githubusercontent.com/stub/retry.bin")!
        URLProtocolStub.reset()
        URLProtocolStub.scripts[url] = URLProtocolStub.Script(
            headers: ["Accept-Ranges": "bytes"], body: body, failBeforeResponse: true)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dest) } // try?-ok: 测试临时文件清理，失败无断言语义
        var progress: [ASRModelDownloadService.DownloadProgress] = []
        try await makeDownloader().download(url: url, expectedBytes: Int64(body.count), to: dest) {
            progress.append($0)
        }
        #expect(try Data(contentsOf: dest) == body)
        #expect(progress.allSatisfy { $0.fraction <= 1.0 }, "重试回滚后进度不得回绕（病灶 2）")
        let ranged = URLProtocolStub.requestLog.filter { $0.rangeHeader != nil }
        #expect(ranged.count > 4, "首段断流应触发重试：请求数 > 段数")
    }

    @Test func resumeOffsetContinuesFromPartialFile() async throws {
        // 残留续传（委员会平局裁定 B1-4）：预置部分文件 + resumeOffset 起步，
        // 终态字节完整、SHA 语义由服务层兜底（此处只钉传输层契约）。
        let body = Data((0..<65536).map { UInt8($0 % 251) })
        let url = URL(string: "https://release-assets.githubusercontent.com/stub/resume.bin")!
        URLProtocolStub.reset()
        URLProtocolStub.scripts[url] = URLProtocolStub.Script(
            headers: ["Accept-Ranges": "bytes"], body: body)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dest) } // try?-ok: 测试临时文件清理，失败无断言语义
        let partial = body.prefix(16384)
        try partial.write(to: dest)
        try await makeDownloader().download(url: url, expectedBytes: Int64(body.count), to: dest,
                                           progress: { _ in }, resumeOffset: 16384)
        #expect(try Data(contentsOf: dest) == body)
        let ranged = URLProtocolStub.requestLog.filter { $0.rangeHeader != nil }
        #expect(ranged.contains { $0.rangeHeader?.hasPrefix("bytes=16384-") == true }, "续传首段必须从偏移起步")
    }

    @Test func sizeMismatchFailsWithoutProducingArtifact() async throws {
        let url = URL(string: "https://release-assets.githubusercontent.com/stub/short.bin")!
        URLProtocolStub.reset()
        URLProtocolStub.scripts[url] = URLProtocolStub.Script(
            headers: ["Accept-Ranges": "bytes"], body: Data(repeating: 0, count: 100))
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dest) } // try?-ok: 测试临时文件清理，失败无断言语义
        do {
            try await makeDownloader().download(url: url, expectedBytes: 1000, to: dest) { _ in }
            Issue.record("sizeMismatch 必须抛出")
        } catch let error as ASRModelDownloadService.Failure {
            #expect(error == .sizeMismatch)
        }
    }
}
#endif
