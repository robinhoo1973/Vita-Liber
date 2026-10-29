import Foundation
import os
import Domain
import Infrastructure

/// 启动门阶段（UI 只消费本枚举，不读底层实现细节）。
enum DatabaseBootPhase: Equatable, Sendable {
    case idle
    case rebuildingHistory
    case probing
    case creating
    case migrating(from: Int, to: Int)
    case verifying
    case assembling
    case catalogChoice
    case ready
}

enum DatabaseBootFailure: Error, Equatable, Sendable {
    case missingWithOriginals
    /// B0（2026-10-29）：多个注册名数据库文件并存——无法证明哪份是最新档案，
    /// 拒绝猜测（不按 mtime/大小挑），需用户人工核对保留一份。
    case databaseAmbiguous(names: [String])
    case corrupt(String)
    case tooNew(found: Int, supported: Int)
    case migrationIncomplete(found: Int, expected: Int)
    case openFailed(String)
    case unexpected(String)
}

struct DatabaseBootDiagnostics: Sendable, Equatable {
    let historyAvailable: Bool
    let historyStepCount: Int
    let registeredDatabases: Int
    let observedDatabases: Int
    let sourceVersion: Int?
    let targetVersion: Int
    let decision: String
    /// 三切片启动探测（2026-10-28 切片-only）：每片自洽态 + 就绪计数。
    /// 「就绪」= 该片 `CatalogSliceProbe.inspectSelfConsistent` 通过（表集/契约/完整性/COUNT）。
    let catalogSliceReadyCount: Int
    /// 就绪切片 kind 原始值（带身份；v4 替代集判据/诊断用——勿以计数判语义）。
    let catalogSliceReadyKinds: [String]
    let catalogSliceStates: [String]
    // T8（⓪ 批）：`legacyCatalogResidueCleaned` 字段删除——清理执行点移到
    // DatabaseBootModel（live 成功后），诊断结构不再承载该布尔（零消费方）。
}

struct PreparedDatabase: Sendable {
    let store: GRDBStore
    /// 批 ③（2026-10-29）：切片全验实测健康（open 后采集；final 快照唯一真源）。
    let sliceHealth: [CatalogSliceKind: CatalogSliceBootHealth]
    let diagnostics: DatabaseBootDiagnostics
}

/// 启动数据库编排：历史库重建 → 物理探测 → 决策 → 唯一迁移入口 `GRDBStore` → 目标复核。
///
/// 全部重活在 detached task 执行，主线程只收阶段进度；迁移决策只信物理库。
enum DatabaseBootService {
    private static let logger = Logger(subsystem: "com.vitaliber", category: "database-boot")

    /// 启动门可测性契约（启动时序批 ①，2026-10-29；测试席裁定终稿）。
    ///
    /// 六个闭包=全部副作用面：路径解析/历史库路径/切片路径/原件证据/患者探针/
    /// 切片探针/唯一迁移入口。生产 `.live` 逐项转发现有静态实现；测试注入
    /// 临时目录与 spy（断言 advisory 先于 open、失败零探针、final 取实测）。
    /// 不携带 FileManager（非 Sendable；生产沿用 .default，测试以闭包内嵌路径）。
    struct BootEnvironment: Sendable {
        var resolveDatabasePath: @Sendable () throws -> AppContainer.ResolvedDatabasePath
        var schemaHistoryPath: @Sendable () -> String
        var catalogSlicePath: @Sendable (String) -> String
        var originalsPresent: @Sendable () -> Bool
        var probePatient: @Sendable (String, Bool) -> DatabaseProbeSnapshot
        var probeSlice: @Sendable (CatalogSliceKind, String) -> CatalogSliceBootHealth
        var open: @Sendable (String, Int?, Int) throws -> GRDBStore

        static let live = BootEnvironment(
            resolveDatabasePath: { try AppContainer.resolveDatabasePath() },
            schemaHistoryPath: { AppContainer.defaultSchemaHistoryPath() },
            catalogSlicePath: { v5CatalogPath($0) },
            originalsPresent: { hasOriginalsEvidence() },
            probePatient: { path, originals in
                DatabaseProbe.inspect(path: path,
                                      requiredTables: DatabaseBootPolicy.requiredTables,
                                      originalsPresent: originals)
            },
            probeSlice: { kind, path in
                bootHealth(CatalogSliceProbe.inspectSelfConsistent(path: path, kind: kind))
            },
            open: { path, source, target in
                try DatabaseUpgradeService.open(at: path, from: source, to: target,
                                                requiredTables: DatabaseBootPolicy.requiredTables)
            })
    }

    static func prepare(environment: BootEnvironment = .live,
                        clock: @escaping @Sendable () -> Date = Date.init,
                        snapshot: @escaping @Sendable (BootChecklistSnapshot) async -> Void = { _ in },
                        progress: @escaping @Sendable (DatabaseBootPhase) async -> Void) async throws -> PreparedDatabase {
        try await Task.detached(priority: .userInitiated) {
            try await prepareSync(environment: environment, clock: clock,
                                  snapshot: snapshot, progress: progress)
        }.value
    }

    private static func prepareSync(environment: BootEnvironment,
                                    clock: @escaping @Sendable () -> Date,
                                    snapshot: @escaping @Sendable (BootChecklistSnapshot) async -> Void,
                                    progress: @escaping @Sendable (DatabaseBootPhase) async -> Void) async throws -> PreparedDatabase {
        // 路径解析必须先于探测：legacy 改名有副作用，失败会回退旧路径；
        // ≥2 个注册名候选并存 = 可解释失败（B0 名字全集，绝不静默建空库）。
        let resolution: AppContainer.ResolvedDatabasePath
        do {
            resolution = try environment.resolveDatabasePath()
        } catch AppContainer.DatabasePathError.ambiguousCandidates(let names) {
            throw DatabaseBootFailure.databaseAmbiguous(names: names)
        }
        let databasePath = resolution.path
        let historyPath = environment.schemaHistoryPath()

        // 1) 历史库：存在则清空，按代码内压缩 base64 SQL 重建。
        // 批 ⑤ 遥测：阶段耗时桶（仅终止事件携带；单次 append 不扰动时序）。
        var phaseTimings: [MigrationReceipt.Event.Phase] = []
        let historyStart = clock()
        await progress(.rebuildingHistory)
        let history: SchemaHistoryStore?
        do {
            history = try SchemaHistoryStore.rebuild(at: historyPath)
        } catch {
            // 非权威投影：重建失败只降级诊断，不让患者库陪葬。
            logger.error("schema history rebuild failed: \(String(describing: error), privacy: .public)")
            history = nil
        }
        phaseTimings.append(.init(name: "history",
                                  durationMs: clock().timeIntervalSince(historyStart) * 1000,
                                  status: history == nil ? "failed" : "ok"))

        // 2) 按历史库注册表逐库探测；患者库的最终决策仍以物理探测为准。
        await progress(.probing)
        let probeStart = clock()
        let originalsPresent = environment.originalsPresent()
        let userProbe = environment.probePatient(databasePath, originalsPresent)
        phaseTimings.append(.init(name: "patientProbe",
                                  durationMs: clock().timeIntervalSince(probeStart) * 1000,
                                  status: "ok"))
        // 切片探测已移到患者库 open/迁移成功之后（启动时序批 ③，2026-10-29）：
        // 决策/open 本就不依赖探针（advisory 只喂 UI），旧序让 corrupt/tooNew 等
        // 失败路径先付 GB 全扫才出失败卡。此处先声明，do 内成功后填充。
        var sliceStates: [(kind: CatalogSliceKind, health: CatalogSliceBootHealth)] = []
        var sliceHealth: [CatalogSliceKind: CatalogSliceBootHealth] = [:]
        var sliceReadyKinds: Set<CatalogSliceKind> = []
        var sliceReady = 0
        var v5Present = 0
        // T8（启动时序批 ⓪，2026-10-29）：v4 残留清理已移出 prepare——旧实现跑在
        // 失败判定之前，失败启动仍删 v4 文件（违「迁移失败=只读降级」）。现由
        // `DatabaseBootModel` 在 live + facade 提交成功后调用（失败路径零删除）。

        var registeredCount = 0
        if let history {
            do {
                let contents = try history.contents()
                registeredCount = contents.registry.count
                for entry in contents.registry {
                    let path: String?
                    switch entry.role {
                    case "user-data": path = databasePath
                    case "schema-history": path = historyPath
                    case "medical-catalog-v5": path = v5CatalogPath(entry.name)
                    default: path = nil
                    }
                    guard let path else { continue }
                    let probe = path == databasePath
                        ? userProbe
                        : DatabaseProbe.inspect(path: path, requiredTables: [], originalsPresent: false)
                    try history.record(.init(
                        name: entry.name, role: entry.role, exists: probe.exists,
                        sizeBytes: probe.sizeBytes, headerValid: probe.headerValid,
                        observedVersion: probe.observedVersion,
                        requiredTables: probe.requiredTablesPresent))
                }
            } catch {
                logger.error("schema history read/write failed: \(String(describing: error), privacy: .public)")
            }
        }

        // 3) 决策：物理库 + 代码版本，历史库观测不参与。
        let decision = DatabaseBootPolicy.decide(
            userProbe, supportedVersion: SchemaMigrations.latestVersion)
        let targetVersion = SchemaMigrations.latestVersion
        record(history, databasePath: databasePath, source: userProbe.observedVersion,
               target: targetVersion, outcome: "decision", detail: label(decision))
        // B3 启动收据（2026-10-29）：跨启动唯一取证通道（历史库每启动重建）。
        // 先写 in-progress，终止事件在成功/失败路径补齐；末行无终止 = 死在迁移中。
        // 取证失败只降级诊断，绝不阻断启动（收据不是启动闸）。
        let receipt = try? MigrationReceipt.standard() // try?-ok: 取证通道失败不阻断启动
        let receiptBootId = UUID().uuidString
        let receiptChosen = URL(fileURLWithPath: databasePath).lastPathComponent
        receiptAppend(receipt, bootId: receiptBootId, resolution: resolution.candidates,
                      chosen: receiptChosen, mode: label(decision),
                      source: userProbe.observedVersion, target: targetVersion,
                      outcome: .inProgress)
        // U-批 B2（架构席 S1/B2）：advisory 快照在决策后、switch/抛出前发射——
        // 失败路径也能拿到存在性/版本/健康事实（行①/②由它 + failure 推导）。
        let plannedSteps: Int?
        if case .migrate(let from, _) = decision {
            plannedSteps = SchemaMigrations.pending(from: from).count
        } else {
            plannedSteps = nil
        }
        await snapshot(BootChecklistSnapshot(
            probe: userProbe, decision: decision, decisionLabel: label(decision),
            plannedMigrationSteps: plannedSteps, sliceHealth: [:], committedKinds: []))

        // 批 ④（2026-10-29）：`.ready` 决策下切片全验与患者库 open 并发启动——
        // 非结构化 Task（TaskGroup 作用域退出必等不可取消的 integrity 跑完，
        // 会把失败卡拖到全验后——架构席否决结构化并发）；失败路径 cancel 且
        // **不 await**（defer 兜底）；成功路径在开关后收编。单发调用、无跨尝试
        // 共享状态，故无需代际令牌；L2 signpost 实测互扰（>20% 则回退串行）。
        var sliceProbeTask: Task<[(kind: CatalogSliceKind, health: CatalogSliceBootHealth)], Never>?
        defer { sliceProbeTask?.cancel() }
        let openStart = clock()
        let store: GRDBStore
        do {
            switch decision {
            case .missingWithOriginals:
                throw DatabaseBootFailure.missingWithOriginals
            case .tooNew(let found, let supported):
                throw DatabaseBootFailure.tooNew(found: found, supported: supported)
            case .corrupt(let reason):
                throw DatabaseBootFailure.corrupt(reason.rawValue)
            case .fresh:
                await progress(.creating)
                store = try environment.open(databasePath, nil, targetVersion)
                await progress(.verifying)
            case .ready(let version):
                // 批 ④：读路径（最常见）并发起全验；迁移/建库保持串行（GB 扫描
                // 挤占缓存会抬迁移 P95——开发/SRE 席裁定）。
                sliceProbeTask = Self.startSliceProbes(environment: environment)
                store = try environment.open(databasePath, version, targetVersion)
                await progress(.verifying)
            case .migrate(let from, let to):
                await progress(.migrating(from: from, to: to))
                store = try environment.open(databasePath, from, to)
                // 阶段标签如实反映已完成的工作（2026-10-27 审查 P3）：
                // .verifying 只在 open 返回后发出，迁移期间不会被误报成「核对」。
                await progress(.verifying)
            }
            phaseTimings.append(.init(name: "open.\(label(decision))",
                                      durationMs: clock().timeIntervalSince(openStart) * 1000,
                                      status: "ok"))
            let sliceStart = clock()
            // 批 ③（2026-10-29）：患者库信任闸全序完成后再做切片自洽全验
            // （表集/契约/完整性/FK/COUNT）——失败路径不再先付 GB 全扫；
            // 全验仍在 publish 前完成（Q14=B 字面满足，见 ADR-041 措辞）。
            // 批 ④：`.ready` 已并发启动则收编其结果；其余决策此处串行收尾。
            if let sliceProbeTask {
                sliceStates = await sliceProbeTask.value
            } else {
                sliceStates = CatalogSliceKind.allCases.map { kind in
                    (kind, environment.probeSlice(kind, environment.catalogSlicePath(kind.sqliteEntryName)))
                }
            }
            sliceHealth = Dictionary(uniqueKeysWithValues: sliceStates.map { ($0.kind, $0.health) })
            phaseTimings.append(.init(name: "sliceVerify",
                                      durationMs: clock().timeIntervalSince(sliceStart) * 1000,
                                      status: "ok"))
            sliceReadyKinds = Set(sliceStates.filter { $0.health == .ready }.map(\.kind))
            sliceReady = sliceReadyKinds.count
            v5Present = sliceStates.filter { $0.health != .missing }.count
            record(history, databasePath: databasePath, source: userProbe.observedVersion,
                   target: targetVersion, outcome: "success", detail: nil)
            receiptAppend(receipt, bootId: receiptBootId, resolution: resolution.candidates,
                          chosen: receiptChosen, mode: label(decision),
                          source: userProbe.observedVersion, target: targetVersion,
                          outcome: .success, phases: phaseTimings)
        } catch let boot as DatabaseBootFailure {
            throw boot
        } catch let upgrade as DatabaseUpgradeError {
            let found: Int?
            let expected: Int
            switch upgrade {
            case .sourceMismatch(let e, let f): found = f; expected = e
            case .targetMismatch(let e, let f): found = f; expected = e
            case .missingRequiredTables: found = userProbe.observedVersion; expected = targetVersion
            }
            record(history, databasePath: databasePath, source: userProbe.observedVersion,
                   target: targetVersion, outcome: "verify-failed",
                   detail: "found=\(found.map(String.init) ?? "nil") expected=\(expected)")
            receiptAppend(receipt, bootId: receiptBootId, resolution: resolution.candidates,
                          chosen: receiptChosen, mode: label(decision),
                          source: userProbe.observedVersion, target: targetVersion,
                          outcome: .verifyFailed,
                          detail: "found=\(found.map(String.init) ?? "nil") expected=\(expected)",
                          phases: phaseTimings)
            throw DatabaseBootFailure.migrationIncomplete(
                found: found ?? -1, expected: expected)
        } catch {
            record(history, databasePath: databasePath, source: userProbe.observedVersion,
                   target: targetVersion, outcome: "open-failed",
                   detail: String(describing: error))
            receiptAppend(receipt, bootId: receiptBootId, resolution: resolution.candidates,
                          chosen: receiptChosen, mode: label(decision),
                          source: userProbe.observedVersion, target: targetVersion,
                          outcome: .openFailed, detail: String(describing: error),
                          phases: phaseTimings)
            throw DatabaseBootFailure.openFailed(String(describing: error))
        }

        let decisionLabel = label(decision)
        let historyStepCount: Int
        if let history {
            historyStepCount = (try? history.contents().steps.count) ?? 0 // try?-ok: 诊断计数失败=0，不影响启动
        } else {
            historyStepCount = 0
        }
        return PreparedDatabase(
            store: store,
            sliceHealth: sliceHealth,
            diagnostics: DatabaseBootDiagnostics(
                historyAvailable: history != nil,
                historyStepCount: historyStepCount,
                registeredDatabases: registeredCount,
                observedDatabases: 1 + v5Present,
                sourceVersion: userProbe.observedVersion,
                targetVersion: targetVersion,
                decision: decisionLabel,
                catalogSliceReadyCount: sliceReady,
                catalogSliceReadyKinds: sliceReadyKinds.map(\.rawValue).sorted(),
                catalogSliceStates: sliceStates.map { "\($0.kind.rawValue):\($0.health.diagnosticLabel)" }))
    }

    // P-批：死列表 `v5CatalogNames`（三片手写名）已删除——命名一律由
    // `CatalogSliceKind.stem` 派生（registry 探测走 sliceStates，无第二真源）。

    /// 批 ④：切片全验并发入口（utility 优先级——不与患者库路径抢 QoS）。
    /// 失败时调用方不 await、仅 cancel：同步 GRDB 读不可中断，协作取消只省电。
    private static func startSliceProbes(environment: BootEnvironment)
        -> Task<[(kind: CatalogSliceKind, health: CatalogSliceBootHealth)], Never> {
        Task.detached(priority: .utility) {
            CatalogSliceKind.allCases.map { kind in
                (kind, environment.probeSlice(kind, environment.catalogSlicePath(kind.sqliteEntryName)))
            }
        }
    }

    private static func v5CatalogPath(_ name: String,
                                      fileManager: FileManager = .default) -> String {
        let base = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("VitaLiber/catalog/v5", isDirectory: true)
            .appendingPathComponent(name).path
    }

    private static func bootHealth(_ state: CatalogSliceProbe.State) -> CatalogSliceBootHealth {
        switch state {
        case .missing: return .missing
        case .unreadable: return .unreadable
        case .contractViolation: return .contractViolation
        case .tableSetMismatch: return .tableSetMismatch
        case .integrityFailed: return .integrityFailed
        case .countsMismatch: return .countsMismatch
        case .ready: return .ready
        }
    }

    private static func hasOriginalsEvidence() -> Bool {
        // 双根证据（2026-10-27 存储边界）：canonical（App Support/Media）与
        // 旧根（Documents/MedicalNotes，v49 前装机）任一有真实文件即算证据。
        let roots = [AppContainer.defaultOriginalsDir(),
                     MediaRootPaths.legacyMedicalNotesRoot()]
        // 只认 originals/ 与 sensitive/ 下的真实文件：空目录/隐藏文件不是证据
        // （data-flow §13.1 双布局判据；根目录本身存在不能让新装机误判为丢库）。
        for directory in roots {
            for sub in ["originals", "sensitive"] {
                let path = directory.appendingPathComponent(sub, isDirectory: true).path
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] // try?-ok: 目录不可读=无原件证据
                if contents.contains(where: { !$0.hasPrefix(".") }) { return true }
            }
        }
        return false
    }

    /// B3 收据追加（失败只告警——取证通道不阻断启动）。
    private static func receiptAppend(_ receipt: MigrationReceipt?, bootId: String,
                                      resolution: [String], chosen: String?, mode: String,
                                      source: Int?, target: Int?,
                                      outcome: MigrationReceipt.Event.Outcome,
                                      detail: String? = nil,
                                      phases: [MigrationReceipt.Event.Phase] = []) {
        guard let receipt else { return }
        do {
            try receipt.append(.init(bootId: bootId, at: clock().timeIntervalSince1970,
                                     candidates: resolution, chosen: chosen, mode: mode,
                                     sourceVersion: source, targetVersion: target,
                                     outcome: outcome, detail: detail,
                                     phases: phases.isEmpty ? nil : phases))
        } catch {
            logger.warning("migration receipt write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func record(_ history: SchemaHistoryStore?, databasePath: String,
                               source: Int?, target: Int?, outcome: String, detail: String?) {
        guard let history else { return }
        do {
            try history.recordAttempt(.init(
                databaseName: URL(fileURLWithPath: databasePath).lastPathComponent,
                sourceVersion: source, targetVersion: target,
                outcome: outcome, detail: detail))
        } catch {
            logger.warning("schema history attempt write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func label(_ decision: DatabaseBootDecision) -> String {
        switch decision {
        case .fresh: return "fresh"
        case .ready(let version): return "ready-v\(version)"
        case .migrate(let from, let to): return "migrate-v\(from)-to-v\(to)"
        case .tooNew(let found, let supported): return "too-new-v\(found)-gt-v\(supported)"
        case .missingWithOriginals: return "missing-with-originals"
        case .corrupt(let reason): return "corrupt-\(reason.rawValue)"
        }
    }
}
