#if os(iOS) || os(macOS)
import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

/// ADR-030 §3.6 安装边界回归（第二轮安全复审 S-I1/S-M4）：
/// 崩溃残留的暂存目录必须在下次安装入口被回收，而有租约/已激活目录不得被触碰；
/// 守卫记录的地址失败要优先于 URLSession 的取消错误暴露给调用方。
@Suite("ASR 下载服务安装边界")
struct ASRModelDownloadServiceTests {
    @Test func 安装入口回收无租约暂存目录并保留有租约与版本目录() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) } // try?-ok: 隔离测试目录清理
        let stale = root.appendingPathComponent(".staging-1.0.0-\(UUID().uuidString)", isDirectory: true)
        let leased = root.appendingPathComponent(".staging-1.0.0-\(UUID().uuidString)", isDirectory: true)
        let version = root.appendingPathComponent("1.0.0-abcdef012345-\(UUID().uuidString)", isDirectory: true)
        for url in [stale, leased, version] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("payload.bin"))
        }
        let lease = ASRModelAssets(root: leased).acquireLease()
        ASRModelDownloadService.removeStaleStaging(in: root)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: leased.path))
        #expect(FileManager.default.fileExists(atPath: version.path))
        withExtendedLifetime(lease) {}
    }

    @Test func 缺失模型根目录时回收静默无操作() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        ASRModelDownloadService.removeStaleStaging(in: missing)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func 守卫记录的地址失败优先于取消错误() {
        let transfer = ModelResourceTransfer()
        transfer.recordForTesting(.badAddress)
        let mapped = transfer.resolve(URLError(.cancelled))
        #expect((mapped as? ASRModelDownloadService.Failure) == .badAddress)
        let untouched = ModelResourceTransfer().resolve(URLError(.timedOut))
        #expect((untouched as? URLError)?.code == .timedOut)
    }
}
#endif
