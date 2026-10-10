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
/// 偏好变更此前只作用于**新排程**的通知（第九轮审查 P4#8：用户切到
/// 「静音仅横幅」后，已预排 7 天的 dose-/slot- 针照常在锁屏响铃——设置
/// 看似无效）。批C④落地收敛取消：在最近的既有写入面（新排程 / 语言重写）
/// 顺带清扫已 pending 且现应被抑制的针（sweepSuppressedPending）——零新增
/// 跨文件接线；枚举 ≤64 条 pending 开销可忽略。收敛失败不翻盘，下个事件点
/// 自动重试。
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

    /// 「静音仅横幅」只对**有应用内横幅承接**的 dose-/slot- 生效（InAppBannerHost
    /// 唯一渲染的类别）；snooze-/voice-rem- 虽归用药通道偏好但无应用内承接，
    /// 按 §5.58 降级链照常系统投递（宁响铃、绝不静默丢弃，见类文档第八轮修复
    /// 说明；第十轮曾按 categoryKey 把抑制放宽到整个用药族，使稍后提醒/语音
    /// 提醒落入零通道——收敛回 Domain hasInAppBannerCoverage 单一事实源）。
    /// 第十一轮审查：抑制还必须咨询横幅总开关——开关关闭时应用内横幅不
    /// 渲染（InAppBannerHost 守卫），「静音仅横幅」的承接不存在，抑制即
    /// 零通道；判定统一走 Domain ReminderChannelRules.suppressSystemDelivery
    /// （与前台 foregroundDelivery 同口径，本类只读 UserDefaults 镜像）。
    private nonisolated static func shouldSuppressSystem(_ notifyId: String) -> Bool {
        let defaults = UserDefaults.standard
        return ReminderChannelRules.suppressSystemDelivery(
            notifyId,
            bannerEnabled: defaults.string(forKey: AppSettingKey.inAppBannerEnabled.rawValue) != "false",
            preference: preference(for: notifyId))
    }

    func schedule(dose notifyId: String, at fireAt: Date, route: AppRoute?) async throws {
        await sweepSuppressedPending()
        guard !Self.shouldSuppressSystem(notifyId) else { return }
        try await inner.schedule(dose: notifyId, at: fireAt, route: route)
    }

    /// 批C①（评审 P1 零通道）：带成员域的同门 + 透传——不覆写本签名则协议
    /// 扩展默认实现会回落旧签名，userInfo 的 patientId 在内层适配器丢失
    /// （前台 willPresent 的成员判定随之失效）。抑制判定与旧签名同源不变。
    func schedule(dose notifyId: String, at fireAt: Date, route: AppRoute?,
                  patientId: UUID?) async throws {
        guard !Self.shouldSuppressSystem(notifyId) else { return }
        try await inner.schedule(dose: notifyId, at: fireAt, route: route, patientId: patientId)
    }

    func scheduleRepeating(dose notifyId: String, at fireAt: Date, route: AppRoute?,
                           repeatRule: String?) async throws {
        await sweepSuppressedPending()
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
        // 批C④：语言重写是既有收敛事件点——顺带清扫现应被抑制的 pending 针
        await sweepSuppressedPending()
    }

    /// 批C④（第九轮审查 P4#8）：偏好切到「静音仅横幅/关闭横幅」后，已 pending
    /// 的旧针收敛取消（门此前只拦新排程）。判定与 shouldSuppressSystem 单一
    /// 事实源；cancel 经内层同族展开（-occ-/-wd 针一并清）。枚举失败/取消失败
    /// 不翻盘主路径（非静默纪律：收敛是尽力而为，下个事件点重试）。
    private func sweepSuppressedPending() async {
        guard let pending = try? await inner.pending() else { return }   // try?-ok: 枚举失败视为无可收敛，不阻断排程主路径
        let doomed = pending.keys.filter { Self.shouldSuppressSystem($0) }
        guard !doomed.isEmpty else { return }
        do { try await inner.cancel(doomed) }
        catch { /* 收敛失败静默重试：下次排程/语言重写再扫 */ }
    }

    func pending() async throws -> [String: Date] {
        try await inner.pending()
    }

    func delivered() async throws -> Set<String> {
        try await inner.delivered()
    }
}
