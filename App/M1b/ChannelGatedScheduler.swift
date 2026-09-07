import Foundation
import Domain
import Protocols

/// FR9.18 系统通知投递门（第七轮全仓审查修复）：
/// §5.58 的六类提醒三选一偏好（remindChannel*）此前零生产消费方——用户把
/// 用药提醒设为「静音仅横幅」后，锁屏通知仍按时响起（假宣告，与第六轮
/// 修复的「调度类型选择真实映射」同族）。
///
/// 本装饰器包在真实调度器外层（AppContainer 装配，Infrastructure 各 store
/// 零改动）：`schedule` 前按 notifyId 前缀归类（ReminderChannelRules，
/// Domain 纯函数）并读 UserDefaults 镜像的偏好值（AppSettingsStore.set
/// 双写维护；UserDefaults 线程安全，actor 内同步读取无需 @MainActor
/// 往返）——「inApp」仅对**有应用内横幅承接**的 dose-/slot- 跳过系统
/// 投递；「persistentRing」在 Critical Alerts 授权益落地（W4/P2）前按
/// 降级链落到 local 照常投递；「local」不变。
///
/// 第八轮全仓审查修复（投递门静默缺口）：门已接通的预约（apt-）与其余
/// 类别若按「inApp」跳过系统投递，而 InAppBannerHost 只渲染剂量/时段
/// 横幅（§5.58 降级链的「应用内横幅」对预约/临期/随访/预警/备份尚不
/// 存在）——用户选择即落入**零通道**（无锁屏、无横幅、无通知中心），
/// P0 早告警静默丢失。按 ui-ux §5.58「目标通道不可用自动降级」纪律：
/// 无横幅承接的类别一律照常系统投递（宁响铃、绝不静默丢弃），待横幅
/// 通道扩展（W4 接线批次）后逐类别收紧。
///
/// 偏好变更只作用于**新排程**的通知；已 pending 的旧通知在下次对账/语言
/// 重写时自然收敛（切换偏好后立即取消旧 pending 的通道对账登记技术债，
/// 随 W4 接线批次一并实施）。
actor ChannelGatedScheduler: ReminderScheduling {
    private let inner: any ReminderScheduling

    init(inner: any ReminderScheduling) {
        self.inner = inner
    }

    /// notifyId → 类别偏好值（未识别前缀回落全局 remindChannel 缺省）
    private nonisolated static func preference(for notifyId: String) -> String? {
        let defaults = UserDefaults.standard
        if let key = ReminderChannelRules.categoryKey(for: notifyId) {
            return defaults.string(forKey: key.rawValue) ?? key.defaultValue
        }
        return defaults.string(forKey: AppSettingKey.remindChannel.rawValue)
            ?? AppSettingKey.remindChannel.defaultValue
    }

    /// 「静音仅横幅」只对 dose-/slot- 生效（InAppBannerHost 唯一渲染的类别）；
    /// 其余类别按 §5.58 降级链照常系统投递（见类文档第八轮修复说明）。
    private nonisolated static func shouldSuppressSystem(_ notifyId: String) -> Bool {
        guard notifyId.hasPrefix("dose-") || notifyId.hasPrefix("slot-") else { return false }
        return !ReminderChannelRules.shouldDeliverSystem(notifyId,
                                                         preference: preference(for: notifyId))
    }

    func schedule(dose notifyId: String, at fireAt: Date, route: AppRoute?) async throws {
        guard !Self.shouldSuppressSystem(notifyId) else { return }
        try await inner.schedule(dose: notifyId, at: fireAt, route: route)
    }

    func scheduleRepeating(dose notifyId: String, at fireAt: Date, route: AppRoute?,
                           repeatRule: String?) async throws {
        guard !Self.shouldSuppressSystem(notifyId) else { return }
        try await inner.scheduleRepeating(dose: notifyId, at: fireAt, route: route,
                                          repeatRule: repeatRule)
    }

    func cancel(_ notifyIds: [String]) async throws {
        try await inner.cancel(notifyIds)
    }

    func removeDelivered(_ notifyIds: [String]) async throws {
        try await inner.removeDelivered(notifyIds)
    }

    func reloadLocalizedContent() async throws {
        try await inner.reloadLocalizedContent()
    }

    func pending() async throws -> [String: Date] {
        try await inner.pending()
    }

    func delivered() async throws -> Set<String> {
        try await inner.delivered()
    }
}
