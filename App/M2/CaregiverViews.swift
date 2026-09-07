import SwiftUI
import Domain
import Infrastructure   // FamilyPendingDose（FR24.5 跨成员投影）

/// FR24.5 同机照护者视图：本机家庭模式下，"帮家人处理"聚合入口。
/// 列出可代确认的待办（FR9.5 家人代确认语义，等同 taken）；
/// 代处理动作写审计并提示"由你代确认"。
///
/// BR-001 纪律（评审修正）：待办来自 `familyPendingDoses` 跨成员聚合查询，
/// 每行携带 dose 所属 patientId——代确认落回**该剂量所属成员**，
/// 绝不使用 currentPatientId 张冠李戴；成员名来自 patient_profile 而非硬编码。
struct CaregiverViews: View {
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminderStore
    @Environment(AppSettingsStore.self) private var settings
    @Environment(AppRouter.self) private var router
    @State private var pendingDoses: [FamilyPendingDose] = []
    @State private var showConfirmAlert = false
    @State private var selectedDose: FamilyPendingDose?

    var body: some View {
        // FR14.1 authFamilyAccess 消费点：关闭 → 照护者视图呈禁用说明态
        if settings.values[.authFamilyAccess] == "false" {
            ContentUnavailableView(L10n.privacyAuthFamilyDisabled,
                                   systemImage: "person.2.slash",
                                   description: Text(L10n.privacyAuthFamilyDisabledBody))
            .safeAreaInset(edge: .bottom) {
                Button {
                    router.navigate(to: .privacyAuthorization)
                } label: {
                    Text(L10n.privacyAuthOpen).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .padding(16)
            }
        } else {
        List {
            if pendingDoses.isEmpty {
                ContentUnavailableView(L10n.caregiverEmpty,
                                       systemImage: "checkmark.circle",
                                       description: Text(L10n.caregiverEmptyHint))
                    .accessibilityIdentifier("FR24.5.empty")
            } else {
                ForEach(pendingDoses) { item in
                    Button {
                        selectedDose = item
                        showConfirmAlert = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.patientName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(item.medicationName)
                                    .font(.headline)
                                // 窗口含前一日（昨日漏确认剂量在 sweep 前仍可代确认）：
                                // 非今日剂量必须带日期，否则昨日 10:00 与今日 10:00
                                // 无法区分，代确认可能错认日期
                                let isToday = Calendar.current.isDate(item.dose.dueAt, inSameDayAs: Date())
                                Text(L10n.caregiverPending(
                                    item.dose.dueAt.formatted(date: isToday ? .omitted : .abbreviated,
                                                              time: .shortened)))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Image(systemName: "person.2.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("FR24.5.row")
                }
            }
        }
        .navigationTitle(L10n.caregiverTitle)
        .alert(L10n.caregiverAlertTitle, isPresented: $showConfirmAlert) {
            Button(L10n.commonCancel, role: .cancel) { }
            Button(L10n.caregiverAlertConfirm) {
                if let dose = selectedDose {
                    Task {
                        await confirmOnBehalf(of: dose)
                    }
                }
            }
        } message: {
            if let dose = selectedDose {
                Text(L10n.caregiverAlertBody(patient: dose.patientName,
                                             medication: dose.medicationName))
            }
        }
        .task { await loadPendingDoses() }
        }
    }

    private func loadPendingDoses() async {
        // 跨成员聚合待确认剂量（FR24.5 数据源；成员名与归属由查询携带）
        do {
            let cal = Calendar.current
            let dayStart = cal.startOfDay(for: Date())
            // 第八轮修复：日界统一经 DayArithmetic 出口（DST 纪律单一事实源）
            let dayEnd = DayArithmetic.offset(days: 1, from: dayStart, calendar: cal)
            // 窗口含前一日：昨日漏确认的剂量在 sweep 物化为 missed 之前
            // 仍可代确认（此前 [今日,明日) 窗口使逾期待办从队列永久消失）
            let windowStart = DayArithmetic.offset(days: -1, from: dayStart, calendar: cal)
            pendingDoses = try await reminderStore.familyPendingDoses(from: windowStart, to: dayEnd)
        } catch {
            // 审查修复：读取失败保留旧列表（原置空让未确认剂量从队列静默消失）
        }
    }

    private func confirmOnBehalf(of item: FamilyPendingDose) async {
        // 代确认走同一 apply(.taken) 路径，落回剂量所属成员（BR-001），
        // 成功后写审计「由你代确认」（FR24.5）。
        // 审查修复：确认失败不得写代确认审计、不得清空待办列表（审计=事实，
        // 写失败即审计撒谎；列表被 reload 错误清空则未确认剂量从队列消失）
        let ok = await reminderStore.confirmTaken(patientId: item.patientId, dose: item.dose)
        guard ok else { return }
        app.auditCaregiverConfirm(doseId: item.dose.notifyId, patientId: item.patientId)
        await loadPendingDoses()
    }
}
