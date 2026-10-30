import Foundation
import Combine
import SwiftUI
import UIKit
import Domain
import Infrastructure

/// 启动门表现态：只有 `container` 非 nil 才允许挂载主界面。
///
/// 会话所有权（2026-10-27 审查 P1/P2）：启动门是唯一创建 `AppSession` 的地方——
/// 无论是否显示可选目录卡、无论 UI 是否首帧渲染（后台冷启动），容器就绪即
/// 通过 `sessionFactory` 建立会话并安装到 `AppSessionHolder`。`ReadyAppRoot`
/// 只复用 holder 中的实例，避免双 `MedicalCatalogState` 与后台作业无会话来源。
@MainActor
final class DatabaseBootModel: ObservableObject {
    @Published private(set) var phase: DatabaseBootPhase = .idle
    @Published private(set) var container: AppContainer?
    @Published private(set) var failure: DatabaseBootFailure?
    @Published private(set) var diagnostics: DatabaseBootDiagnostics?
    @Published private(set) var isRunning = false
    /// 本地库已就绪但参考目录缺失/版本不匹配时的显式可选步骤。
    @Published private(set) var awaitingCatalogChoice = false
    /// 三切片目录状态（2026-10-28 切片-only）：首启卡/会话/环境的唯一目录态。
    @Published private(set) var catalogSlices: CatalogSlicesState?
    /// U-批 B2：启动自检事实快照（advisory→final，架构席 S1/B2 定稿）。
    @Published private(set) var bootSnapshot: BootChecklistSnapshot?
    /// 只读降级容器（2026-10-28 B2）：仅 tooNew 且只读打开成功时非 nil
    /// （显式「只读查看」入口的可用判据；不建会话、不 install holder）。
    @Published private(set) var readOnlyContainer: AppContainer?
    /// 只读壳路由开关（VitaLiberApp body 用；enterReadOnly 置真）。
    @Published private(set) var isShowingReadOnly = false
    /// 损坏库恢复（业主 2026-10-30）：文件级操作进行中（打包/校验/替换/恢复）。
    @Published private(set) var recoveryBusy = false
    /// 已暂存、待确认导入的修复文件（用户确认前不触碰本机患者库）。
    private var stagedRepairedPath: String?
    /// 已校验、待确认恢复的备份（确认后删除损坏库并重建导入）。
    private var stagedBackupRestore: BackupService.VerifiedBackup?
    /// 启动内待执行备份恢复（重建空库成功后、发布前导入）。
    private var pendingBackupRestore: BackupService.VerifiedBackup?
    /// UI 交接门（U-批 B2，B1 口径「页先于主 UI 可见」）：默认 true——主 UI 在
    /// `finishBootScreen()` 前不挂载；session 在 publish 即建、页下存在。
    @Published private(set) var isShowingBootScreen = true
    private var pendingContainer: AppContainer?
    /// 自检页首帧呈现时刻（onAppear 上报；headless 无首帧保持 nil）。
    private var selfCheckPresentedAt: Date?

    private let sessionFactory: ((AppContainer, CatalogSlicesState) -> AppSession)?
    /// 「暂不下载，继续」的延期偏好（UI 偏好，非医疗数据；UserDefaults 不入备份）。
    static let deferredPromptKey = "catalogPromptDeferredAt"
    private let defaults: UserDefaults
    private let now: () -> Date
    private let autoEnter = CatalogAutoEnterScheduler()
    /// 启动门注入缝（启动时序批 ①，2026-10-29）：默认直连 DatabaseBootService；
    /// 测试注入假实现以断言快照序列（advisory 先于 open、final 取实测等）。
    private let prepareDatabase: @Sendable (@escaping @Sendable (BootChecklistSnapshot) async -> Void,
                                             @escaping @Sendable (DatabaseBootPhase) async -> Void)
        async throws -> PreparedDatabase
    /// 被动交接的终态时刻（首排时落定；恢复锚点已过期时不得立即交接，批 ②）。
    private var bootTerminalAt: Date?
    /// 批 ③：open 后实测的切片健康（final 快照唯一真源）。
    private var preparedSliceHealth: [CatalogSliceKind: CatalogSliceBootHealth] = [:]
    /// 摘要展开态（批 ②）：展开期间冻结被动交接；收起后按 resumeAnchor 恢复。
    @Published private(set) var isSelfCheckSummaryExpanded = false

    /// B4 hold 钩子对视图可见化（DEBUG）：hold 期间强制展开四行（既有 UI 用例依赖）。
    /// 两段式稳态用例用 `-uitest-selfcheck-hold-summary`：冻结交接但允许折叠摘要。
    var debugHoldForcesExpanded: Bool { uiTestSelfCheckHold }

    /// `-uitest-selfcheck-hold-summary`：冻结被动交接与卡片 autoEnter，
    /// 但不强制展开四行——用于「二启稳态折叠摘要 → 展开 → 收起」用例。
    private var uiTestSelfCheckHoldSummary: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uitest-selfcheck-hold-summary")
        #else
        false
        #endif
    }

    private var isHandoffFrozenForUITest: Bool {
        uiTestSelfCheckHold || uiTestSelfCheckHoldSummary
    }

    init(sessionFactory: ((AppContainer, CatalogSlicesState) -> AppSession)? = nil,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         prepareDatabase: @escaping @Sendable (
             @escaping @Sendable (BootChecklistSnapshot) async -> Void,
             @escaping @Sendable (DatabaseBootPhase) async -> Void)
             async throws -> PreparedDatabase = { snapshot, progress in
                 try await DatabaseBootService.prepare(snapshot: snapshot, progress: progress)
             }) {
        self.sessionFactory = sessionFactory
        self.defaults = defaults
        self.now = now
        self.prepareDatabase = prepareDatabase
    }

    func start() async {
        guard !isRunning, container == nil, pendingContainer == nil else { return }
        isRunning = true
        failure = nil
        phase = .idle
        readOnlyContainer = nil
        isShowingReadOnly = false
        // B3 只读壳钩子（仅 DEBUG 生效）：合成 tooNew + 确保测试库存在 →
        // 只读打开 → 失败卡显示「只读查看」。
        if uiTestBootReadOnly {
            let unsupported = DatabaseBootFailure.tooNew(
                found: 99, supported: SchemaMigrations.latestVersion)
            bootSnapshot = BootChecklistSnapshot(
                probe: Self.uiTestFailureProbe,
                decision: .tooNew(found: 99, supported: SchemaMigrations.latestVersion),
                decisionLabel: "uitest-readonly", plannedMigrationSteps: nil,
                sliceHealth: [:], committedKinds: [])
            failure = unsupported
            let path = AppContainer.defaultDatabasePath()
            _ = try? GRDBStore.pool(at: path) // try?-ok: DEBUG 钩子确保测试库存在；生产路径不达
            if let store = try? GRDBStore.readOnly(at: path) { // try?-ok: 开败=不显入口（graceful）
                readOnlyContainer = AppContainer.readOnly(store: store)
            }
            AppSessionHolder.shared.fail()
            isRunning = false
            return
        }
        // B4 失败桩：不经真实启动门，直接落确定性失败态（advisory 语义同真实
        // 失败路径——快照 committedKinds 空，行③恒未校验）。
        if let injected = uiTestSelfCheckFailure {
            bootSnapshot = BootChecklistSnapshot(
                probe: Self.uiTestFailureProbe, decision: nil,
                decisionLabel: "uitest-injected", plannedMigrationSteps: nil,
                sliceHealth: [:], committedKinds: [])
            failure = injected
            AppSessionHolder.shared.fail()
            isRunning = false
            return
        }
        do {
            bootSnapshot = nil
            let prepared = try await prepareDatabase(
                { [weak self] advisory in
                    await MainActor.run { self?.bootSnapshot = advisory }
                },
                { [weak self] phase in
                    await MainActor.run { self?.phase = phase }
                })
            phase = .assembling
            let assembled = try AppContainer.live(store: prepared.store)
            // 损坏库恢复（业主 2026-10-30）：备份已校验 → 重建空库后、发布前导入。
            // 失败=保留空库并落可解释失败态（重试/导出/改走修复文件均仍可用）。
            if let restore = pendingBackupRestore {
                pendingBackupRestore = nil
                phase = .restoringBackup
                do {
                    _ = try await BackupService.restore(verified: restore, store: prepared.store)
                } catch {
                    throw DatabaseBootFailure.recoveryBackupFailed(String(describing: error))
                }
            }
            diagnostics = prepared.diagnostics
            preparedSliceHealth = prepared.sliceHealth
            self.catalogSlices = CatalogSlicesState(
                facade: assembled.catalogSlices ?? CatalogSliceReadFacade(),
                checker: assembled.catalogSliceChecker,
                updater: assembled.catalogSliceUpdater,
                receiptDirectory: URL(fileURLWithPath: AppContainer.defaultCatalogSliceDirectory(),
                                     isDirectory: true))
            // T8（启动时序批 ⓪，2026-10-29）：v4 残留清理后置到「live 成功 +
            // facade 提交」之后——失败/降级路径（catch 各分支）绝不触碰 v4 文件。
            // 判据仍=替代集三 kind 全就绪（带身份）；幂等、失败只记日志。
            let readyKinds = Set(prepared.diagnostics.catalogSliceReadyKinds
                .compactMap(CatalogSliceKind.init(rawValue:)))
            LegacyCatalogResidue.cleanIfEligible(readyKinds: readyKinds)
            if showsCatalogChoice(diagnostics: prepared.diagnostics) {
                pendingContainer = assembled
                awaitingCatalogChoice = true
                phase = .catalogChoice
            } else {
                publish(assembled)
            }
        } catch let boot as DatabaseBootFailure {
            failure = boot
            // 只读降级适格（B2）：仅 tooNew 且只读打开成功才给「只读查看」入口；
            // 打开失败（热 WAL 等）=graceful，不显入口（讨论稿 2026-10-28 round1）。
            if let decision = bootSnapshot?.decision,
               ReadOnlyDegradation.isEligible(decision) {
                if let store = try? GRDBStore.readOnly(at: AppContainer.defaultDatabasePath()) { // try?-ok: 只读开败=不显入口，绝不回落读写
                    readOnlyContainer = AppContainer.readOnly(store: store)
                }
            }
            AppSessionHolder.shared.fail()
        } catch is CancellationError {
            // 取消发生在 App 退出/重试边界：不得停在无重试出口的阶段页。
            if container == nil && pendingContainer == nil {
                failure = .unexpected("cancelled")
            }
            AppSessionHolder.shared.fail()
        } catch {
            failure = .unexpected(String(describing: error))
            AppSessionHolder.shared.fail()
        }
        isRunning = false
    }

    func retry() async {
        guard !isRunning else { return }
        failure = nil
        AppSessionHolder.shared.resetForRetry()
        await start()
    }

    // MARK: - 损坏数据库恢复（业主 2026-10-30 单独接口四动作）

    /// 失败卡是否提供「数据库修复…」入口：仅可解释的库文件损坏；
    /// 多库并存（需人工核对保留一份）与只读降级（数据可读）不提供。
    var canOfferDatabaseRepair: Bool {
        guard let failure else { return false }
        switch failure {
        case .corrupt, .openFailed, .recoveryBackupFailed:
            return true
        default:
            return false
        }
    }

    struct BackupInspection: Equatable, Sendable {
        let exportedAt: Date
        let totalRecords: Int
    }

    private struct StagedRepair: Sendable {
        let path: String
        let report: DatabaseRecoveryService.RepairReport
    }

    /// ① 损坏库打包（压缩包供用户自行修复/留档）：主库 + 伴生 + 非权威历史库。
    func makeCorruptDatabaseArchive() async throws -> URL {
        let path = try recoveryPatientPath()
        let history = AppContainer.defaultSchemaHistoryPath()
        var entries: [DatabaseRecoveryService.ZipEntry] = [
            .init(name: URL(fileURLWithPath: path).lastPathComponent, path: path)
        ]
        for suffix in DatabaseRecoveryService.sidecarSuffixes {
            let candidate = path + suffix
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            entries.append(.init(name: URL(fileURLWithPath: candidate).lastPathComponent,
                                 path: candidate))
        }
        if FileManager.default.fileExists(atPath: history) {
            entries.append(.init(name: URL(fileURLWithPath: history).lastPathComponent,
                                 path: history))
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitaliber-db-repair-\(Int(now().timeIntervalSince1970)).zip")
        return try await Task.detached(priority: .userInitiated) {
            try DatabaseRecoveryService.makeArchive(entries: entries, destination: destination)
        }.value
    }

    /// ② 校验用户修复后的文件（.sqlite / .zip）：先复制/解包到应用临时目录再校验
    /// （picker 的 security-scoped 权限只在本次回调内有效）。通过后暂存，等待确认。
    func inspectRepairedDatabase(at url: URL) async throws -> DatabaseRecoveryService.RepairReport {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitaliber-repair-inspect-\(UUID().uuidString)", isDirectory: true)
        let staged = try await Task.detached(priority: .userInitiated) { () -> StagedRepair in
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
            let candidate: URL
            if url.pathExtension.lowercased() == "zip" {
                candidate = try DatabaseRecoveryService.extractRepairedDatabase(
                    from: url, into: workDir)
            } else {
                candidate = workDir.appendingPathComponent("repaired.sqlite")
                try fileManager.copyItem(at: url, to: candidate)
            }
            let report = try DatabaseRecoveryService.validateRepairedDatabase(at: candidate)
            return StagedRepair(path: candidate.path, report: report)
        }.value
        stagedRepairedPath = staged.path
        return staged.report
    }

    /// ③ 用暂存的修复文件替换损坏库并重新启动（原损坏文件保留 .corrupt-<ts> 副本）。
    func applyStagedRepairAndRebuild() async throws {
        guard let repaired = stagedRepairedPath else { return }
        recoveryBusy = true
        defer { recoveryBusy = false }
        let patient = try recoveryPatientPath()
        try await Task.detached(priority: .userInitiated) {
            try DatabaseRecoveryService.install(repairedPath: repaired, patientPath: patient)
        }.value
        stagedRepairedPath = nil
        failure = nil
        AppSessionHolder.shared.resetForRetry()
        await start()
    }

    /// ④ 校验备份包（.vlbu / 旧 JSON）：无 writer 校验 + 摘要，供用户确认。
    func inspectBackupPackage(_ data: Data) async throws -> BackupInspection {
        let verified = try await Task.detached(priority: .userInitiated) {
            try BackupService.verifyPackage(data)
        }.value
        stagedBackupRestore = verified
        return BackupInspection(exportedAt: Date(timeIntervalSince1970: verified.exportedAt),
                                totalRecords: verified.totalRecords)
    }

    /// ④ 用暂存备份恢复：删除损坏库 → 重建空库 → 启动内导入 → 发布。
    func restoreStagedBackupAndRebuild() async throws {
        guard let verified = stagedBackupRestore else { return }
        recoveryBusy = true
        defer { recoveryBusy = false }
        let patient = try recoveryPatientPath()
        try await Task.detached(priority: .userInitiated) {
            try DatabaseRecoveryService.erasePatientDatabase(patientPath: patient)
        }.value
        stagedBackupRestore = nil
        failure = nil
        pendingBackupRestore = verified
        AppSessionHolder.shared.resetForRetry()
        await start()
    }

    /// ① 删除损坏库并重新生成空库（调用方必须先做数据丢失确认）。
    func eraseCorruptDatabaseAndRebuild() async throws {
        recoveryBusy = true
        defer { recoveryBusy = false }
        let patient = try recoveryPatientPath()
        try await Task.detached(priority: .userInitiated) {
            try DatabaseRecoveryService.erasePatientDatabase(patientPath: patient)
        }.value
        failure = nil
        AppSessionHolder.shared.resetForRetry()
        await start()
    }

    /// 关闭修复页时丢弃暂存（修复文件副本 / 已校验备份）。
    func discardStagedRecovery() {
        if let staged = stagedRepairedPath {
            try? FileManager.default.removeItem( // try?-ok: 临时目录清理，失败由系统回收
                at: URL(fileURLWithPath: staged).deletingLastPathComponent())
        }
        stagedRepairedPath = nil
        stagedBackupRestore = nil
    }

    private func recoveryPatientPath() throws -> String {
        try AppContainer.resolveDatabasePath().path
    }

    /// XCUITest 不能驱动首启可选卡；DEBUG 的 `-uitest-*` 默认自动继续。
    private var shouldAutoContinue: Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        return args.contains { $0.hasPrefix("-uitest-") } && !args.contains("-uitest-boot-catalog-choice")
        #else
        false
        #endif
    }

    private var forceCatalogChoice: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uitest-boot-catalog-choice")
        #else
        false
        #endif
    }

    // MARK: - 测试钩子（U-批 B4，2026-10-28；仅 DEBUG）

    /// `-uitest-selfcheck-hold`：显式冻结自检页——被动 hold 与卡片 autoEnter
    /// 均不触发（显式 hold 优先于通用 `-uitest-` 的立即放行）。
    private var uiTestSelfCheckHold: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uitest-selfcheck-hold")
        #else
        false
        #endif
    }

    /// `-uitest-selfcheck-failure=<case>`：prepare 桩——不起真实启动门，
    /// 直接落确定性失败态（corrupt/tooNew/missingOriginals/migrationIncomplete/
    /// openFailed/其它→unexpected），供失败卡 UI 用例。
    private var uiTestSelfCheckFailure: DatabaseBootFailure? {
        #if DEBUG
        let prefix = "-uitest-selfcheck-failure="
        for arg in ProcessInfo.processInfo.arguments where arg.hasPrefix(prefix) {
            switch arg.dropFirst(prefix.count) {
            case "corrupt": return .corrupt("uitest")
            case "tooNew": return .tooNew(found: 99, supported: SchemaMigrations.latestVersion)
            case "missingOriginals": return .missingWithOriginals
            case "migrationIncomplete":
                return .migrationIncomplete(found: 48, expected: SchemaMigrations.latestVersion)
            case "openFailed": return .openFailed("uitest")
            default: return .unexpected("uitest")
            }
        }
        return nil
        #else
        nil
        #endif
    }

    /// O21：通用 `-uitest-*` 默认不渲染自检页（立即放行主界面）；
    /// 显式 hold 或失败桩才保持自检页可见。
    private var uiTestInstantHandoff: Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        return args.contains { $0.hasPrefix("-uitest-") }
            && !isHandoffFrozenForUITest && uiTestSelfCheckFailure == nil
        #else
        false
        #endif
    }

    /// 失败桩用的合成探测事实（文件存在且版本正常——失败语义由注入 case 决定）。
    private static let uiTestFailureProbe = DatabaseProbeSnapshot(
        exists: true, sizeBytes: 4096, headerValid: true, observedVersion: 49,
        tableCount: 30, requiredTablesPresent: 3, requiredTablesExpected: 3,
        originalsPresent: false)

    /// `-uitest-boot-readonly`：B3 只读壳 UI 证据钩子——合成 tooNew 失败并
    /// 确保测试库存在（库创建属测试面，生产路径不可达），供失败卡→只读壳用例。
    private var uiTestBootReadOnly: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uitest-boot-readonly")
        #else
        false
        #endif
    }

    private func showsCatalogChoice(diagnostics: DatabaseBootDiagnostics) -> Bool {
        if forceCatalogChoice { return true }
        // XCUITest 不能驱动首启卡（契约见 shouldAutoContinue）——该逃生门必须先于强制分支：
        // 5eb279b0 把 mandatory 分支插在其上，使 `-uitest-*` 且 onboarding 标记读为未完成的
        // 用例被强制卡拦在首页之外（CI 40902338522：AssistantChat 5 例红，可及树仅
        // STARTUP.catalog.primary）。强制卡自身的 UI 覆盖走 -uitest-boot-catalog-choice
        // （forceCatalogChoice 仍最前）。
        if shouldAutoContinue { return false }
        // 审查席 P1：强制首启下载（当前库为空 ∧ 第一次启动）优先于 7 天延期
        // ——否则「离线先进入」写下的延期会把业主强制策略在联网重启后静默绕过。
        if mandatoryFirstLaunchDownload { return true }
        // 切片-only（2026-10-28；P-批四片）：v4 替代集 `{drug,facility,reference}` 全就绪
        // 即视为「无需引导」——按 kind 子集判定（计数会随加片漂移）；profile 第四片按
        // 业主项 O4 建议为「可选但常显」，不阻塞首启卡（若 O4 裁决改为四片必需，在此调整）。
        let readyKinds = Set(diagnostics.catalogSliceReadyKinds)
        if Set(CatalogSliceKind.legacyReplacedKinds.map(\.rawValue)).isSubset(of: readyKinds)
            || shouldAutoContinue {
            return false
        }
        // 「稍后再说」在延期窗口内不再每次冷启动拦截；目录变化或窗口过期后重新提示。
        return !promptDeferredRecently
    }

    /// 强制首启下载真值（与 CatalogSlicesPromptPresentation.mandatoryDownload 同口径：
    /// firstLaunch = 尚未完成首启向导 ∧ 本机无任一片）。
    /// 视图用：强制首启下载态（决定卡片标题「（必需）/（可选）」叙事）。
    var isCatalogMandatory: Bool { mandatoryFirstLaunchDownload }

    /// 首启向导未完成（经注入 defaults 读取；视图不得直连 UserDefaults）。
    var isFirstLaunchOnboarding: Bool { !defaults.bool(forKey: "onboardingFinished") }

    private var mandatoryFirstLaunchDownload: Bool {
        guard !defaults.bool(forKey: "onboardingFinished"),
              let slices = catalogSlices else { return false }
        return CatalogSlicesPromptPresentation.mandatoryDownload(state: slices, firstLaunch: true)
    }

    private var promptDeferredRecently: Bool {
        CatalogPromptDeferral.isDeferred(
            now: now(),
            lastDeferredAt: defaults.object(forKey: Self.deferredPromptKey) as? Date)
    }

    /// 用户显式点击「检查更新」：这是首启唯一允许发起网络的动作（一次扇出四片）。
    func checkCatalog() {
        catalogSlices?.check()
    }

    /// 第二次显式动作：安装全部候选（按片体积小先，失败不阻断其余）。
    func installCatalog() {
        catalogSlices?.installAll()
    }

    enum CatalogChoiceExit {
        case deferred        // 暂不下载：写 7 天延期并取消在途检查/下载
        case keepUpdating    // 先去使用：不写延期、不取消在途下载
        case completed       // 完成/已是最新：进入（语义同 keepUpdating）
        case cancelled       // 显式取消在途检查/下载并进入：不写 7 天延期（B7）
    }

    /// 参考数据是可选项；显式「暂不下载」也进入主界面并写 7 天延期
    /// （P0 零网络可用）。B7 更名自 continueToApp，防与「取消并进入」误用。
    func deferAndEnter() { finishCatalogChoice(.deferred) }

    /// 取消在途检查/下载并进入：**不写** 7 天延期（延期只属于显式「暂不下载」，
    /// B7 取消语义落地——重开 App 时首启卡照常按延期规则评估）。
    func cancelAndEnter() { finishCatalogChoice(.cancelled) }

    /// 「先去使用（下载继续）」/完成后「进入 App」：不得静默取消在途下载
    /// （2026-10-27 评审 P0：旧实现主按钮在任何状态都会取消下载）。
    func enterKeepingUpdate() { finishCatalogChoice(.keepUpdating) }

    /// 完成/已是最新后的自动进入。
    func completeAndEnter() { finishCatalogChoice(.completed) }

    /// 完成后自动进入；VoiceOver 下延到 3s，先让成功播报完成。
    /// B7：descriptor 为 autoEnter 单真源——视图只在 `descriptor.autoEnter`
    /// 为真时调用本方法，模型不再按聚合态自行重算（旧 shouldAutoEnter 已删）。
    func scheduleAutoEnterIfNeeded() {
        guard !isHandoffFrozenForUITest else { return }   // hold / hold-summary 冻结卡片 autoEnter
        guard awaitingCatalogChoice else { return }
        let delay: Duration = UIAccessibility.isVoiceOverRunning ? .seconds(3) : .milliseconds(1500)
        autoEnter.schedule(after: delay) { [weak self] in
            self?.finishCatalogChoice(.completed)
        }
    }

    private func finishCatalogChoice(_ exit: CatalogChoiceExit) {
        guard let pendingContainer else { return }   // 幂等：防双发布
        autoEnter.cancel()
        switch exit {
        case .deferred:
            // 审查席 P1：强制模式不写延期、不取消在途（离线豁免的「先进入」
            // 语义=下载可继续，下次启动仍会强制提示）。
            if mandatoryFirstLaunchDownload { break }
            defaults.set(now(), forKey: Self.deferredPromptKey)
            catalogSlices?.cancelCheck()
            catalogSlices?.cancelUpdate()
        case .cancelled:
            // B7：显式取消在途检查/下载并进入——不写 7 天延期。
            catalogSlices?.cancelCheck()
            catalogSlices?.cancelUpdate()
        case .keepUpdating, .completed:
            break
        }
        awaitingCatalogChoice = false
        self.pendingContainer = nil
        publish(pendingContainer)
        // 卡片退出是显式动作：不再叠加被动 0.8s hold（卡片流程有其自身节奏）。
        finishBootScreen()
    }

    // MARK: - 启动自检交接门（U-批 B2）

    /// 自检页首帧呈现上报（`DatabaseInitializationView.onAppear`；headless 无此路径）。
    func noteSelfCheckPresented() {
        if selfCheckPresentedAt == nil { selfCheckPresentedAt = now() }
        trySchedulePassiveHandoff()
    }

    /// 显式进入只读壳（失败卡「只读查看」；仅 readOnlyContainer 非 nil 时可点）。
    func enterReadOnly() {
        guard readOnlyContainer != nil else { return }
        isShowingReadOnly = true
        finishBootScreen()   // 取消被动计时（失败路径本不武装，幂等）
    }

    /// 程序化放行主界面（取消被动计时；幂等）。B3 后页上无手动入口——
    /// 调用方=被动 hold 到期 / 卡片退出 / 测试通路。
    func finishBootScreen() {
        guard isShowingBootScreen else { return }
        isShowingBootScreen = false
        autoEnter.cancel()
        // U-批 B3：交接完成 → 释放行④持有的目录态（会话是唯一 owner）。
        catalogSlices = nil
    }

    /// 被动交接：仅「容器就绪、无失败、无待办卡片、已呈现」时计时；
    /// 终态自 `max(presentedAt, readyAt)` 起可见 ≥ 最短展示（VO 3s）。
    /// 批 ②：摘要展开期间冻结；收起走 `resumeAnchor`（floor 已过期不得立即交接）。
    private func trySchedulePassiveHandoff() {
        guard isShowingBootScreen, failure == nil,
              container != nil, !awaitingCatalogChoice,
              !rowFourBusy,
              !isSelfCheckSummaryExpanded,   // 批 ②：展开态冻结交接
              !isHandoffFrozenForUITest,   // B4 hold / hold-summary 冻结被动交接
              let presentedAt = selfCheckPresentedAt else { return }
        if bootTerminalAt == nil { bootTerminalAt = now() }
        let terminalAt = bootTerminalAt ?? now()
        let minDisplay = passiveMinDisplay
        let remaining = max(presentedAt, terminalAt)
            .addingTimeInterval(minDisplay).timeIntervalSince(now())
        if remaining <= 0 {
            finishBootScreen()
            return
        }
        autoEnter.cancel()
        autoEnter.schedule(after: .seconds(remaining)) { [weak self] in
            self?.finishBootScreen()
        }
    }

    private var passiveMinDisplay: TimeInterval {
        UIAccessibility.isVoiceOverRunning
            ? StartupSelfCheckRules.voiceOverMinDisplaySeconds
            : StartupSelfCheckRules.minDisplaySeconds
    }

    /// 摘要展开/收起（批 ②，视图调用）：展开冻结交接计时；收起按
    /// `max(收起时刻 + 500ms, floorEnd)` 恢复——floor 过期后的收起仍保留
    /// 500ms 可读窗口（`StartupSelfCheckRules.resumeAnchor`）。
    func toggleSelfCheckSummary() {
        isSelfCheckSummaryExpanded.toggle()
        if isSelfCheckSummaryExpanded {
            autoEnter.cancel()
            return
        }
        guard isShowingBootScreen, failure == nil, container != nil,
              !awaitingCatalogChoice, !rowFourBusy, !uiTestSelfCheckHold,
              let presentedAt = selfCheckPresentedAt else { return }
        let terminalAt = bootTerminalAt ?? now()
        guard let floorEnd = StartupSelfCheckRules.floorEnd(
            presentedAt: presentedAt, terminalAt: terminalAt,
            minDisplay: passiveMinDisplay) else { return }
        let resumeAt = StartupSelfCheckRules.resumeAnchor(collapsedAt: now(), floorEnd: floorEnd)
        let remaining = resumeAt.timeIntervalSince(now())
        autoEnter.cancel()
        guard remaining > 0 else {
            finishBootScreen()
            return
        }
        autoEnter.schedule(after: .seconds(remaining)) { [weak self] in
            self?.finishBootScreen()
        }
    }

    /// 行④进行中（检查/下载）时被动交接让位（五级优先级：行④进行中 > 被动 hold）。
    private var rowFourBusy: Bool {
        guard let aggregate = catalogSlices?.aggregate else { return false }
        return aggregate == .checking || aggregate == .updating
    }

    /// 行④活动变化（开始/结束检查或更新）后重评估被动交接（视图 onChange 调用）。
    /// 进行中 → 取消在排的被动 hold（卡片流程有自己的 autoEnter，不受此影响）；
    /// 结束后 → 按剩余预算重排（`trySchedulePassiveHandoff` 从 now 起算）。
    func rowFourActivityChanged() {
        if rowFourBusy {
            if !awaitingCatalogChoice { autoEnter.cancel() }
            return
        }
        // 2026-10-30 审查修复：行④检查/下载可能持续数十秒，首次计时锚点
        // （bootTerminalAt）早已过期——不重锚则交接立即发生，刚出现的
        // 「均为最新/失败」结果与播报来不及呈现。结束后从此刻重算可见窗口。
        bootTerminalAt = now()
        trySchedulePassiveHandoff()
    }

    /// 容器发布：先建会话（同一实例交给主界面与后台作业），再放行 UI。
    private func publish(_ assembled: AppContainer) {
        let slices = self.catalogSlices
        if let slices, let sessionFactory {
            _ = sessionFactory(assembled, slices)   // AppSession.init 安装到 holder
            // U-批 B3：自检页仍在展示（UI 首帧已上报）时保持引用——页脚行④
            // 「检查」在被动 hold 窗口内必须可点，交接完成后由 finishBootScreen
            // 释放；headless（无首帧）不保留，维持「会话唯一 owner」语义。
            if !isShowingBootScreen || selfCheckPresentedAt == nil {
                self.catalogSlices = nil
            }
        }
        container = assembled
        phase = .ready
        // 批 ③：final 快照在 facade 装配后发——健康取 open 后实测（PreparedDatabase），
        // committedKinds 取读面真值（availabieKinds 存在才可宣称 ready；假绿链路闭合）。
        if let advisory = bootSnapshot {
            bootSnapshot = BootChecklistSnapshot(
                probe: advisory.probe, decision: advisory.decision,
                decisionLabel: advisory.decisionLabel,
                plannedMigrationSteps: advisory.plannedMigrationSteps,
                sliceHealth: preparedSliceHealth,
                committedKinds: Set(assembled.catalogSlices?.availableKinds ?? []))
        }
        trySchedulePassiveHandoff()
        // O21（B4）：通用 -uitest-* 默认不渲染自检页（立即放行）；显式
        // -uitest-selfcheck-hold / 失败桩才保持自检页。
        if uiTestInstantHandoff {
            finishBootScreen()
        }
    }
}
