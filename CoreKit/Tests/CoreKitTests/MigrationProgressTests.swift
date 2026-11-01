#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Testing
@testable import Infrastructure

// binds: SU-M0-DBBOOT-SAFETY（2026-11-01 迁移安全网 · 逐 step 进度）
@Suite("SU-M0-DBBOOT-SAFETY · 迁移进度")
struct MigrationProgressTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [MigrationStepProgress] = []

        func append(_ progress: MigrationStepProgress) {
            lock.lock(); defer { lock.unlock() }
            storage.append(progress)
        }

        var events: [MigrationStepProgress] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    @Test func freshDatabaseEmitsNoStepProgress() throws {
        let recorder = Recorder()
        let queue = try DatabaseQueue(configuration: GRDBStore.configuration())
        _ = try GRDBStore(writer: queue) { recorder.append($0) }
        #expect(recorder.events.isEmpty, "v0 建库不是增量迁移，不得发 step 事件")
    }

    @Test func legacyV1EmitsPairedMonotonicSteps() throws {
        let recorder = Recorder()
        let queue = try SchemaChainGoldenTests.legacyV2Database()
        _ = try GRDBStore(writer: queue) { recorder.append($0) }

        let pending = SchemaMigrations.pending(from: 1)
        let events = recorder.events
        #expect(events.count == pending.count * 2, "每个成功 step 必须 started+finished 成对")
        #expect(events.first?.index == 1)
        #expect(events.last?.index == pending.count)
        #expect(events.last?.phase == .finished)
        for (offset, step) in pending.enumerated() {
            let started = events[offset * 2]
            let finished = events[offset * 2 + 1]
            #expect(started.index == offset + 1)
            #expect(started.version == step.version)
            #expect(started.phase == .started)
            #expect(finished.index == offset + 1)
            #expect(finished.version == step.version)
            #expect(finished.phase == .finished)
            #expect(started.total == pending.count)
        }
    }
}
#endif
