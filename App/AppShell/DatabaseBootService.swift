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
    case ready
}

enum DatabaseBootFailure: Error, Equatable, Sendable {
    case missingWithOriginals
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
    let catalogPresent: Bool
    let catalogVersion: Int?
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

    static func prepare(progress: @escaping @Sendable (DatabaseBootPhase) async -> Void) async throws -> PreparedDatabase {
        try await Task.detached(priority: .userInitiated) {
            try await prepareSync(progress: progress)
        }.value
    }

    private static func prepareSync(progress: @escaping @Sendable (DatabaseBootPhase) async -> Void) async throws -> PreparedDatabase {
        // 路径解析必须先于探测：f7 的 legacy 改名有副作用，失败会回退旧路径。
        let databasePath = AppContainer.defaultDatabasePath()
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
        let catalogPath = AppContainer.defaultMedicalCatalogPath()
        let catalogProbe = DatabaseProbe.inspect(
            path: catalogPath, requiredTables: [], originalsPresent: false)
        let historyProbe = DatabaseProbe.inspect(
            path: historyPath, requiredTables: [], originalsPresent: false)

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
                    case "medical-catalog": path = catalogPath
                    default: path = nil
                    }
                    guard let path else { continue }
                    let probe = path == databasePath ? userProbe
                        : path == historyPath ? historyProbe
                        : catalogProbe
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
                await progress(.verifying)
                store = try DatabaseUpgradeService.open(
                    at: databasePath, from: nil, to: targetVersion,
                    requiredTables: DatabaseBootPolicy.requiredTables)
            case .ready(let version):
                await progress(.verifying)
                store = try DatabaseUpgradeService.open(
                    at: databasePath, from: version, to: targetVersion,
                    requiredTables: DatabaseBootPolicy.requiredTables)
            case .migrate(let from, let to):
                await progress(.migrating(from: from, to: to))
                await progress(.verifying)
                store = try DatabaseUpgradeService.open(
                    at: databasePath, from: from, to: to,
                    requiredTables: DatabaseBootPolicy.requiredTables)
            }
            record(history, databasePath: databasePath, source: userProbe.observedVersion,
                   target: targetVersion, outcome: "success", detail: nil)
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
            throw DatabaseBootFailure.migrationIncomplete(
                found: found ?? -1, expected: expected)
        } catch {
            record(history, databasePath: databasePath, source: userProbe.observedVersion,
                   target: targetVersion, outcome: "open-failed",
                   detail: String(describing: error))
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
                observedDatabases: 3,
                sourceVersion: userProbe.observedVersion,
                targetVersion: targetVersion,
                decision: decisionLabel,
                catalogPresent: catalogProbe.exists && catalogProbe.headerValid && catalogProbe.sizeBytes > 0,
                catalogVersion: catalogProbe.observedVersion))
    }

    private static func hasOriginalsEvidence() -> Bool {
        let directory = AppContainer.defaultOriginalsDir()
        // 只认 originals/ 与 sensitive/ 下的真实文件：空目录/隐藏文件不是证据
        // （data-flow §13.1 双布局判据；根目录本身存在不能让新装机误判为丢库）。
        for sub in ["originals", "sensitive"] {
            let path = directory.appendingPathComponent(sub, isDirectory: true).path
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] // try?-ok: 目录不可读=无原件证据
            if contents.contains(where: { !$0.hasPrefix(".") }) { return true }
        }
        return false
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
