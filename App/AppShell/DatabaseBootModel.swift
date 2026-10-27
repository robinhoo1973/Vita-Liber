import Foundation
import Combine
import SwiftUI

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
    @Published private(set) var catalog: MedicalCatalogState?
    private var pendingContainer: AppContainer?

    private let sessionFactory: ((AppContainer, MedicalCatalogState) -> AppSession)?
    /// 「稍后再说」的延期偏好（UI 偏好，非医疗数据；UserDefaults 不入备份）。
    private static let deferredPromptKey = "catalogPromptDeferredAt"
    private static let deferredPromptWindow: TimeInterval = 7 * 24 * 60 * 60

    init(sessionFactory: ((AppContainer, MedicalCatalogState) -> AppSession)? = nil) {
        self.sessionFactory = sessionFactory
    }

    func start() async {
        guard !isRunning, container == nil, pendingContainer == nil else { return }
        isRunning = true
        failure = nil
        phase = .idle
        do {
            let prepared = try await DatabaseBootService.prepare { [weak self] phase in
                await MainActor.run { self?.phase = phase }
            }
            phase = .assembling
            let assembled = try AppContainer.live(store: prepared.store)
            diagnostics = prepared.diagnostics
            let catalog = MedicalCatalogState(
                store: assembled.medicalCatalog,
                updater: assembled.medicalCatalogUpdater,
                path: URL(fileURLWithPath: AppContainer.defaultMedicalCatalogPath()),
                checker: assembled.medicalCatalogChecker,
                opener: assembled.medicalCatalogOpener)
            self.catalog = catalog
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
        if diagnostics.catalogSupportedByCurrentApp || shouldAutoContinue { return false }
        // 「稍后再说」在延期窗口内不再每次冷启动拦截；目录变化或窗口过期后重新提示。
        return !promptDeferredRecently
    }

    private var promptDeferredRecently: Bool {
        guard let deferredAt = UserDefaults.standard.object(forKey: Self.deferredPromptKey) as? Date
        else { return false }
        return Date().timeIntervalSince(deferredAt) < Self.deferredPromptWindow
    }

    /// 用户显式点击「检查更新」：这是首启唯一允许发起网络的动作。
    func checkCatalog() {
        catalog?.check()
    }

    func installCatalog() {
        catalog?.applyUpdate()
    }

    /// 参考数据是可选项；不下载也进入主界面（P0 零网络可用）。
    func continueToApp() {
        guard let pendingContainer else { return }
        UserDefaults.standard.set(Date(), forKey: Self.deferredPromptKey)
        catalog?.cancelCheck()
        catalog?.cancelUpdate()
        awaitingCatalogChoice = false
        self.pendingContainer = nil
        publish(pendingContainer)
    }

    /// 容器发布：先建会话（同一实例交给主界面与后台作业），再放行 UI。
    private func publish(_ assembled: AppContainer) {
        let catalog = self.catalog
        if let catalog, let sessionFactory {
            _ = sessionFactory(assembled, catalog)   // AppSession.init 安装到 holder
            self.catalog = nil                        // 会话是唯一 owner，避免僵尸状态
        }
        container = assembled
        phase = .ready
    }
}
