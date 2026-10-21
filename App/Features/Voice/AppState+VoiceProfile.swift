import Foundation
import Domain

extension AppState {
    /// FR17.11/BR-001：确认答案仅写入访谈建立时绑定的成员。
    /// 原字段/备注及完善进度共用成功写入边界，成员失效时不借用当前档案。
    func commitVoiceProfileField(_ key: String, value: String, patientId: UUID,
                                 audit: VoiceExecutionAudit? = nil) async -> Bool {
        guard var profile = members.first(where: { $0.id == patientId && $0.deletedAt == nil }) else { return false }
        switch key {
        case "bloodType": profile.bloodType = value
        case "idNo": profile.idNo = value
        case "insuranceNo": profile.insuranceNo = value
        case "note": profile.note = value
        case "birthDate": profile.birthDate = value
        default:
            guard let section = Self.voiceProfileSectionTitle(key) else { return false }
            // 结构化实体尚未接齐的访谈先保存完整原文，不推导医疗结论。
            profile.note = VoiceProfileRules.upsertingSection(
                in: profile.note, section: section,
                aliases: VoiceProfileRules.sectionAliases(for: key), value: value)
        }
        profile.updatedAt = Date().timeIntervalSince1970
        let saved = await updateMember(profile, completingVoiceInterviewStep: key, audit: audit)
        guard saved else { return false }
        // 结构化落库失败必须让本步失败可见并允许重试；不能只写 note 就报
        // 「已完成」——完成页会声称结构化数据已写入，而过敏/用药列表为空。
        return await persistVoiceStructuredField(key, value: value, patientId: patientId)
    }

    private static func voiceProfileSectionTitle(_ key: String) -> String? {
        switch key {
        case "allergy": return L10n.voiceguide_noteAllergy
        case "pastHistory": return L10n.voiceguide_noteHistory
        case "currentMeds": return L10n.voiceguide_noteMeds
        case "emergencyContact": return L10n.voiceguide_noteContact
        default: return nil
        }
    }
}
