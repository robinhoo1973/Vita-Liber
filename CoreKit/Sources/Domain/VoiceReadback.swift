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

    /// 回读文本 = **已确认的结构化字段**，绝不含音频原文（FR17.13）。
    /// 传入未确认字段会被过滤掉——未确认内容不得被当作事实播报（BR-003）。
    public static func readbackScript(_ set: OcrConfirmationSet) -> String? {
        let parts = set.confirmedFields.map { "\($0.displayLabel)：\($0.value)" }
        guard !parts.isEmpty else { return nil }
        return "已录入：" + parts.joined(separator: "，") + "。对吗？"
    }
}

/// 长音频分段策略（tech-spec §11 清偿项「SFSpeechRecognizer 60s 截断」，归属 M1.5）。
///
/// 基线轨 SFSpeechRecognizer 单次识别约 60s 后被系统截断，长录音必须切窗续接；
/// 升级轨（ADR-023，iOS 26+）支持长音频，不分段。两轨经同一 `TranscriptionEngine`
/// 协议暴露，分段与否是**实现细节**，调用方零感知。
public enum TranscriptionSegmentation {
    /// 方言无独立引擎时的回落 locale（FR17.15/FR17.16 发声与识别回退链）
    public static let fallbackLocale = "zh-Hans-CN"

    public struct Window: Sendable, Equatable {
        public var startSeconds: Int
        public var lengthSeconds: Int
        public init(startSeconds: Int, lengthSeconds: Int) {
            self.startSeconds = startSeconds; self.lengthSeconds = lengthSeconds
        }
    }

    /// 切窗规划。窗口间留 `overlapSeconds` 重叠，避免切点正好落在字中间导致丢字。
    /// - 升级轨（supportsLongForm）恒为单窗；
    /// - 基线轨按 `maxSegmentSeconds` 切，且**留 5s 安全余量**再切——
    ///   卡着 60s 切会在系统抢先截断与我方切窗之间产生竞态。
    public static func plan(durationSeconds: Int,
                            capability: TranscriptionCapability,
                            overlapSeconds: Int = 2) -> [Window] {
        guard durationSeconds > 0 else { return [] }
        if capability.supportsLongForm {
            return [Window(startSeconds: 0, lengthSeconds: durationSeconds)]
        }
        let safe = max(5, capability.maxSegmentSeconds - 5)
        if durationSeconds <= safe {
            return [Window(startSeconds: 0, lengthSeconds: durationSeconds)]
        }
        var windows: [Window] = []
        var start = 0
        while start < durationSeconds {
            let length = min(safe, durationSeconds - start)
            windows.append(Window(startSeconds: start, lengthSeconds: length))
            if start + length >= durationSeconds { break }
            start += max(1, length - overlapSeconds)
        }
        return windows
    }
}

/// FR17.11 / BR-003 / BR-006：语音通道对既有用药计划的修改一律拒绝。
///
/// 语音只允许「新增草稿与备注」；**剂量 / 频次 / 停用**三类修改必须被挡在
/// 语音入口之外，改由触屏路径显式操作。理由是错误代价不对称——语音误识别一次
/// 剂量修改，后果是真实的用药错误，而多点两下触屏没有任何损失。
public enum VoiceModificationGuard {

    public enum Category: String, Sendable, Equatable, CaseIterable {
        case dosage      // 剂量
        case frequency   // 频次
        case discontinue // 停用/停药
    }

    public struct Rejection: Sendable, Equatable {
        public var category: Category
        public var matchedPhrase: String
        /// 拒绝卡文案（纯事实 + 指路，不含任何医学建议——BR-006 措辞负清单）
        public var title: String
        public var body: String
        public var actionLabel: String
        public init(category: Category, matchedPhrase: String,
                    title: String, body: String, actionLabel: String) {
            self.category = category; self.matchedPhrase = matchedPhrase
            self.title = title; self.body = body; self.actionLabel = actionLabel
        }
    }

    /// 触发词表。命中即拒——**宁可误拒，不可误改**（安全侧偏置，同 ADR-009 的取向）。
    static let phrases: [Category: [String]] = [
        .dosage: ["改成", "改为", "加到", "减到", "增加剂量", "减少剂量", "加量", "减量",
                  "多吃", "少吃", "改剂量", "调剂量"],
        .frequency: ["改成一天", "一天改", "改为每天", "改成每天", "频次改", "改频次",
                     "从一天", "次数改"],
        .discontinue: ["停药", "停用", "不吃了", "别吃了", "停掉", "取消这个药", "以后不吃"],
    ]

    /// 只在**修改既有计划**的语境下判定。`isExistingPlanContext == false`（如新建草稿、
    /// 速记正文）时不拦——否则用户连「记一条：医生说以后不吃了」这样的备忘都记不了。
    public static func evaluate(_ transcript: String,
                                isExistingPlanContext: Bool) -> Rejection? {
        guard isExistingPlanContext else { return nil }
        // 频次优先于剂量：「改成一天两次」同时含「改成」，按更具体的类别归因
        for category in [Category.discontinue, .frequency, .dosage] {
            guard let list = phrases[category] else { continue }
            for phrase in list where transcript.contains(phrase) {
                return rejection(category: category, phrase: phrase)
            }
        }
        return nil
    }

    static func rejection(category: Category, phrase: String) -> Rejection {
        let what: String
        switch category {
        case .dosage:      what = "剂量"
        case .frequency:   what = "服用频次"
        case .discontinue: what = "停用药物"
        }
        return Rejection(
            category: category,
            matchedPhrase: phrase,
            title: "语音不能修改\(what)",
            // 纯事实句式：陈述限制 + 指路，不含「建议/应该/需遵医嘱」等负清单词
            body: "为避免识别误差造成用药差错，\(what)的修改只能在屏幕上手动完成。你刚才说的内容没有被保存。",
            actionLabel: "去用药计划修改")
    }
}
