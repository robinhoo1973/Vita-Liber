import Foundation

/// FR17.13 标准语音输入模板的**决策半场**（纯函数，Domain 层）。
///
/// 为什么这些规则必须在 Domain 而不是 View 里：tech-spec §1.1 规则 4——
/// BR 业务规则是 Domain 纯函数，View 不做业务决策。回读与否牵涉隐私红线
/// （FR17.7「不回读敏感内容」）与无障碍承诺（F18），把它写进 View 就等于
/// 每个入口各自实现一遍，正是 FR17.13「禁止各功能自建独立确认逻辑」要杜绝的。

/// 音频输出路由（FR17.13：耳机感知）
public enum AudioRoute: String, Sendable, Equatable, Codable {
    case headphones     // 有线/蓝牙耳机
    case speaker        // 扬声器/听筒——周围人可能听到
}

/// 无耳机回读偏好三态（FR14.7）
public enum ReadbackPreference: String, Sendable, Equatable, Codable, CaseIterable {
    case never              // 从不（默认）
    case ask                // 每次询问（关怀模式默认）
    case alwaysInCareMode   // 总是——仅关怀模式可设
}

/// 回读决策
public enum ReadbackDecision: Sendable, Equatable {
    /// TTS 完整回读已确认的结构化字段（不含音频原文，FR17.13）
    case readAloud(warnBystanders: Bool)
    /// 屏幕核对；`offerSpeakButton` 恒为 true —— [🔊 朗读] 是无障碍出口，不可关闭
    case screenConfirm(offerSpeakButton: Bool)
    /// 先问一次「是否朗读」，再按用户当次选择走上面两条
    case askFirst

    /// FR17.13 耳机状态即时切换判定用（拔耳机 = 回读→屏幕核对须中断播报；
    /// 插耳机 = 屏幕核对→回读须触发一次回读）
    public var isReadAloud: Bool {
        if case .readAloud = self { return true }
        return false
    }
}

public enum ReadbackPolicy {

    /// FR17.13 决策表。
    ///
    /// - 有耳机 → 一律回读（隐私已由耳机保障），不需要旁人提示。
    /// - 无耳机 → **默认不回读敏感内容**，走屏幕核对；是否主动提议朗读由偏好决定：
    ///   - `.never`  → 直接屏幕核对（仍提供 [🔊 朗读] 手动出口）
    ///   - `.ask`    → 询问一次
    ///   - `.alwaysInCareMode` → **仅在关怀模式下**才自动朗读，且必须带「请确认周围无人」
    ///     提示；非关怀模式下该偏好不成立，保守回落到 `.ask`（设置项本身也只在
    ///     关怀模式可选，此处是第二道防线——设置可能来自备份恢复的旧机器状态）。
    ///
    /// `offerSpeakButton` 永远为 true：F18 的视障/老年用户不戴耳机时也要能听，
    /// 这是 FR17.13「无耳机回读出口」化解与 F18 冲突的落点，不受偏好影响。
    public static func decide(route: AudioRoute,
                              preference: ReadbackPreference,
                              careMode: Bool) -> ReadbackDecision {
        if route == .headphones { return .readAloud(warnBystanders: false) }
        switch preference {
        case .never:
            return .screenConfirm(offerSpeakButton: true)
        case .ask:
            return .askFirst
        case .alwaysInCareMode:
            return careMode ? .readAloud(warnBystanders: true) : .askFirst
        }
    }

    /// 该偏好是否允许被设置（FR14.7：`总是` 仅关怀模式可设）
    public static func isSelectable(_ preference: ReadbackPreference, careMode: Bool) -> Bool {
        preference == .alwaysInCareMode ? careMode : true
    }

    /// 耳机状态在录入过程中变化 → 即时重判（FR17.13「拔/插耳机即时切换回读策略」）。
    /// 返回 nil 表示决策未变，无需打断当前流程/给 Toast。
    public static func rerouted(from old: AudioRoute, to new: AudioRoute,
                                preference: ReadbackPreference,
                                careMode: Bool) -> ReadbackDecision? {
        guard old != new else { return nil }
        return decide(route: new, preference: preference, careMode: careMode)
    }

    /// 回读字段对（key 为 Domain 语义键，App 层经其字段标签映射取本地化名）。
    public struct ReadbackPart: Sendable, Equatable {
        public var key: String
        public var value: String
        public init(key: String, value: String) {
            self.key = key; self.value = value
        }
    }

    /// 回读字段 = **已确认的结构化字段**，绝不含音频原文（FR17.13）。
    /// 传入未确认字段会被过滤掉——未确认内容不得被当作事实播报（BR-003）。
    ///
    /// 审查修复（V3.68 §11 清偿残根）：原 `readbackScript` 在 Domain 拼中文
    /// 句式（「已录入：…。对吗？」），且用 `displayLabel` 直拼——语音路径的
    /// displayLabel 是英文内部键（blood_pressure_sys/allergy/note），TTS 会把
    /// 内部键原样念给用户听。改为只出类型化字段对，句式由 App 层经 L10n
    /// （voice.readbackFmt）与字段标签映射组装——与 V3.68「Domain 只出
    /// 类型化数据、文案经 L10n 单出口」同一纪律。
    public static func readbackParts(_ set: OcrConfirmationSet) -> [ReadbackPart]? {
        let parts = set.confirmedFields.map { ReadbackPart(key: $0.key, value: $0.value) }
        return parts.isEmpty ? nil : parts
    }
}
