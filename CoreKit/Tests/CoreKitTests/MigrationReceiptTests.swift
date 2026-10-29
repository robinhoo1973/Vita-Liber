import Foundation
import Testing
@testable import Infrastructure

// binds: SU-M0-DBBOOT-RECEIPT（gate-suites.tsv M0 行；B3 迁移收据）
@Suite("SU-M0-DBBOOT-RECEIPT · 迁移启动收据（JSONL）")
struct MigrationReceiptTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func appendWritesOneJSONLinePerEvent() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let receipt = try MigrationReceipt(directory: dir)
        try receipt.append(.init(bootId: "b1", at: 1_760_000_000, candidates: ["app-local-user_data.sqlite"],
                                 chosen: "app-local-user_data.sqlite", mode: "migrate-v49-to-v50",
                                 sourceVersion: 49, targetVersion: 50, outcome: .inProgress))
        try receipt.append(.init(bootId: "b1", at: 1_760_000_010, candidates: ["app-local-user_data.sqlite"],
                                 chosen: "app-local-user_data.sqlite", mode: "migrate-v49-to-v50",
                                 sourceVersion: 49, targetVersion: 50, outcome: .success))
        let lines = try String(contentsOf: receipt.fileURL, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 2)
        let events = try receipt.readEvents()
        #expect(events.count == 2)
        #expect(events[0].outcome == .inProgress)
        #expect(events[1].outcome == .success)
        #expect(events[1].sourceVersion == 49)
        #expect(events[1].targetVersion == 50)
    }

    @Test func unterminatedInProgressIsDetectable() throws {
        // 判读语义：末事件 in-progress 且无同 bootId 终止行 = 上次死在迁移中。
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let receipt = try MigrationReceipt(directory: dir)
        try receipt.append(.init(bootId: "dead", at: 1, candidates: [], chosen: nil,
                                 mode: "migrate-v1-to-v50", sourceVersion: 1,
                                 targetVersion: 50, outcome: .inProgress))
        let events = try receipt.readEvents()
        let dangling = events.filter { $0.outcome == .inProgress }
            .filter { pending in
                !events.contains { $0.bootId == pending.bootId && $0.outcome != .inProgress }
            }
        #expect(dangling.count == 1)
        #expect(dangling.first?.bootId == "dead")
    }

    @Test func corruptLineDoesNotPoisonEvidence() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let receipt = try MigrationReceipt(directory: dir)
        try receipt.append(.init(bootId: "b1", at: 1, candidates: [], chosen: nil,
                                 mode: "fresh", sourceVersion: nil,
                                 targetVersion: 50, outcome: .success))
        // 追加半行（模拟断电截断）——读取侧跳过损坏行，好行仍可判读。
        let handle = try FileHandle(forWritingTo: receipt.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"broken\":".utf8))
        try handle.close()
        #expect(try receipt.readEvents().count == 1)
    }

    @Test func rotationKeepsOneArchive() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let receipt = try MigrationReceipt(directory: dir, rotateThreshold: 200)
        for index in 0..<6 {
            try receipt.append(.init(bootId: "b\(index)", at: Double(index), candidates: [],
                                     chosen: nil, mode: "fresh", sourceVersion: nil,
                                     targetVersion: 50, outcome: .success))
        }
        let archive = receipt.fileURL.appendingPathExtension("1")
        #expect(FileManager.default.fileExists(atPath: archive.path), "超阈值后必须轮转出 .1 归档")
        // 归档 + 现文件合计仍保有最近事件（取证窗口不断档）。
        let archived = try String(contentsOf: archive, encoding: .utf8)
        let current = try String(contentsOf: receipt.fileURL, encoding: .utf8)
        #expect(!archived.isEmpty)
        #expect(!current.isEmpty)
    }

    @Test func phasesRoundTripAndBackwardCompatibility() throws {
        // 批 ⑤：终止事件携带阶段耗时；旧行（无 phases 键）仍可解码。
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let receipt = try MigrationReceipt(directory: dir)
        try receipt.append(.init(
            bootId: "b1", at: 1, candidates: [], chosen: nil, mode: "fresh",
            sourceVersion: nil, targetVersion: 50, outcome: .success,
            phases: [
                .init(name: "history", durationMs: 12.5, status: "ok"),
                .init(name: "open.fresh", durationMs: 340.0, status: "ok"),
                .init(name: "sliceVerify", durationMs: 1800.0, status: "ok"),
            ]))
        // 追加一行「旧格式」（无 phases 键）——解码必须兼容。
        let handle = try FileHandle(forWritingTo: receipt.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("""
        {"at":2,"bootId":"b0","candidates":[],"mode":"ready-v50","outcome":"success"}
        """.utf8))
        try handle.close()
        let events = try receipt.readEvents()
        #expect(events.count == 2)
        #expect(events[0].phases?.count == 3)
        #expect(events[0].phases?[2].name == "sliceVerify")
        #expect(events[1].phases == nil, "旧行无 phases 键=向后兼容")
    }
}
