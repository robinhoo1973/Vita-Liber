import XCTest
@testable import VitaLiber
import Domain
import Infrastructure

/// 目录零隐式联网三级证据（U-批 B5，2026-10-28）：
/// ①spy 级——被动展示面零端口调用、显式检查恰一次、无候选安装零调用；
/// ②canary 级——测试内 URLProtocol 拦截计数（自证生效后断言 fail-closed
///   resolver 零请求）；③设备级飞行模式走 L2 真机清单。
/// 裁决偏差：URLProtocol 审计落测试目标内 canary，不设生产 DEBUG 钩子
/// （五处 session 工厂加产线钩子的风险 > 证据增量；B6 规格落词对齐）。
@MainActor
final class CatalogSlicesZeroNetworkTests: XCTestCase {

    // MARK: - spies

    private final class SpyReleaseResolver: CatalogSliceReleaseResolving, @unchecked Sendable {
        private let lock = NSLock()
        private var _checkCount = 0
        var checkCount: Int { lock.lock(); defer { lock.unlock() }; return _checkCount }

        func check() async throws -> CatalogSliceCheckEnvelope {
            lock.lock(); _checkCount += 1; lock.unlock()
            return CatalogSliceCheckEnvelope(
                outcome: CatalogSliceCheckOutcome(results: CatalogSliceKind.allCases.map {
                    CatalogSliceCheckResult(kind: $0, state: .upToDate(catalogVersion: nil),
                                            localCatalogVersion: nil)
                }),
                verified: [:])
        }
    }

    private final class SpyUpdater: CatalogSliceInstalling, @unchecked Sendable {
        private let lock = NSLock()
        private var _updateCount = 0
        var updateCount: Int { lock.lock(); defer { lock.unlock() }; return _updateCount }

        func update(_ candidate: VerifiedCatalogSliceCandidate,
                    progress: @escaping @Sendable (MedicalCatalogUpdateProgress) -> Void) async throws {
            lock.lock(); _updateCount += 1; lock.unlock()
        }
    }

    /// 全拦截 canary：任何请求都被计数并以离线错误立即失败（不发真实网络）。
    private final class CountingURLProtocol: URLProtocol {
        nonisolated(unsafe) private static var _requestCount = 0
        private static let lock = NSLock()
        static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _requestCount }
        static func reset() { lock.lock(); defer { lock.unlock() }; _requestCount = 0 }
        static func record() { lock.lock(); defer { lock.unlock() }; _requestCount += 1 }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.record()
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }

    private func makeState(checker: (any CatalogSliceReleaseResolving)?,
                           updater: (any CatalogSliceInstalling)?) -> CatalogSlicesState {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zero-net-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) // try?-ok: 测试目录
        return CatalogSlicesState(facade: CatalogSliceReadFacade(), checker: checker,
                                  updater: updater, receiptDirectory: dir)
    }

    // MARK: - ① spy 级

    func testPassiveSurfaceNeverCallsPorts() {
        let resolver = SpyReleaseResolver()
        let updater = SpyUpdater()
        let state = makeState(checker: resolver, updater: updater)
        _ = state.installedCount
        _ = state.aggregate
        for kind in CatalogSliceKind.allCases {
            _ = state.isInstalled(kind)
            _ = state.remoteState(kind)
        }
        XCTAssertEqual(resolver.checkCount, 0, "被动展示面不得触达检查端口")
        XCTAssertEqual(updater.updateCount, 0, "被动展示面不得触达安装端口")
    }

    func testExplicitCheckCallsCheckerExactlyOnce() async throws {
        let resolver = SpyReleaseResolver()
        let updater = SpyUpdater()
        let state = makeState(checker: resolver, updater: updater)
        XCTAssertEqual(resolver.checkCount, 0)
        state.check()   // 显式动作（首个联网许可点）
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, state.aggregate == .checking {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(resolver.checkCount, 1, "显式 check 恰调用 checker 一次")
        XCTAssertEqual(updater.updateCount, 0, "检查路径不得触发安装")
    }

    func testInstallWithoutCandidatesNeverCallsUpdater() async throws {
        let resolver = SpyReleaseResolver()
        let updater = SpyUpdater()
        let state = makeState(checker: resolver, updater: updater)
        state.installAll()   // 无已验签候选 → 必须零动作
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(updater.updateCount, 0, "无候选时 installAll 不得触碰安装器")
    }

    // MARK: - ② canary 级

    func testFailClosedResolverMakesZeroNetworkRequests() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        // 自证：canary 必须拦截一切请求（探测请求预期离线失败，不发真实网络）。
        CountingURLProtocol.reset()
        _ = try? await session.data(from: URL(string: "https://example.invalid/probe")!)   // try?-ok: 探测预期失败
        XCTAssertEqual(CountingURLProtocol.requestCount, 1, "canary 必须拦截所有请求")

        // 正式断言：pinned root 缺失 → fail-closed，检查全程零请求。
        CountingURLProtocol.reset()
        let resolver = CatalogSliceReleaseResolver(pinnedRootJSON: nil, makeVerifier: nil,
                                                   session: session)
        _ = try await resolver.check()
        XCTAssertEqual(CountingURLProtocol.requestCount, 0,
                       "pinned root 缺失须 fail-closed 零联网（ADR-030/FR25.13.2）")
    }
}
