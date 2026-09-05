import Foundation
import SwiftUI
import Domain

/// §5.45 类型安全路由中枢：每个 Tab 独立 NavigationStack path；
/// 通知/SOS/错误卡跳转经 `navigate(to:)` 按 route 所属 Tab 分发——
/// 切换 selection + append 到对应 path（多级推入由 path 数组顺序保证）。
///
/// 持久化（§5.48 NavigationStack 跨启动恢复）：paths 经 Codable 编码落
/// UserDefaults，冷启动恢复；恢复后路由指向已删除实体时由目的地视图自弹回根。
@MainActor
@Observable
final class AppRouter {
    var homePath: [AppRoute] = []
    var recordsPath: [AppRoute] = []
    var remindersPath: [AppRoute] = []
    var aiPath: [AppRoute] = []
    var mePath: [AppRoute] = []

    /// 当前选中模块——导航单一状态源（评审修正，TestFlight 实测：navigate 只 append
    /// 不切 Tab，跨 Tab 路由点击无任何反应）。§5.45 契约「切换 selection + append」
    /// 的两半必须同源完成，selection 亦随 paths 一起持久化（§5.48 跨启动恢复）。
    private(set) var selection: MainModuleID = .home

    private let defaults: UserDefaults
    /// 恢复中标志：从 UserDefaults 解码失败时静默归零（缺路由降级不 crash，§5.45）
    private var isRestoring = false
    /// 恢复完成标志：init 阶段场景尚未渲染，非空 path 在首帧渲染期触发 push
    /// 转场会命中 iOS 26 转场环境断言（TestFlight 2026-09-05 crash 2）——恢复
    /// 必须推迟到导航外壳（RootAdaptiveView）首次挂载之后。此前 persist 为
    /// no-op，防止空 path 覆盖 UserDefaults 里的持久化路由。
    private var didRestore = false
    /// 导航外壳就绪标志（RootAdaptiveView.onAppear 置位）。注意不能用
    /// AppRootView 首帧作就绪锚点：门禁冷启动时首帧是 LockOverlayView，
    /// 外壳（含五个 NavigationStack）要等 Face ID 解锁后才挂载——外壳未
    /// 挂载时 push 同样命中转场环境断言（crash 2 时序：启动后约 1.5s）。
    private var navigationReady = false
    /// 外壳就绪前暂存的通知路由队列（主线程访问，enqueue/markNavigationReady 消费；
    /// 队列而非单槽——启动窗口内连点两条通知时逐条投递，不丢后到/先到的路由）
    private var pendingRoutes: [AppRoute] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // restore() 不在 init 执行——见 didRestore 注释（§5.48 恢复时点修正）
    }

    /// 导航外壳（RootAdaptiveView）首次挂载后调用（幂等）。
    /// 内部再延一拍（下一 runloop）：恢复/投递落在挂载帧提交之后，
    /// 不在外壳的挂载 render pass 内执行 push。
    func markNavigationReady() {
        guard !navigationReady else { return }
        navigationReady = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.finishRestore()
            guard !self.pendingRoutes.isEmpty else { return }
            let routes = self.pendingRoutes
            self.pendingRoutes = []
            for route in routes {
                self.navigate(to: route)
            }
        }
    }

    /// 通知点击 → 路由入队（AppNotificationDelegate 调用）：
    /// 外壳就绪 → 立即分发；未就绪（启动窗口/门禁中）→ 暂存，
    /// 由 markNavigationReady 在挂载帧之后投递。
    func enqueue(route: AppRoute) {
        if navigationReady {
            navigate(to: route)
        } else {
            pendingRoutes.append(route)
        }
    }

    /// 外壳挂载后恢复（markNavigationReady 调用）。幂等：多次调用只恢复一次。
    func finishRestore() {
        guard !didRestore else { return }
        didRestore = true
        restore()
    }

    /// 通知点击 → 路由分发：先切 selection 到 route 所属 Tab（本拍），
    /// 再 append 到对应 path（下一拍）——同一 update 内 TabView 换栈 +
    /// NavigationStack 推入会让 iOS 26 借用控制器缓存路径在环境未装配时
    /// 配置转场（TestFlight crash 2 断言栈：configurePreferredTransition）。
    /// 跨 Tab 路由若不切 selection，用户留在原 Tab 看不到任何推进
    /// （TestFlight 实测——首页快速拍摄/语音速记面板选择栏目均因此无反应）。
    /// SOS 免门禁（FR1.8），其余路由在门禁通过后可见。
    func navigate(to route: AppRoute) {
        let tab = MainModuleID.tab(of: route)
        selection = tab
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch tab {
            case .home: self.homePath.append(route)
            case .records: self.recordsPath.append(route)
            case .reminders: self.remindersPath.append(route)
            case .ai: self.aiPath.append(route)
            case .me: self.mePath.append(route)
            }
            self.persist()
        }
    }

    /// Tab/侧边栏选中回写（RootAdaptiveView 统一入口，避免散落直接赋值）
    func select(_ tab: MainModuleID) {
        guard selection != tab else { return }
        selection = tab
        persist()
    }

    /// TabView selection / Sidebar 回写的统一绑定
    var selectionBinding: Binding<MainModuleID> {
        Binding(
            get: { [weak self] in self?.selection ?? .home },
            set: { [weak self] in self?.select($0) })
    }

    /// Tab 内的 path 绑定（NavigationStack(path:) 消费）。
    /// 审查修复注记：曾尝试 lazy 缓存绑定避免每帧新建 Binding 的身份抖动，
    /// 但 @Observable 宏不支持 lazy 存储属性（ObservationTracked 展开后
    /// 「lazy cannot be used on a computed property」编译失败）——回落为
    /// keyPath 参数化的单一构造（SwiftUI 常规模式，绑定身份抖动不构成
    /// 实际问题，crash 2 根因在恢复时点与双导航变更，与此无关）。
    private func pathBinding(_ keyPath: ReferenceWritableKeyPath<AppRouter, [AppRoute]>) -> Binding<[AppRoute]> {
        Binding(get: { [weak self] in self?[keyPath: keyPath] ?? [] },
                set: { [weak self] in self?[keyPath: keyPath] = $0; self?.persist() })
    }

    func binding(for tab: MainModuleID) -> Binding<[AppRoute]> {
        switch tab {
        case .home: return pathBinding(\.homePath)
        case .records: return pathBinding(\.recordsPath)
        case .reminders: return pathBinding(\.remindersPath)
        case .ai: return pathBinding(\.aiPath)
        case .me: return pathBinding(\.mePath)
        }
    }

    // MARK: - §5.48 跨启动恢复

    private enum Key: String, CaseIterable {
        case home, records, reminders, ai, me, selectedModule
        var storageKey: String { "router.path.\(rawValue)" }
    }

    private func persist() {
        guard !isRestoring, didRestore else { return }
        set(Key.home, homePath); set(Key.records, recordsPath)
        set(Key.reminders, remindersPath); set(Key.ai, aiPath); set(Key.me, mePath)
        defaults.set(selection.rawValue, forKey: Key.selectedModule.storageKey)
    }

    private func set(_ key: Key, _ path: [AppRoute]) {
        guard !path.isEmpty else {
            defaults.removeObject(forKey: key.storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(path) else { return }   // try?-ok: 编码失败即放弃持久化，不阻塞导航（§5.48 降级语义）
        defaults.set(data, forKey: key.storageKey)
    }

    private func restore() {
        isRestoring = true
        defer { isRestoring = false }
        homePath = load(Key.home); recordsPath = load(Key.records)
        remindersPath = load(Key.reminders); aiPath = load(Key.ai); mePath = load(Key.me)
        if let raw = defaults.string(forKey: Key.selectedModule.storageKey),
           let restored = MainModuleID(rawValue: raw) {
            selection = restored
        }
    }

    private func load(_ key: Key) -> [AppRoute] {
        guard let data = defaults.data(forKey: key.storageKey) else { return [] }
        guard let routes = try? JSONDecoder().decode([AppRoute].self, from: data) else { // try?-ok: 历史版本路由解码失败 → 归零从根开始（缺路由降级不 crash，§5.45）
            defaults.removeObject(forKey: key.storageKey)
            return []
        }
        return routes
    }
}

/// §5.45 通知点击→路由映射契约的接收端：
/// UNUserNotificationCenterDelegate.didReceive 解码 userInfo["route"]（Codable AppRoute），
/// 经 AppRouter.enqueue 入队；缺失/解码失败 → 降级为打开 App 默认落点，绝不 crash。
///
/// 5WHY 根因修正（TestFlight 2026-09-05 crash）：
/// 1. 禁用 async 变体 `didReceive` —— 系统在**后台线程**调用它，而 UIKit 在
///    通知响应投递路径上包裹的快照/状态恢复工作（_updateSnapshotAndStateRestoration
///    WithAction → _performBlockAfterCATransactionCommitSynchronizes）在 delegate
///    线程上执行，非主线程触发 "Call must be made on main thread" 断言（SIGABRT）。
///    完成回调变体系统保证主线程调用；回调立即归还，路由工作经
///    Task { @MainActor } 落到主线程并延后一拍。
/// 2. 启动窗口门控 —— 冷启动点按通知时 didReceive 先于导航外壳挂载到达，
///    此时 push 会命中 iOS 26 转场环境断言（SIGTRAP，crash 2）。路由经
///    AppRouter.enqueue 暂存，外壳挂载（RootAdaptiveView.onAppear →
///    markNavigationReady）之后才投递。
@MainActor
final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let router: AppRouter

    init(router: AppRouter) { self.router = router }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        // 立即归还回调：不在系统通知交付路径上做任何路由/UIKit 工作
        completionHandler()
        guard let data = response.notification.request.content.userInfo["route"] as? Data,
              let route = try? JSONDecoder().decode(AppRoute.self, from: data) else { // try?-ok: 历史/损坏路由解码失败降级默认落点，不得 crash（§5.45）
            return
        }
        // 主线程异步入队：无论系统在哪个线程回调，路由工作都落在主线程
        // 且延后一拍，避开启动窗口的首帧转场断言
        Task { @MainActor [weak self] in
            self?.router.enqueue(route: route)
        }
    }
}
