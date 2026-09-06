import SwiftUI
import Domain
import Infrastructure   // MedicationStore.InventorySummaryItem / GuidelineStore.AlertEvent

/// FR14.8 通知中心（SP-27 · ui-ux §5.19）：集中展示未读/已处理的用药、预约、
/// 临期、设备观察提示、待确认 OCR 和系统状态消息；每条含来源、处理状态和下一步。
/// 不替代 FR14.2 审计日志（审计是事实流水，通知中心是可行动消息流）。
///
/// 数据源 = 环境仓的当前成员投影（BR-001 各仓已隔离）；本视图零业务判定。
struct NotificationCenterView: View {
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminderStore
    @Environment(M2HubStore.self) private var hub
    @Environment(AppRouter.self) private var router
    @Environment(NotificationCenterState.self) private var notificationState
    @Environment(DocumentsState.self) private var docs

    /// 条目处理状态（已读/归档持久化；未登记 = .unread）
    @State private var itemStates: [String: NotificationItemState] = [:]

    var body: some View {
        List {
            if !pendingDoses.isEmpty {
                Section(L10n.ncSectionPending) {
                    ForEach(Array(pendingDoses.enumerated()), id: \.offset) { _, dose in
                        PendingDoseRow(dose: dose) {
                            Task {
                                await reminderStore.confirmTaken(patientId: app.currentPatientId,
                                                                 dose: dose.dose)
                            }
                        }
                    }
                }
            }
            if !appointments.isEmpty {
                Section(L10n.ncSectionAppointment) {
                    ForEach(appointments.filter { state(for: "apt-\($0.id)") != .archived }) { apt in
                        Button {
                            markRead("apt-\(apt.id)")
                            router.navigate(to: .appointmentDetail(apt.id))
                        } label: {
                            HStack {
                                Image(systemName: "stethoscope").foregroundStyle(Color("brand-primary", bundle: .main))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(apt.hospital)·\(apt.department)").font(.subheadline)
                                    Text(apt.startsAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .accessibilityIdentifier("SP-27.notification.appointment")
                        .swipeActions { archiveAction("apt-\(apt.id)") }
                    }
                }
            }
            if !expiringLots.isEmpty {
                Section(L10n.ncSectionExpiry) {
                    ForEach(expiringLots.filter { state(for: "lot-\($0.lotId)") != .archived }) { item in
                        Button {
                            markRead("lot-\(item.lotId)")
                            router.navigate(to: .medicationCabinet)
                        } label: {
                            HStack {
                                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Color("semantic-warning", bundle: .main))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.medicationName).font(.subheadline)
                                    if let expireAt = item.expireAt {
                                        Text(L10n.ncExpireDate(
                                            expireAt.formatted(date: .abbreviated, time: .omitted)))
                                            .font(.caption).foregroundStyle(Color("semantic-warning", bundle: .main))
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .swipeActions { archiveAction("lot-\(item.lotId)") }
                    }
                }
            }
            if !l1Alerts.isEmpty {
                Section(L10n.ncSectionAlert) {
                    ForEach(l1Alerts.filter { state(for: "alert-\($0.id)") != .archived }) { event in
                        Button {
                            markRead("alert-\(event.id)")
                            router.navigate(to: .alertHistory)
                        } label: {
                            HStack {
                                Image(systemName: "waveform.path.ecg").foregroundStyle(Color("semantic-danger", bundle: .main))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.card.summaryTitle ?? event.severity.rawValue).font(.subheadline)
                                    Text("\(event.severity.rawValue) · \(event.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(Color("semantic-danger", bundle: .main))
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .swipeActions { archiveAction("alert-\(event.id)") }
                    }
                }
            }
            if pendingOCRCount > 0 {
                Section(L10n.ncSectionOcr) {
                    Button {
                        router.navigate(to: .pendingOcrQueue)
                    } label: {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color("semantic-warning", bundle: .main))
                            Text(L10n.ncOcrCount(pendingOCRCount)).font(.subheadline)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("SP-27.notification.ocr")
                    .swipeActions { archiveAction("ocr-queue") }
                }
            }
            if allEmpty {
                ContentUnavailableView(L10n.ncEmpty, systemImage: "bell.slash",
                                       description: Text(L10n.ncEmptyHint))
                    .accessibilityIdentifier("SP-27.empty")
            }
        }
        .navigationTitle(L10n.ncTitle)
        .task(id: app.currentPatientId) {
            await reminderStore.refreshTriggered(patientId: app.currentPatientId)
            await hub.load(patientId: app.currentPatientId)
            await docs.load(patientId: app.currentPatientId)
            await loadStates()
        }
    }

    // 待处理剂量（未决 + 未过期）
    private var pendingDoses: [DoseRecord] {
        reminderStore.todaySlots
            .flatMap(\.records)
            .filter { $0.action == nil && $0.dose.dueAt <= Date().addingTimeInterval(30 * 60) }
    }

    private var appointments: [AppointmentRow] { reminderStore.upcomingAppointments }

    /// 临期批次（30 天内到期，FR9.11 窗口对齐）
    private var expiringLots: [MedicationStore.InventorySummaryItem] {
        let window = DayArithmetic.offset(days: 30)
        return hub.inventoryItems.filter { item in
            guard let expireAt = item.expireAt else { return false }
            return expireAt <= window
        }
    }

    private var l1Alerts: [GuidelineStore.AlertEvent] {
        hub.alertEvents.filter { $0.severity != .L0 && $0.patientId == app.currentPatientId }
    }

    /// 待确认 OCR 数：grade 'D' 文档数（V3.39 起数据源 = DocumentStore 活管线）
    private var pendingOCRCount: Int {
        docs.documents.filter { $0.grade == "D" }.count
    }

    private func state(for key: String) -> NotificationItemState { itemStates[key] ?? .unread }

    private func loadStates() async {
        var keys: [String] = []
        keys += pendingDoses.map { "dose-\($0.id)" }
        keys += appointments.map { "apt-\($0.id)" }
        keys += expiringLots.map { "lot-\($0.lotId)" }
        keys += l1Alerts.map { "alert-\($0.id)" }
        if pendingOCRCount > 0 { keys.append("ocr-queue") }
        await notificationState.load(keys: keys)
    }

    private func markRead(_ key: String) {
        itemStates[key] = .read
        Task {
            try? await notificationState.markRead(key)   // try?-ok: 标记失败下次进入仍可重试，不阻断导航
        }
    }

    @ViewBuilder
    private func archiveAction(_ key: String) -> some View {
        Button(role: .destructive) {
            itemStates[key] = .archived
            Task {
                try? await notificationState.markArchived(key)   // try?-ok: 归档失败保留本地态，下次重载校正
            }
        } label: {
            Label(L10n.ncArchive, systemImage: "archivebox")
        }
    }

    private var allEmpty: Bool {
        pendingDoses.isEmpty && appointments.isEmpty && expiringLots.isEmpty
            && l1Alerts.isEmpty && pendingOCRCount == 0
    }
}

/// 待处理剂量行（独立子视图：缩小 ForEach 内容闭包的类型检查单元，
/// 避开 Xcode 26 上复杂闭包的重载求解失败）
private struct PendingDoseRow: View {
    let dose: DoseRecord
    let onConfirm: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "pills.fill")
                .foregroundStyle(Color("brand-primary", bundle: .main))
            VStack(alignment: .leading, spacing: 2) {
                Text(dose.displayLabel).font(.subheadline)
                Text(L10n.ncNextActionDose).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.ncConfirmDose, action: onConfirm)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                                .frame(minHeight: 44)   // 触点≥44pt（审查修复）
        }
        .accessibilityIdentifier("SP-27.notification.dose.\(dose.id)")
    }
}
