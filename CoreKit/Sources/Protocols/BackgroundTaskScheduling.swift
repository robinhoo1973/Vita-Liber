import Foundation

/// 后台任务调度端口（2026-10-04 后台任务专项评审 C1-4 seam，
/// discussions/2026-10-04-background-tasks-council.md）：生产实现
/// `BGTaskSchedulerAdapter`（Infrastructure，#if os(iOS)），测试实现注入桩。
/// 此前 `BackgroundWorkScheduler` 直连 `BGTaskScheduler.shared`——调度层三处契约缺陷
/// （runContinued 单槽覆盖/孤儿请求/取消穿透）无任何可测通道，且平台守卫空单元
/// 使门面在 Linux 型检全盲。本端口把平台原语收口为五个操作，门面与状态机
/// 移出 `#if os(iOS)` 后获 Linux 完整型检与可注入测试。
public protocol BackgroundTaskScheduling: Sendable {
    /// 注册一个标识符（须在启动完成前；每个标识符恰一次）。回执 false = 系统拒绝注册。
    func register(identifier: String, launch: @escaping @Sendable (any BackgroundTaskHandle) -> Void) -> Bool
    /// 提交一次运行请求（同名重提语义由平台决定；调用方按「先撤后提」纪律调用）。
    func submit(_ request: BackgroundTaskRequest) throws
    /// 撤销挂起请求（不伤运行中任务）。
    func cancel(identifier: String)
}

/// 系统唤起后的任务句柄：回报完成、接收到期回调、读取系统进度（iOS 26 continued）。
/// 到期回调经方法设置（existential 上不能赋值协议 setter——Linux 型检实证）。
public protocol BackgroundTaskHandle: Sendable {
    func setTaskCompleted(success: Bool)
    var expirationHandler: (@Sendable () -> Void)? { get }
    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void)
    /// iOS 26 continued processing 的系统进度条（刷新/处理类为 nil）。
    var progress: Progress? { get }
}

/// 提交请求的纯值形态（平台无关）。
public struct BackgroundTaskRequest: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// BGAppRefreshTask（≈30s 级）
        case refresh
        /// BGProcessingTask（分钟级；网络/电源要求）
        case processing(requiresNetwork: Bool, requiresExternalPower: Bool)
        /// BGContinuedProcessingTaskRequest（iOS 26 用户动作发起；title/subtitle 为 Live Activity 文案）
        case continued
    }

    public let identifier: String
    public let kind: Kind
    public let earliestBeginDate: Date
    public let title: String?
    public let subtitle: String?

    public init(identifier: String, kind: Kind, earliestBeginDate: Date,
                title: String? = nil, subtitle: String? = nil) {
        self.identifier = identifier; self.kind = kind
        self.earliestBeginDate = earliestBeginDate
        self.title = title; self.subtitle = subtitle
    }
}

/// 提交失败的平台无关分类（适配器把 BGTaskScheduler.Error 映射为此；门面据此分账
/// 「注册级缺陷」与「系统级暂态」，见 BackgroundWorkScheduler.SubmitFailureKind）。
public enum BackgroundTaskSubmitError: Error, Sendable, Equatable {
    /// 标识符未登记/未注册——注册级缺陷。
    case notPermitted
    /// 系统层面暂不可用（后台刷新被关闭、低电量等）。
    case unavailable
    /// 排队过多（同名请求未撤销即重提的经典成因）。
    case tooManyPending
    /// 其他错误。
    case other
}
