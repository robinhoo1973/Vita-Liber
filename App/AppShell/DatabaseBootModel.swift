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

    init(sessionFactory: ((AppContainer, CatalogSlicesState) -> AppSession)? = nil,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init) {
        self.sessionFactory = sessionFactory
        self.defaults = defaults
        self.now = now
    }

    func start() async {
        guard !isRunning, container == nil, pendingContainer == nil else { return }
        isRunning = true
        failure = nil
        phase = .idle
        do {
            bootSnapshot = nil
            let prepared = try await DatabaseBootService.prepare(
                snapshot: { [weak self] advisory in
                    await MainActor.run { self?.bootSnapshot = advisory }
                },
                progress: { [weak self] phase in
                    await MainActor.run { self?.phase = phase }
                })
            phase = .assembling
            let assembled = try AppContainer.live(store: prepared.store)
            diagnostics = prepared.diagnostics
            self.catalogSlices = CatalogSlicesState(
                facade: assembled.catalogSlices ?? CatalogSliceReadFacade(),
                checker: assembled.catalogSliceChecker,
                updater: assembled.catalogSliceUpdater,
                receiptDirectory: URL(fileURLWithPath: AppContainer.defaultCatalogSliceDirectory(),
                                     isDirectory: true))
            if showsCatalogChoice(diagnostics: prepared.diagnostics) {
                pendingContainer = assembled
                awaitingCatalogChoice = true
                phase = .catalogChoice
            } else {
                publish(assembled)
            }
        } catch let boot as DatabaseBootFailure {
            failure = boot
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

    private func showsCatalogChoice(diagnostics: DatabaseBootDiagnostics) -> Bool {
        if forceCatalogChoice { return true }
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
    }

    /// 参考数据是可选项；不下载也进入主界面（P0 零网络可用）。
    func continueToApp() { finishCatalogChoice(.deferred) }

    /// 「先去使用（下载继续）」/完成后「进入 App」：不得静默取消在途下载
    /// （2026-10-27 评审 P0：旧实现主按钮在任何状态都会取消下载）。
    func enterKeepingUpdate() { finishCatalogChoice(.keepUpdating) }

    /// 完成/已是最新后的自动进入。
    func completeAndEnter() { finishCatalogChoice(.completed) }

    /// 完成/无候选后自动进入；VoiceOver 下延到 3s，先让成功播报完成。
    func scheduleAutoEnterIfNeeded() {
        guard awaitingCatalogChoice, shouldAutoEnter else { return }
        let delay: Duration = UIAccessibility.isVoiceOverRunning ? .seconds(3) : .milliseconds(1500)
        autoEnter.schedule(after: delay) { [weak self] in
            self?.finishCatalogChoice(.completed)
        }
    }

    private var shouldAutoEnter: Bool {
        guard let slices = catalogSlices else { return false }
        if slices.hasCompletedAnyUpdate { return true }
        switch slices.aggregate {
        case .allCurrent, .sourcePartial: return true
        default: return false
        }
    }

    private func finishCatalogChoice(_ exit: CatalogChoiceExit) {
        guard let pendingContainer else { return }   // 幂等：防双发布
        autoEnter.cancel()
        switch exit {
        case .deferred:
            defaults.set(now(), forKey: Self.deferredPromptKey)
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

    /// 手动 [进入 App] / 卡片退出后放行主界面（取消被动计时；幂等）。
    func finishBootScreen() {
        guard isShowingBootScreen else { return }
        isShowingBootScreen = false
        autoEnter.cancel()
        // U-批 B3：交接完成 → 释放行④持有的目录态（会话是唯一 owner）。
        catalogSlices = nil
    }

    /// 被动交接：仅「容器就绪、无失败、无待办卡片、已呈现」时计时；
    /// 终态自 `max(presentedAt, readyAt)` 起可见 ≥ 最短展示（VO 3s）。
    private func trySchedulePassiveHandoff() {
        guard isShowingBootScreen, failure == nil,
              container != nil, !awaitingCatalogChoice,
              !rowFourBusy,
              let presentedAt = selfCheckPresentedAt else { return }
        let terminalAt = now()
        let minDisplay = UIAccessibility.isVoiceOverRunning
            ? StartupSelfCheckRules.voiceOverMinDisplaySeconds
            : StartupSelfCheckRules.minDisplaySeconds
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
        // U-批 S1：final 快照在 facade 装配后发（facadeCommitted=true，行③以 facade 为准）。
        if let advisory = bootSnapshot {
            bootSnapshot = BootChecklistSnapshot(
                probe: advisory.probe, decision: advisory.decision,
                decisionLabel: advisory.decisionLabel,
                plannedMigrationSteps: advisory.plannedMigrationSteps,
                sliceHealth: advisory.sliceHealth, facadeCommitted: true)
        }
        trySchedulePassiveHandoff()
    }
}
