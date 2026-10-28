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
    /// 三片全就绪并已执行 v4 残留清理（启动前置；失败只记日志，不阻断）。
    let legacyCatalogResidueCleaned: Bool
}

struct PreparedDatabase: Sendable {
    let store: GRDBStore
    let diagnostics: DatabaseBootDiagnostics
}

/// 启动数据库编排：历史库重建 → 物理探测 → 决策 → 唯一迁移入口 `GRDBStore` → 目标复核。
///
/// 全部重活在 detached task 执行，主线程只收阶段进度；迁移决策只信物理库。
enum DatabaseBootService {
    private static let logger = Logger(subsystem: "com.vitaliber", category: "database-boot")

    static func prepare(snapshot: @escaping @Sendable (BootChecklistSnapshot) async -> Void = { _ in },
                        progress: @escaping @Sendable (DatabaseBootPhase) async -> Void) async throws -> PreparedDatabase {
        try await Task.detached(priority: .userInitiated) {
            try await prepareSync(snapshot: snapshot, progress: progress)
        }.value
    }

    private static func prepareSync(snapshot: @escaping @Sendable (BootChecklistSnapshot) async -> Void,
                                    progress: @escaping @Sendable (DatabaseBootPhase) async -> Void) async throws -> PreparedDatabase {
        // 路径解析必须先于探测：legacy 改名有副作用，失败会回退旧路径；
        // ≥2 个注册名候选并存 = 可解释失败（B0 名字全集，绝不静默建空库）。
        let resolution: AppContainer.ResolvedDatabasePath
        do {
            resolution = try AppContainer.resolveDatabasePath()
        } catch AppContainer.DatabasePathError.ambiguousCandidates(let names) {
            throw DatabaseBootFailure.databaseAmbiguous(names: names)
        }
        let databasePath = resolution.path
        let historyPath = AppContainer.defaultSchemaHistoryPath()

        // 1) 历史库：存在则清空，按代码内压缩 base64 SQL 重建。
        await progress(.rebuildingHistory)
        let history: SchemaHistoryStore?
        do {
            history = try SchemaHistoryStore.rebuild(at: historyPath)
        } catch {
            // 非权威投影：重建失败只降级诊断，不让患者库陪葬。
            logger.error("schema history rebuild failed: \(String(describing: error), privacy: .public)")
            history = nil
        }

        // 2) 按历史库注册表逐库探测；患者库的最终决策仍以物理探测为准。
        await progress(.probing)
        let originalsPresent = hasOriginalsEvidence()
        let userProbe = DatabaseProbe.inspect(
            path: databasePath,
            requiredTables: DatabaseBootPolicy.requiredTables,
            originalsPresent: originalsPresent)
        // 三切片探测（2026-10-28 切片-only）：切片库只有 slice_meta，绝不回落 v4 的
        // catalog_meta/user_version 语义——每片自洽校验（表集/契约/完整性/COUNT）。
        let sliceStates: [(kind: CatalogSliceKind, health: CatalogSliceBootHealth)] =
            CatalogSliceKind.allCases.map { kind in
                let state = CatalogSliceProbe.inspectSelfConsistent(
                    path: v5CatalogPath(kind.sqliteEntryName), kind: kind)
                return (kind, Self.bootHealth(state))
            }
        let sliceHealth = Dictionary(uniqueKeysWithValues: sliceStates.map { ($0.kind, $0.health) })
        let sliceReadyKinds = Set(sliceStates.filter { $0.health == .ready }.map(\.kind))
        let sliceReady = sliceReadyKinds.count
        let v5Present = sliceStates.filter { $0.health != .missing }.count
        // 「自动迁移前一数据库」（2026-10-28；P-批按 kind 子集）：v4 替代集
        // {drug,facility,reference} 全就绪才清 v4 残留；profile 不参与；未替换前绝不删。
        let legacyResidueCleaned = LegacyCatalogResidue.cleanIfEligible(readyKinds: sliceReadyKinds)

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
            plannedMigrationSteps: plannedSteps, sliceHealth: sliceHealth,
            facadeCommitted: false))

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
                store = try DatabaseUpgradeService.open(
                    at: databasePath, from: nil, to: targetVersion,
                    requiredTables: DatabaseBootPolicy.requiredTables)
                await progress(.verifying)
            case .ready(let version):
                store = try DatabaseUpgradeService.open(
                    at: databasePath, from: version, to: targetVersion,
                    requiredTables: DatabaseBootPolicy.requiredTables)
                await progress(.verifying)
            case .migrate(let from, let to):
                await progress(.migrating(from: from, to: to))
                store = try DatabaseUpgradeService.open(
                    at: databasePath, from: from, to: to,
                    requiredTables: DatabaseBootPolicy.requiredTables)
                // 阶段标签如实反映已完成的工作（2026-10-27 审查 P3）：
                // .verifying 只在 open 返回后发出，迁移期间不会被误报成「核对」。
                await progress(.verifying)
            }
            record(history, databasePath: databasePath, source: userProbe.observedVersion,
                   target: targetVersion, outcome: "success", detail: nil)
            receiptAppend(receipt, bootId: receiptBootId, resolution: resolution.candidates,
                          chosen: receiptChosen, mode: label(decision),
                          source: userProbe.observedVersion, target: targetVersion,
                          outcome: .success)
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
                          detail: "found=\(found.map(String.init) ?? "nil") expected=\(expected)")
            throw DatabaseBootFailure.migrationIncomplete(
                found: found ?? -1, expected: expected)
        } catch {
            record(history, databasePath: databasePath, source: userProbe.observedVersion,
                   target: targetVersion, outcome: "open-failed",
                   detail: String(describing: error))
            receiptAppend(receipt, bootId: receiptBootId, resolution: resolution.candidates,
                          chosen: receiptChosen, mode: label(decision),
                          source: userProbe.observedVersion, target: targetVersion,
                          outcome: .openFailed, detail: String(describing: error))
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
                catalogSliceStates: sliceStates.map { "\($0.kind.rawValue):\($0.health.diagnosticLabel)" },
                legacyCatalogResidueCleaned: legacyResidueCleaned))
    }

    // P-批：死列表 `v5CatalogNames`（三片手写名）已删除——命名一律由
    // `CatalogSliceKind.stem` 派生（registry 探测走 sliceStates，无第二真源）。

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
                                      detail: String? = nil) {
        guard let receipt else { return }
        do {
            try receipt.append(.init(bootId: bootId, at: Date().timeIntervalSince1970,
                                     candidates: resolution, chosen: chosen, mode: mode,
                                     sourceVersion: source, targetVersion: target,
                                     outcome: outcome, detail: detail))
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
