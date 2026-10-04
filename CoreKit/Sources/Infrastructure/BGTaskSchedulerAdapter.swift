#if os(iOS)
// linux-blind: （平台守卫：BackgroundTasks 仅 iOS） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import BackgroundTasks
import Protocols

/// BGTaskScheduler 的生产适配器（2026-10-04 评审 C1-4 seam）：全部平台原语
/// （register/submit/cancel/错误分类/iOS 26 continued）收口于此；门面与状态机
/// 不再触碰 BackgroundTasks，测试注入桩见 CoreKitTests/BackgroundWorkSchedulerTests。
public final class BGTaskSchedulerAdapter: BackgroundTaskScheduling, @unchecked Sendable {
    public static let shared = BGTaskSchedulerAdapter()

    public func register(identifier: String, launch: @escaping @Sendable (any BackgroundTaskHandle) -> Void) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            launch(BGTaskHandleBox(task: task))
        }
    }

    public func submit(_ request: BackgroundTaskRequest) throws {
        let bgRequest: BGTaskRequest
        switch request.kind {
        case .refresh:
            let refresh = BGAppRefreshTaskRequest(identifier: request.identifier)
            refresh.earliestBeginDate = request.earliestBeginDate
            bgRequest = refresh
        case .processing(let network, let power):
            let processing = BGProcessingTaskRequest(identifier: request.identifier)
            processing.requiresNetworkConnectivity = network
            processing.requiresExternalPower = power
            processing.earliestBeginDate = request.earliestBeginDate
            bgRequest = processing
        case .continued:
            // continued 即时启动语义（系统可行即开始；startTimeout 回落由门面承担），
            // 不设 earliestBeginDate。iOS 26-only 符号必须带编译期守卫（部署目标 iOS 16
            // ——CI 37189703793 实证:守卫随 seam 迁移丢失,编译器在每个使用点强制要求）。
            guard #available(iOS 26, *) else { throw BackgroundTaskSubmitError.unavailable }
            let continued = BGContinuedProcessingTaskRequest(identifier: request.identifier,
                                                             title: request.title ?? "",
                                                             subtitle: request.subtitle ?? "")
            continued.strategy = .queue
            bgRequest = continued
        }
        do {
            try BGTaskScheduler.shared.submit(bgRequest)
        } catch {
            throw Self.map(error)
        }
    }

    public func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }

    private static func map(_ error: Error) -> BackgroundTaskSubmitError {
        guard let bgError = error as? BGTaskScheduler.Error else { return .other }
        switch bgError.code {
        case .notPermitted: return .notPermitted
        case .unavailable: return .unavailable
        case .tooManyPendingTaskRequests: return .tooManyPending
        default: return .other
        }
    }
}

/// BGTask / BGContinuedProcessingTask → BackgroundTaskHandle 包装
/// （expirationHandler 以本地镜像提供 get，setter 转发系统句柄）。
private final class BGTaskHandleBox: BackgroundTaskHandle, @unchecked Sendable {
    private let task: BGTask
    private var storedExpiration: (@Sendable () -> Void)? = nil
    init(task: BGTask) { self.task = task }

    func setTaskCompleted(success: Bool) { task.setTaskCompleted(success: success) }

    var expirationHandler: (@Sendable () -> Void)? { storedExpiration }

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        storedExpiration = handler
        task.expirationHandler = handler
    }

    var progress: Progress? {
        // iOS 26-only 符号使用点守卫（CI 37189703793 同族）
        if #available(iOS 26, *) { return (task as? BGContinuedProcessingTask)?.progress }
        return nil
    }
}

#endif
