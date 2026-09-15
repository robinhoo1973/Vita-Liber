import Foundation

/// 档案完善进度规则（首页进度卡 · mock 对齐项，结构轮 2026-09-15 自
/// AppState 迁入）：字段集合与计数语义是 Domain 规则（tech-spec §1.1 规则 4）——
/// 此前内联在 @MainActor AppState，测试必须组装整个 App 状态才能断言；
/// 迁移后以纯函数单测（P7）。
public enum MemberProfileCompleteness {
    /// 语音访谈四段（过敏/既往史/当前用药/紧急联系人）——FR17.11/BR-001
    /// 按成员持久化的完成步骤键，与 AppState 持久化键同源。
    public static let voiceInterviewKeys: Set<String> = ["allergy", "pastHistory", "currentMeds", "emergencyContact"]

    /// 血型/证件/医保/生日 4 个直接字段 + 语音访谈四段 = 8 项。
    /// 空白串不计完成（trim 后判空）；nil 表示档案未加载/已不存在——
    /// 首页不生成虚假的 0/8 提示或占位。
    public static func progress(profile: PatientProfile?,
                                interviewCompleted: Set<String>,
                                total: Int = 8) -> (done: Int, total: Int)? {
        guard let profile, profile.deletedAt == nil else { return nil }
        let done = [profile.bloodType, profile.idNo, profile.insuranceNo, profile.birthDate].filter {
            !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }.count
        return (done + interviewCompleted.intersection(voiceInterviewKeys).count, total)
    }
}
