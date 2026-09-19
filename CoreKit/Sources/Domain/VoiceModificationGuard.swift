import Foundation

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
        /// V3.68：拒绝卡文案由 App 层经 L10n 组装（Domain 不再拼中文句式；
        /// BR-006 措辞负清单在模板层保证——模板本身零判断词）。
        public init(category: Category, matchedPhrase: String) {
            self.category = category; self.matchedPhrase = matchedPhrase
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
            if let phrase = phrases[category]?.first(where: { transcript.contains($0) }) {
                return Rejection(category: category, matchedPhrase: phrase)
            }
        }
        return nil
    }

    /// 拒绝卡构造单一出口（2026-09-19 恢复：测试契约
    /// rejectionCardIsTypedAndKeepsMatchedPhrase 钉死——类别与命中短语必须随卡
    /// 留痕，用户可见「改了什么」；2026-09-18 清理轮误删，CoreKitTests 不在
    /// Linux 型检范围，CI 35411488605 实证）。
    public static func rejection(category: Category, phrase: String) -> Rejection {
        Rejection(category: category, matchedPhrase: phrase)
    }
}
