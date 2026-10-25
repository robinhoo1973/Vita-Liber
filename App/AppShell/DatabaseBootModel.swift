import Foundation
import SwiftUI

/// 启动门表现态：只有 `container` 非 nil 才允许挂载主界面。
@MainActor
final class DatabaseBootModel: ObservableObject {
    @Published private(set) var phase: DatabaseBootPhase = .idle
    @Published private(set) var container: AppContainer?
    @Published private(set) var failure: DatabaseBootFailure?
    @Published private(set) var diagnostics: DatabaseBootDiagnostics?
    @Published private(set) var isRunning = false

    func start() async {
        guard !isRunning, container == nil else { return }
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
            container = assembled
            phase = .ready
        } catch let boot as DatabaseBootFailure {
            failure = boot
        } catch is CancellationError {
            // 用户退出/任务取消：保留首帧，下次进入重试。
        } catch {
            failure = .unexpected(String(describing: error))
        }
        isRunning = false
    }

    func retry() async {
        guard !isRunning else { return }
        failure = nil
        await start()
    }
}
