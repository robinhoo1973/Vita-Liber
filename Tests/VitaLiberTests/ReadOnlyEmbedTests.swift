import XCTest
@testable import VitaLiber
import Domain
import Infrastructure

/// 只读降级装配（B2 V2 证据，2026-10-28）：`AppContainer.readOnly` 装配成功、
/// 调度器为 no-op、不装会话、只读触碰后库字节不变。
@MainActor
final class ReadOnlyEmbedTests: XCTestCase {

    private func digest(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil } // try?-ok: 测试摘要，读失败按缺文件
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    func testReadOnlyContainerAssemblesWithoutSessionOrWrites() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ro-embed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let path = dir.appendingPathComponent("app-local-user_data.sqlite").path
        _ = try GRDBStore.pool(at: path)   // 建库到 latest 后释放

        let mainBefore = digest(path)
        let sessionBefore = AppSessionHolder.shared.currentSession

        let store = try GRDBStore.readOnly(at: path)
        let container = AppContainer.readOnly(store: store)

        XCTAssertTrue(container.reminderScheduler is NoopReminderScheduling,
                      "只读容器必须使用 no-op 调度器（绝不排通知）")
        let version = try container.store.writer.read {
            try Int.fetchOne($0, sql: "PRAGMA user_version")
        }
        XCTAssertEqual(version, SchemaMigrations.latestVersion)
        // holder 未被本测试改动（前后同值；只读路径绝不 install）。
        if let sessionBefore {
            XCTAssertTrue(AppSessionHolder.shared.currentSession === sessionBefore,
                          "只读装配不得替换既有会话")
        } else {
            XCTAssertNil(AppSessionHolder.shared.currentSession,
                         "只读装配绝不得安装会话")
        }

        XCTAssertEqual(digest(path), mainBefore, "只读装配与读取后主库字节必须不变")
    }
}
