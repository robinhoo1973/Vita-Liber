import SwiftUI
import Domain
import Infrastructure   // MedicationStore.InventorySummaryItem / GuidelineStore.AlertEvent
import Perception

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
    @Environment(AppDataChangeCenter.self) private var dataChange

    /// 第四轮全仓审查修复（5WHY）：视图曾维护本地 @State itemStates 影子副本，
    /// 而 NotificationCenterState.load(keys:) 灌入的持久化状态（重启后已读/
    /// 归档）从不被消费——持久化形同虚设、重启即全部回到未读（FR14.8
    /// 回归）。渲染与写入一律走门面 itemStates，删除影子副本。
    ///
    /// round2 U-N4/U-N5（FR14.8 / FR2.1⑦）：归档键经 Domain `NotificationItemKey` 单一编码，
    /// 与首页同命名空间；归档只走门面悲观路径 `archive(_:)`（先落库、成功才改可观察态），
    /// 失败行仍可见并可重试——乐观 `markArchived` 已删除。
    @State private var archiveFailedKey: String?
    @State private var showArchiveFailed = false

    var body: some View {
        WithPerceptionTracking {
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
                if !visibleAppointments.isEmpty {
                    Section(L10n.ncSectionAppointment) {
                        ForEach(visibleAppointments) { apt in
                            Button {
                                markRead(aptKey(apt))
                                router.navigate(to: .appointmentDetail(apt.id))
                            } label: {
                                HStack {
                                    // §3.4 单一出口：预约 = `calendar.badge.clock`（原硬编码 `stethoscope`
                                    // 是**就诊**符号，且绕过类别图标出口；色令牌不变 = brand）。
                                    Image(systemName: CardKindIcon.spec(timelineKind: .appointment).symbol)
                                        .foregroundStyle(CardKindIcon.spec(timelineKind: .appointment).tint)
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
                            .swipeActions { archiveAction(aptKey(apt)) }
                        }
                    }
                }
                if !visibleExpiringLots.isEmpty {
                    Section(L10n.ncSectionExpiry) {
                        ForEach(visibleExpiringLots) { item in
                            Button {
                                markRead(lotKey(item))
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
                            .swipeActions { archiveAction(lotKey(item)) }
                        }
                    }
                }
                if !visibleL1Alerts.isEmpty {
                    Section(L10n.ncSectionAlert) {
                        ForEach(visibleL1Alerts) { event in
                            Button {
                                markRead(alertKey(event))
                                router.navigate(to: .alertEvidence(patientId: event.patientId, eventId: event.id, severity: event.severity))
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
                            // round2 U-N3：L1+ 预警归档不开放全滑——须点按钮显式归档（BR-003 高风险不被整行拖走）
                            .swipeActions(allowsFullSwipe: false) { archiveAction(alertKey(event)) }
                        }
                    }
                }
                // round2 U-N4：跨成员全局键 "ocr-queue" 废止——它与首页按文档的 ocr-<docId> 键
                // 不同源，且归档一次会隐藏所有成员的待确认入口（BR-003 催办不可被整体藏起）。
                // OCR 行只做导航，不再归档；待确认文档的处置（稍后/查看）在首页按文档进行。
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
                    }
                }
                if allEmpty {
                    VLUnavailableView(L10n.ncEmpty, systemImage: "bell.slash",
                                           description: Text(L10n.ncEmptyHint))
                        .accessibilityIdentifier("SP-27.empty")
                }
            }
            .navigationTitle(L10n.ncTitle)
            // 悲观归档失败可见（U-N5）：行仍在，用户可重试或取消
            .alert(L10n.homeSwipeFailed, isPresented: $showArchiveFailed, presenting: archiveFailedKey) { key in
                Button(L10n.retry) { archive(key) }
                Button(L10n.commonCancel, role: .cancel) {}
            } message: { _ in
                Text(L10n.ncArchive)
            }
            .task(id: "\(app.currentPatientId)-\(dataChange.alertsVersion)") {
                await reminderStore.refreshTriggered(patientId: app.currentPatientId)
                await hub.load(patientId: app.currentPatientId)
                await docs.load(patientId: app.currentPatientId)
                await loadStates()
            }
        }
    }

    // 待处理剂量（未决 + 未过期）——窗口容差走 Domain 单一事实源
    // DoseSlotGrouping.tolerance（±30min），视图不再裸写 30*60
    private var pendingDoses: [DoseRecord] {
        reminderStore.todaySlots
            .flatMap(\.records)
            .filter { $0.isUnresolved && $0.dose.dueAt <= Date().addingTimeInterval(DoseSlotGrouping.tolerance) }
    }

    private var appointments: [AppointmentRow] { reminderStore.upcomingAppointments }

    // 审查修复（归档过滤与空态同源）：此前行渲染按归档过滤、节头与 allEmpty
    // 用未过滤数组——全部归档后节头空挂（有标题零行）、空态永不出现
    // （整页空白）。可见性谓词收敛为单一计算属性，节头/行/空态三处同源。
    private var visibleAppointments: [AppointmentRow] {
        appointments.filter { state(for: aptKey($0)) != .archived }
    }

    // MARK: - 归档键（Domain 单一编码，与首页 NotificationItemKey.hideKeys 同命名空间）

    private func aptKey(_ apt: AppointmentRow) -> String {
        NotificationItemKey.key(kind: "appointment", sourceId: apt.id.uuidString)
    }
    /// lot- = 该批次库存类通知（续药/临期共用）：任一入口归档，首页同批次续药行与本页临期行同隐。
    private func lotKey(_ item: MedicationStore.InventorySummaryItem) -> String {
        NotificationItemKey.key(kind: "refill", sourceId: item.lotId.uuidString)
    }
    private func alertKey(_ event: GuidelineStore.AlertEvent) -> String {
        NotificationItemKey.key(kind: "alert_event", sourceId: event.id.uuidString)
    }

    /// 临期批次（30 天内到期，FR9.11 窗口对齐）
    private var expiringLots: [MedicationStore.InventorySummaryItem] {
        let window = DayArithmetic.offset(days: 30)
        return hub.inventoryItems.filter { item in
            guard let expireAt = item.expireAt else { return false }
            return expireAt <= window
        }
    }

    private var visibleExpiringLots: [MedicationStore.InventorySummaryItem] {
        expiringLots.filter { state(for: lotKey($0)) != .archived }
    }

    private var l1Alerts: [GuidelineStore.AlertEvent] {
        hub.qualifiedAlertEvents.filter { $0.qualified && $0.severity != .L0 && $0.patientId == app.currentPatientId }
    }

    private var visibleL1Alerts: [GuidelineStore.AlertEvent] {
        l1Alerts.filter { state(for: alertKey($0)) != .archived }
    }

    /// 待确认 OCR 数：D 级文档数（V3.39 起数据源 = DocumentStore 活管线；
    /// 谓词收敛为 DocumentRow.isPendingConfirmation）
    private var pendingOCRCount: Int {
        docs.documents.filter(\.isPendingConfirmation).count
    }

    private func state(for key: String) -> NotificationItemState {
        notificationState.itemStates[key] ?? .unread
    }

    private func loadStates() async {
        // dose- 键本页从未读写（U-N4 死键，用药行只有确认按钮）；ocr-queue 跨成员全局键已废——
        // OCR 行只做导航。门面 load(keys:) 只合并所请求键，不再整体替换。
        var keys: [String] = []
        keys += appointments.map(aptKey)
        keys += expiringLots.map(lotKey)
        keys += l1Alerts.map(alertKey)
        await notificationState.load(keys: keys)
    }

    private func markRead(_ key: String) {
        notificationState.markRead(key)
    }

    /// 悲观归档（与首页同一门面路径）：先落库、成功才改可观察态；失败行仍可见，弹重试。
    private func archive(_ key: String) {
        Task {
            do { try await notificationState.archive(key) }
            catch { archiveFailedKey = key; showArchiveFailed = true }
        }
    }

    /// 归档不是删除医疗事实（只写 notification_state），故不用 destructive 角色。
    @ViewBuilder
    private func archiveAction(_ key: String) -> some View {
        Button { archive(key) } label: { Label(L10n.ncArchive, systemImage: "archivebox") }
            .tint(.orange)
    }

    private var allEmpty: Bool {
        // 审查修复（与行可见性同源）：改用归档过滤后的可见数组——
        // 原实现全部归档后空态不出现、整页空白。
        pendingDoses.isEmpty && visibleAppointments.isEmpty && visibleExpiringLots.isEmpty
            && visibleL1Alerts.isEmpty && pendingOCRCount == 0
    }
}

/// 待处理剂量行（独立子视图：缩小 ForEach 内容闭包的类型检查单元，
/// 避开 Xcode 26 上复杂闭包的重载求解失败）
private struct PendingDoseRow: View {
    let dose: DoseRecord
    let onConfirm: () -> Void

    var body: some View {
        WithPerceptionTracking {
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
}
