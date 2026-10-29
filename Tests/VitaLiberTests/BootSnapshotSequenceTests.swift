import XCTest
@testable import VitaLiber
import Domain
import Infrastructure

/// SU-M2-SELFCHECK-SNAPSHOT（启动时序批 ①，2026-10-29；测试席契约 (b)）：
/// 快照发射序列=advisory 先于 open、失败恰 1 发、字段内容如实；
/// BootEnvironment 注入缝自证（临时目录/桩探针/桩 open，不碰真实库）。
@MainActor
final class BootSnapshotSequenceTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _snapshots: [BootChecklistSnapshot] = []
        private var _openCount = 0
        private var _openObservedSnapshots = 0

        func record(_ snapshot: BootChecklistSnapshot) {
            lock.lock(); defer { lock.unlock() }
            _snapshots.append(snapshot)
        }

        func recordOpen() {
            lock.lock(); defer { lock.unlock() }
            _openCount += 1
            _openObservedSnapshots = _snapshots.count
        }

        var snapshots: [BootChecklistSnapshot] {
            lock.lock(); defer { lock.unlock() }
            return _snapshots
        }

        var openCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _openCount
        }

        /// open 被调用时已发射的 advisory 数（断言 advisory 先于 open）。
        var snapshotsBeforeOpen: Int {
            lock.lock(); defer { lock.unlock() }
            return _openObservedSnapshots
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("boot-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readyProbe(exists: Bool = true) -> DatabaseProbeSnapshot {
        DatabaseProbeSnapshot(
            exists: exists, sizeBytes: exists ? 4096 : 0, headerValid: exists,
            observedVersion: exists ? SchemaMigrations.latestVersion : nil,
            tableCount: exists ? 30 : 0,
            requiredTablesPresent: exists ? 3 : 0, requiredTablesExpected: 3,
            originalsPresent: false)
    }

    private func makeEnvironment(dir: URL, recorder: Recorder,
                                 probe: DatabaseProbeSnapshot,
                                 openThrows: Bool) -> DatabaseBootService.BootEnvironment {
        let databasePath = dir.appendingPathComponent("app-local-user_data.sqlite").path
        let historyPath = dir.appendingPathComponent("app-local-schema-history.sqlite").path
        return DatabaseBootService.BootEnvironment(
            resolveDatabasePath: {
                .init(path: databasePath, candidates: ["app-local-user_data.sqlite"])
            },
            schemaHistoryPath: { historyPath },
            catalogSlicePath: { name in dir.appendingPathComponent(name).path },
            originalsPresent: { false },
            probePatient: { _, _ in probe },
            probeSlice: { _, _ in .missing },
            open: { _, _, _ in
                recorder.recordOpen()
                if openThrows { throw DatabaseBootFailure.openFailed("stub") }
                return try GRDBStore.inMemory()
            })
    }

    func testReadyDecisionEmitsAdvisoryBeforeOpen() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let recorder = Recorder()
        let environment = makeEnvironment(dir: dir, recorder: recorder,
                                          probe: readyProbe(), openThrows: false)
        let prepared = try await DatabaseBootService.prepare(
            environment: environment,
            clock: { Date(timeIntervalSince1970: 1_760_000_000) },
            snapshot: { recorder.record($0) },
            progress: { _ in })
        XCTAssertNotNil(prepared)
        XCTAssertEqual(recorder.snapshots.count, 1, "service 侧成功路径恰 1 发 advisory（final 由模型层发射）")
        let advisory = try XCTUnwrap(recorder.snapshots.first)
        XCTAssertEqual(advisory.decision, .ready(version: SchemaMigrations.latestVersion))
        XCTAssertTrue(advisory.committedKinds.isEmpty, "advisory 恒未提交（committedKinds 空）")
        XCTAssertEqual(recorder.openCount, 1)
        XCTAssertEqual(recorder.snapshotsBeforeOpen, 1, "advisory 必须先于 open 发射")
    }

    func testCorruptDecisionEmitsSingleAdvisoryThenThrows() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let recorder = Recorder()
        let corruptProbe = DatabaseProbeSnapshot(
            exists: true, sizeBytes: 1, headerValid: false, observedVersion: nil,
            tableCount: 0, requiredTablesPresent: 0, requiredTablesExpected: 3,
            originalsPresent: false)
        let environment = makeEnvironment(dir: dir, recorder: recorder,
                                          probe: corruptProbe, openThrows: false)
        do {
            _ = try await DatabaseBootService.prepare(
                environment: environment,
                clock: Date.init,
                snapshot: { recorder.record($0) },
                progress: { _ in })
            XCTFail("corrupt 决策必须抛出")
        } catch {
            XCTAssertTrue(error is DatabaseBootFailure)
        }
        XCTAssertEqual(recorder.snapshots.count, 1, "失败路径恰 1 发 advisory")
        XCTAssertEqual(recorder.openCount, 0, "fail-closed 决策不得触发 open")
        if case .corrupt = recorder.snapshots.first?.decision { } else {
            XCTFail("advisory 决策应为 corrupt")
        }
    }

    /// 批 ④（2026-10-29）：`.ready` 决策下切片全验与 open 并发交叠——
    /// 时序确定性证明：probe 开始早于 open 结束，且 open 开始早于 probe 结束。
    /// run 40821125910 红修复：原实现靠 Thread.sleep 赌 utility 任务被及时调度
    /// （macOS 跑者较闲时 open 先完成、probe 后启动，两时间戳同秒）。改为两闭包
    /// 互为门闩的有界等待——交叠由结构保证，不再依赖协作池调度时机。
    func testReadyDecisionOverlapsSliceProbesWithOpen() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        final class Timeline: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [(String, Date)] = []
            func mark(_ label: String) {
                lock.lock(); defer { lock.unlock() }
                events.append((label, Date()))
            }
            func time(_ label: String) -> Date? {
                lock.lock(); defer { lock.unlock() }
                return events.first { $0.0 == label }?.1
            }

            /// 有界轮询等待事件出现（协作池只保证 `Task.detached` 创建先于 open
            /// 调用，不保证 utility 任务在 open 完成前拿到线程——互为门闩把
            /// 「交叠」从调度运气变成结构必然）。
            func waitFor(_ label: String, timeout: TimeInterval = 10) -> Bool {
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    if time(label) != nil { return true }
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return false
            }
        }
        let timeline = Timeline()
        let databasePath = dir.appendingPathComponent("app-local-user_data.sqlite").path
        let historyPath = dir.appendingPathComponent("app-local-schema-history.sqlite").path
        // CI 40798903458 红修复：@Sendable 闭包内不得调 @MainActor 方法——
        // 值在 MainActor 作用域预取后按值捕获（DatabaseProbeSnapshot 为 Sendable）。
        let readySnapshot = readyProbe()
        let environment = DatabaseBootService.BootEnvironment(
            resolveDatabasePath: {
                .init(path: databasePath, candidates: ["app-local-user_data.sqlite"])
            },
            schemaHistoryPath: { historyPath },
            catalogSlicePath: { name in dir.appendingPathComponent(name).path },
            originalsPresent: { false },
            probePatient: { _, _ in readySnapshot },
            probeSlice: { _, _ in
                timeline.mark("probeStart")
                _ = timeline.waitFor("openStart")
                timeline.mark("probeEnd")
                return .ready
            },
            open: { _, _, _ in
                timeline.mark("openStart")
                _ = timeline.waitFor("probeStart")
                timeline.mark("openEnd")
                return try GRDBStore.inMemory()
            })
        _ = try await DatabaseBootService.prepare(
            environment: environment, clock: Date.init,
            snapshot: { _ in }, progress: { _ in })
        let probeStart = try XCTUnwrap(timeline.time("probeStart"))
        let probeEnd = try XCTUnwrap(timeline.time("probeEnd"))
        let openStart = try XCTUnwrap(timeline.time("openStart"))
        let openEnd = try XCTUnwrap(timeline.time("openEnd"))
        XCTAssertLessThan(probeStart, openEnd, "probe 必须先于 open 结束开始（并发而非串行）")
        XCTAssertLessThan(openStart, probeEnd, "open 必须在 probe 结束前开始（双向交叠）")
    }

    func testSequentialAttemptsEmitIndependentAdvisories() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) } // try?-ok: 测试清理
        let recorder = Recorder()
        let environment = makeEnvironment(dir: dir, recorder: recorder,
                                          probe: readyProbe(), openThrows: false)
        for _ in 0..<2 {
            _ = try await DatabaseBootService.prepare(
                environment: environment, clock: Date.init,
                snapshot: { recorder.record($0) }, progress: { _ in })
        }
        XCTAssertEqual(recorder.snapshots.count, 2, "每次尝试独立发射（重置语义由模型层 bootSnapshot=nil 承担）")
    }
}
