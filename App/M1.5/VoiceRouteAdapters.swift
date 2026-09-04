import SwiftUI
import Domain

// MARK: - FR17.10/FR17.11 语音挂载适配器（SP-55 目标 → 既有流程）

/// FR17.10 语音提醒设定（挂载适配）：确认卡确认后写入提醒调度
/// （复用 FR9.18 通道与通知隐私；删除/取消类语音指令在 F19 语义层拒绝）。
struct VoiceReminderDraftRouteView: View {
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminders

    var body: some View {
        VoiceReminderDraftView { title, fireAt, repeatRule in
            Task {
                // 通用 Reminder 语义（FR8.10 同实体）：经调度通道落「voice-rem-」通知；
                // 模糊时间必须落具体日期（FR10.2）——视图层 resolveDate 已强制
                await reminders.scheduleVoiceReminder(title: title, fireAt: fireAt,
                                                      repeatRule: repeatRule,
                                                      patientId: app.currentPatientId)
            }
        }
    }
}

/// FR17.14 语音速记条目（挂载适配：面板作为导航目的地呈现）
struct VoiceNotePanelRouteView: View {
    var body: some View {
        VoiceNotePanelView()
    }
}

/// FR17.11 语音引导式档案完善/修改（挂载适配）：
/// 每步确认字段 → 更新当前成员档案（修改走 FR6.4 修订历史语义——
/// 成员字段更新前在 AppState 保留旧值审计）。
struct VoiceGuidedProfileRouteView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VoiceGuidedProfileView { key, value in
            Task {
                guard var profile = app.members.first(where: { $0.id == app.currentPatientId }) else { return }
                switch key {
                case "bloodType": profile.bloodType = value
                case "idNo": profile.idNo = value
                case "insuranceNo": profile.insuranceNo = value
                case "note": profile.note = value
                case "birthDate": profile.birthDate = value
                default: break
                }
                profile.updatedAt = Date().timeIntervalSince1970
                _ = await app.updateMember(profile)
            }
        }
    }
}
