import Foundation
import Combine
import SwiftUI

/// 启动门表现态：只有 `container` 非 nil 才允许挂载主界面。
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
            if prepared.diagnostics.catalogSupportedByCurrentApp || shouldAutoContinue {
                container = assembled
                phase = .ready
            } else {
                pendingContainer = assembled
                awaitingCatalogChoice = true
                phase = .catalogChoice
            }
        } catch let boot as DatabaseBootFailure {
            failure = boot
            AppSessionHolder.shared.fail()
        } catch is CancellationError {
            // 用户退出/任务取消：保留首帧，下次进入重试。
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
        await start()
    }

    /// XCUITest 不能驱动首启可选卡；仅 DEBUG 的 `-uitest-*` 启动参数自动继续。
    private var shouldAutoContinue: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-uitest-") }
        #else
        false
        #endif
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
        catalog?.cancelUpdate()
        catalog = nil
        awaitingCatalogChoice = false
        self.pendingContainer = nil
        container = pendingContainer
        phase = .ready
    }
}
