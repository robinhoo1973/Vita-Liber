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
            // 通用 Reminder 语义（FR8.10 同实体）：经调度通道落「voice-rem-」通知；
            // 模糊时间必须落具体日期（FR10.2）——视图层 resolveDate 已强制。
            // 调度成败回传（审查修复）：失败时调用方可见报错、绝不弹「已保存」
            await reminders.scheduleVoiceReminder(title: title, fireAt: fireAt,
                                                  repeatRule: repeatRule,
                                                  patientId: app.currentPatientId)
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
///
/// TestFlight 实测修复：访谈步骤 key（allergy/pastHistory/currentMeds/
/// emergencyContact）原与可写字段零匹配，`default: break` 把用户答案
/// 静默丢弃——「语音完善」形同虚设。现访谈四步一律以结构化段落追加进
/// profile.note（绝不丢数据），过敏/用药/联系人结构化落库登记技术债，
/// 待 M2 对应 store 接口接齐后迁移。
struct VoiceGuidedProfileRouteView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let patientId = app.currentPatientId
        VoiceGuidedProfileView { key, value in
            await app.commitVoiceProfileField(key, value: value, patientId: patientId)
        }
        // 同一无参路由可能留在 Me 栈顶：换人必须重建答案/步骤/确认态，
        // 旧会话在途提交仍只持有上面捕获的原 patientId（BR-001）。
        .id(patientId)
    }
}
