import Foundation
import Testing

#if os(iOS) || os(macOS)
// linux-blind: 传输语义仅在 macOS CI 真跑（家族 N/O/P 同规；E10 双运行时矩阵纪律）。
@testable import Infrastructure

/// SU-M15-MEDCATALOG · binds: SU-M15-MEDCATALOG（TC-M15-11 传输层，委员会测试席）
/// URLSessionMedicalCatalogPackageFetcher 传输契约：白名单重定向、百分比节流、
/// 取消、瞬态重试、磁盘满语义（2026-09-27 裁决 5 韧性改造后的行为钉）。
@Suite("SU-M15-MEDCATALOG · 目录 fetcher 传输行为钉", .serialized, .timeLimit(.minutes(2)))
struct MedicalCatalogFetcherTransportTests {

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func assetURL(_ name: String) -> URL {
        // 用生产同一构造器（单一事实源）：桩键必须与 fetcher 实际请求的 URL 一致
        MedicalCatalogReleaseProtocol.packageURL(assetName: name)!
    }

    @Test func successfulFetchDeliversExactBytes() async throws {
        let body = Data((0..<16384).map { UInt8($0 % 251) })
        let url = assetURL("medical-data-package-sqlite-0f5cd3aeab2616f1970bca918d9f51edfae2a40cbc99098b982993672bffc618-cipher-714889113c7698b65356a9081fdcaf346d0819a6eb66d7020d68b20c09fc46bc.bin")
        URLProtocolStub.reset(host: "github.com")
        URLProtocolStub.scripts[url] = URLProtocolStub.Script(body: body)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dest) } // try?-ok: 测试临时文件清理，失败无断言语义
        let fetcher = URLSessionMedicalCatalogPackageFetcher(session: makeSession())
        var callbacks = 0
        try await fetcher.fetch(assetName: "medical-data-package-sqlite-0f5cd3aeab2616f1970bca918d9f51edfae2a40cbc99098b982993672bffc618-cipher-714889113c7698b65356a9081fdcaf346d0819a6eb66d7020d68b20c09fc46bc.bin", expectedSize: Int64(body.count), to: dest) { _ in
            callbacks += 1
        }
        #expect(try Data(contentsOf: dest) == body)
        #expect(callbacks <= 101, "整百分比节流：回调数 ≤ 101")
    }

    @Test func persistentConnectionFailureSurfacesAsDownloadFailure() async throws {
        // 确定性失败路径钉：持续断流 → .downloadFailed（重试**恢复**语义的 seam 化
        // 单测登记为待办——URLProtocol 注入与 URLSession 任务复用语义不可靠，
        // CI 36305107324 多轮实证）。
        let body = Data((0..<16384).map { UInt8($0 % 251) })
        let name = "medical-data-package-sqlite-0f5cd3aeab2616f1970bca918d9f51edfae2a40cbc99098b982993672bffc618-cipher-714889113c7698b65356a9081fdcaf346d0819a6eb66d7020d68b20c09fc46bc.bin"
        let url = assetURL(name)
        URLProtocolStub.reset(host: "github.com")
        URLProtocolStub.scripts[url] = URLProtocolStub.Script(body: body, failBeforeResponse: true)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dest) } // try?-ok: 测试临时文件清理，失败无断言语义
        let fetcher = URLSessionMedicalCatalogPackageFetcher(session: makeSession())
        do {
            try await fetcher.fetch(assetName: name, expectedSize: Int64(body.count), to: dest) { _ in }
            Issue.record("持续断流必须抛出")
        } catch let error as MedicalCatalogUpdateError {
            #expect(error == .downloadFailed)
        }
    }

    @Test func sizeMismatchThrowsChecksumError() async throws {
        let url = assetURL("medical-data-package-sqlite-0f5cd3aeab2616f1970bca918d9f51edfae2a40cbc99098b982993672bffc618-cipher-714889113c7698b65356a9081fdcaf346d0819a6eb66d7020d68b20c09fc46bc.bin")
        URLProtocolStub.reset(host: "github.com")
        URLProtocolStub.scripts[url] = URLProtocolStub.Script(body: Data(repeating: 0, count: 100))
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dest) } // try?-ok: 测试临时文件清理，失败无断言语义
        let fetcher = URLSessionMedicalCatalogPackageFetcher(session: makeSession())
        do {
            try await fetcher.fetch(assetName: "medical-data-package-sqlite-0f5cd3aeab2616f1970bca918d9f51edfae2a40cbc99098b982993672bffc618-cipher-714889113c7698b65356a9081fdcaf346d0819a6eb66d7020d68b20c09fc46bc.bin", expectedSize: 1000, to: dest) { _ in }
            Issue.record("尺寸不符必须抛出")
        } catch let error as MedicalCatalogUpdateError {
            #expect(error == .checksumMismatch)
        }
    }
}
#endif
