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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restore()
    }

    /// 通知点击 → 路由分发：先切 selection 到 route 所属 Tab，再 append 到对应 path
    /// （跨 Tab 路由若不切 selection，用户留在原 Tab 看不到任何推进——TestFlight 实测
    /// 首页快速拍摄/语音速记面板选择栏目均因此无反应）。
    /// SOS 免门禁（FR1.8），其余路由在门禁通过后可见。
    func navigate(to route: AppRoute) {
        let tab = MainModuleID.tab(of: route)
        selection = tab
        switch tab {
        case .home: homePath.append(route)
        case .records: recordsPath.append(route)
        case .reminders: remindersPath.append(route)
        case .ai: aiPath.append(route)
        case .me: mePath.append(route)
        }
        persist()
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

    /// Tab 内的 path 绑定（NavigationStack(path:) 消费）
    func binding(for tab: MainModuleID) -> Binding<[AppRoute]> {
        switch tab {
        case .home: return Binding(get: { [weak self] in self?.homePath ?? [] },
                                   set: { [weak self] in self?.homePath = $0; self?.persist() })
        case .records: return Binding(get: { [weak self] in self?.recordsPath ?? [] },
                                      set: { [weak self] in self?.recordsPath = $0; self?.persist() })
        case .reminders: return Binding(get: { [weak self] in self?.remindersPath ?? [] },
                                        set: { [weak self] in self?.remindersPath = $0; self?.persist() })
        case .ai: return Binding(get: { [weak self] in self?.aiPath ?? [] },
                                 set: { [weak self] in self?.aiPath = $0; self?.persist() })
        case .me: return Binding(get: { [weak self] in self?.mePath ?? [] },
                                 set: { [weak self] in self?.mePath = $0; self?.persist() })
        }
    }

    // MARK: - §5.48 跨启动恢复

    private enum Key: String, CaseIterable {
        case home, records, reminders, ai, me, selectedModule
        var storageKey: String { "router.path.\(rawValue)" }
    }

    private func persist() {
        guard !isRestoring else { return }
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
/// 经 AppRouter 导航；缺失/解码失败 → 降级为打开 App 默认落点，绝不 crash。
final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let router: AppRouter

    init(router: AppRouter) { self.router = router }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let data = response.notification.request.content.userInfo["route"] as? Data else {
            return   // 无路由 = 打开 App 默认落点（合法降级，§5.45）
        }
        guard let route = try? JSONDecoder().decode(AppRoute.self, from: data) else { // try?-ok: 历史/损坏路由解码失败降级默认落点，不得 crash（§5.45）
            return
        }
        await MainActor.run { router.navigate(to: route) }
    }
}
