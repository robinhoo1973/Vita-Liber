import Foundation

/// 紧急联系人 → 常用成员 的纯规则（2026-10-24 业主）：
/// 只有家庭成员关系且常用成员中无同名活跃成员时才自动加入。
public enum EmergencyContactMemberRules {
    /// 展示名归一：去首尾空白 + 大小写/变音不敏感（中文不受影响）。
    public static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: .current)
    }

    public static func shouldAutoAddMember(name: String,
                                           relation: String,
                                           existingMemberNames: [String]) -> Bool {
        let relationValue = MemberRelation(tolerant: relation)
        guard relationValue.isFamily else { return false }
        let target = normalizedName(name)
        guard !target.isEmpty else { return false }
        return !existingMemberNames.map(normalizedName).contains(target)
    }
}
