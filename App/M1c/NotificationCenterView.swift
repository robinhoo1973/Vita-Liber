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

    var body: some View {
        List {
            if !pendingDoses.isEmpty {
                Section(L10n.ncSectionPending) {
                    ForEach(pendingDoses, id: \.dose.notifyId) { dose in
                        HStack {
                            Image(systemName: "pills.fill")
                                .foregroundStyle(Color("brand-primary", bundle: .main))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dose.displayLabel).font(.subheadline)
                                Text(L10n.ncNextActionDose).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L10n.ncConfirmDose) {
                                Task {
                                    await reminderStore.confirmTaken(patientId: app.currentPatientId,
                                                                     dose: dose.dose)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .accessibilityIdentifier("SP-27.notification.dose.\(dose.notifyId)")
                    }
                }
            }
            if !appointments.isEmpty {
                Section(L10n.ncSectionAppointment) {
                    ForEach(appointments) { apt in
                        Button {
                            router.navigate(to: .appointmentList)
                        } label: {
                            HStack {
                                Image(systemName: "stethoscope").foregroundStyle(.blue)
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
                    }
                }
            }
            if !expiringLots.isEmpty {
                Section(L10n.ncSectionExpiry) {
                    ForEach(expiringLots) { item in
                        Button {
                            router.navigate(to: .medicationCabinet)
                        } label: {
                            HStack {
                                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.medicationName).font(.subheadline)
                                    if let expireAt = item.expireAt {
                                        Text(L10n.ncExpireDate(
                                            expireAt.formatted(date: .abbreviated, time: .omitted)))
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            if !l1Alerts.isEmpty {
                Section(L10n.ncSectionAlert) {
                    ForEach(l1Alerts) { event in
                        Button {
                            router.navigate(to: .alertHistory)
                        } label: {
                            HStack {
                                Image(systemName: "waveform.path.ecg").foregroundStyle(.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.card.sourceRef ?? event.card.facts).font(.subheadline)
                                    Text("\(event.severity.rawValue) · \(event.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.red)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            if pendingOCRCount > 0 {
                Section(L10n.ncSectionOcr) {
                    Button {
                        router.navigate(to: .pendingOcrQueue)
                    } label: {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            Text(L10n.ncOcrCount(pendingOCRCount)).font(.subheadline)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("SP-27.notification.ocr")
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
            await reminderStore.refresh(patientId: app.currentPatientId)
            await hub.load(patientId: app.currentPatientId)
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
        let window = Date().addingTimeInterval(30 * 86400)
        return hub.inventoryItems.filter { item in
            guard let expireAt = item.expireAt else { return false }
            return expireAt <= window
        }
    }

    private var l1Alerts: [GuidelineStore.AlertEvent] {
        hub.alertEvents.filter { $0.severity != .L0 && $0.patientId == app.currentPatientId }
    }

    private var pendingOCRCount: Int {
        app.timeline.reduce(0) { $0 + $1.fields.filter { !$0.isConfirmed }.count }
    }

    private var allEmpty: Bool {
        pendingDoses.isEmpty && appointments.isEmpty && expiringLots.isEmpty
            && l1Alerts.isEmpty && pendingOCRCount == 0
    }
}
