import Foundation
import SwiftUI
import Perception
import Domain
import Infrastructure

/// 本机 AI 模型（llama GGUF）首启下载中心（2026-09-20 业主裁决项 4）：
/// App 级可观察安装态——设置页/实验室页同源呈现「下载等待 UI」
/// （确定性进度 + 阶段文案 + 取消），离开页面状态不丢失。
/// 稳定性由服务层保证（断点续传/哈希双钉版/原子落位/失败清理）。
@MainActor
@Perceptible
final class LlamaInstallCenter {
    enum State: Equatable {
        case idle          // 未安装也未下载
        case installing    // 下载中（progress/phase 见 active）
        case installed     // 就绪
        case failed        // 最近一次失败（lastError）
    }

    @MainActor
    @Perceptible
    final class Active: Identifiable {
        let id = UUID()
        var receivedBytes: Int64 = 0
        var totalBytes: Int64 = LlamaModelManager.expectedModelBytes
        var phase: LlamaModelDownloadService.Phase?
        var waiting = true

        /// 确定性进度（0…1）；阶段未定前显示不确定转轮。
        var fraction: Double {
            totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0
        }

        nonisolated func submit(progress: LlamaModelDownloadService.Progress) {
            Task { @MainActor [weak self] in
                self?.receivedBytes = progress.receivedBytes
                self?.totalBytes = progress.totalBytes
                self?.waiting = false
            }
        }

        nonisolated func submit(phase: LlamaModelDownloadService.Phase) {
            Task { @MainActor [weak self] in self?.phase = phase }
        }
    }

    private(set) var state: State = LlamaModelManager.isModelReady() ? .installed : .idle
    private(set) var active: Active?
    private(set) var lastError: String?
    private var task: Task<Void, Never>?

    static let shared = LlamaInstallCenter()

    private init() {}

    var isInstalling: Bool { state == .installing }

    func refresh() {
        if state != .installing {
            state = LlamaModelManager.isModelReady() ? .installed : (state == .failed ? .failed : .idle)
        }
    }

    func start() {
        guard !isInstalling else { return }
        let install = Active()
        active = install
        state = .installing
        lastError = nil
        task = Task { [weak self] in
            await self?.run(install)
        }
    }

    func dismissFailure() { if state == .failed { state = .idle; lastError = nil } }

    func cancel() {
        task?.cancel()
        task = nil
        active = nil
        state = LlamaModelManager.isModelReady() ? .installed : .idle
    }

    private func run(_ install: Active) async {
        var assertion: UIBackgroundTaskIdentifier = .invalid
        assertion = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(assertion)
        }
        defer { UIApplication.shared.endBackgroundTask(assertion) }
        do {
            _ = try await LlamaModelDownloadService.shared.install(
                progress: { install.submit(progress: $0) },
                onPhase: { install.submit(phase: $0) })
            if !Task.isCancelled {
                active = nil
                state = .installed
                // T2 可用性随模型就绪即时生效（引擎侧 isModelReady 判定）。
                AppDataChangeCenter.shared.assetsChanged()
            }
        } catch is CancellationError {
            active = nil
            state = LlamaModelManager.isModelReady() ? .installed : .idle
        } catch {
            if !Task.isCancelled {
                active = nil
                lastError = (error as? LlamaModelDownloadService.Failure)?.errorDescription ?? String(describing: error)
                state = .failed
            }
        }
    }
}
