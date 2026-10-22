import SwiftUI
import Domain
import Perception

// MARK: - FR17.10/FR17.11 语音挂载适配器（SP-55 目标 → 既有流程）

/// FR17.10 语音提醒设定（挂载适配）：确认卡确认后写入提醒调度
/// （复用 FR9.18 通道与通知隐私；删除/取消类语音指令在 F19 语义层拒绝）。
struct VoiceReminderDraftRouteView: View {
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminders

    var body: some View {
        WithPerceptionTracking {
            VoiceReminderDraftView { title, fireAt, repeatRule, audit in
                // 通用 Reminder 语义（FR8.10 同实体）：经调度通道落「voice-rem-」通知；
                // 模糊时间必须落具体日期（FR10.2）——视图层 resolveDate 已强制。
                // 调度成败回传（审查修复）：失败时调用方可见报错、绝不弹「已保存」
                await reminders.scheduleVoiceReminder(title: title, fireAt: fireAt,
                                                      repeatRule: repeatRule,
                                                      patientId: app.currentPatientId,
                                                      audit: audit)
            }
        }
    }
}

/// FR17.14 语音速记条目（挂载适配：面板作为导航目的地呈现）
struct VoiceNotePanelRouteView: View {
    var body: some View {
        WithPerceptionTracking {
            VoiceNotePanelView()
        }
    }
}
