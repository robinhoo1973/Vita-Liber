import SwiftUI
import Domain

/// FR24.5 同机照护者视图：本机家庭模式下，"帮家人处理"聚合入口。
/// 列出可代确认的待办（FR9.5 家人代确认语义，等同 taken）；
/// 代处理动作写审计并提示"由你代确认"。
struct CaregiverViews: View {
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminderStore
    @State private var pendingDoses: [PendingDoseItem] = []
    @State private var showConfirmAlert = false
    @State private var selectedDose: PendingDoseItem?

    var body: some View {
        List {
            if pendingDoses.isEmpty {
                ContentUnavailableView("无待处理事项",
                                       systemImage: "checkmark.circle",
                                       description: Text("所有家人的提醒已处理"))
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
                                Text("待确认 · \(item.scheduledTime)")
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
        .navigationTitle("帮家人处理")
        .alert("代确认提醒", isPresented: $showConfirmAlert) {
            Button("取消", role: .cancel) { }
            Button("确认代处理") {
                if let dose = selectedDose {
                    Task {
                        await confirmOnBehalf(of: dose)
                    }
                }
            }
        } message: {
            if let dose = selectedDose {
                Text("确认代 \(dose.patientName) 处理「\(dose.medicationName)」？\n此操作将记录为由你代确认。")
            }
        }
        .task { loadPendingDoses() }
    }

    private func loadPendingDoses() {
        // 聚合所有家庭成员的待确认剂量
        // FR9.5 家人代确认语义：等同 taken
        pendingDoses = reminderStore.todaySlots
            .flatMap { slot in
                slot.records.compactMap { record in
                    guard record.action == nil else { return nil }
                    return PendingDoseItem(
                        id: record.dose.notifyId,
                        patientName: "家人",
                        medicationName: record.displayLabel,
                        scheduledTime: record.dose.dueAt.formatted(date: .omitted, time: .shortened),
                        dose: record.dose
                    )
                }
            }
    }

    private func confirmOnBehalf(of item: PendingDoseItem) async {
        // 代确认走同一 apply(.taken) 路径并写 audit 标注「由你代确认」
        await reminderStore.confirmTaken(
            patientId: app.currentPatientId,
            dose: item.dose
        )
        loadPendingDoses()
    }
}

/// 待确认剂量条目
private struct PendingDoseItem: Identifiable {
    let id: String
    let patientName: String
    let medicationName: String
    let scheduledTime: String
    let dose: ScheduledDose
}
