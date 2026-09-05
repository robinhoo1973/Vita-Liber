import SwiftUI
import Domain
import Infrastructure

/// F2 首页 TodayView（SP-04 · ui-ux §5.2）。
///
/// 八卡固定顺序（FR2.1）：①成员切换条 ②今日待办（时段聚合 FR9.17 + 预约，
/// 合并按时间排序）③待确认 OCR ④即将到期（7 天窗口）⑤续药卡（余量≤7 天）
/// ⑥观察提示摘要（仅 L1+）⑦最近异常观察 ⑧快速拍摄四入口。
/// 右上：🎤 语音速记入口（FR17.9）+ 🔔 通知中心铃铛（FR14.8，未读角标）。
/// 关怀模式开启后本页被 FR18.5 四大卡版式**覆写**（同 ADR-021 单视图双态）。
///
/// 数据全部来自环境仓的**当前成员**投影（BR-001：各仓已在加载侧隔离成员），
/// 本视图只做快照组装与呈现，不做业务判定。
struct HomeView: View {
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminderStore
    @Environment(M2HubStore.self) private var hub
    @Environment(ObservationStoreState.self) private var observationState
    @Environment(AppRouter.self) private var router
    @State private var showMemberPicker = false
    @State private var showSOS = false
    @State private var showVoiceNote = false
    @State private var showVoicePanel = false
    @State private var notifDenied = false
    @State private var dismissNotifBanner = false

    private var snapshot: TodaySnapshot {
        TodayAggregator.snapshot(
            member: app.currentPatientId,
            todos: todoItems,
            pendingOCRCount: pendingOCRCount,
            expiring: expiringItems,
            refills: refillItems,
            alerts: alertRefs,
            observations: obsRefs)
    }

    // ② 今日待办：时段卡（FR9.17）+ 预约 + 批次补录待办（FR9.10），合并按时间排序
    private var todoItems: [TodoItem] {
        var items: [TodoItem] = []
        for slot in reminderStore.todaySlots {
            let meds = slot.records.map(\.displayLabel).joined(separator: "、")
            items.append(TodoItem(kind: .doseSlot, at: slot.anchorTime,
                                  title: meds.isEmpty ? L10n.homeDoseSlot : meds,
                                  memberId: app.currentPatientId))
        }
        for apt in reminderStore.upcomingAppointments {
            items.append(TodoItem(kind: .appointment, at: apt.startsAt,
                                  title: "\(apt.hospital)·\(apt.department)",
                                  memberId: app.currentPatientId))
        }
        // FR9.10：效期或存放位置缺失的批次 → 批次补录待办（补齐后消除）
        for item in hub.inventoryItems where item.expireAt == nil || (item.storageNote ?? "").isEmpty {
            items.append(TodoItem(kind: .stockBacklog, at: Date(),
                                  title: L10n.homeStockBacklog(item.medicationName),
                                  memberId: app.currentPatientId))
        }
        return items.sorted { $0.at < $1.at }
    }

    // ③ 待确认 OCR 数：时间轴投影中未确认字段计数（BR-003 未确认不进正式区，
    // 首页必须持续催办直至处理，72h 置顶规则由 FR2.3 承接）
    private var pendingOCRCount: Int {
        app.timeline.reduce(0) { $0 + ($1.fields ?? []).filter { !$0.isConfirmed }.count }
    }

    // ④ 即将到期（7 天窗口）：预约 + 药品临期（FR9.11 批次效期在 Phase 2 并入）
    private var expiringItems: [ExpiryItem] {
        let window = Date().addingTimeInterval(7 * 86400)
        return reminderStore.upcomingAppointments
            .filter { $0.startsAt <= window }
            .map { ExpiryItem(title: "\($0.hospital)·\($0.department)", date: $0.startsAt,
                              memberId: app.currentPatientId) }
    }

    // ⑤ 续药卡（FR9.8.3）：余量≤7 天出现——诚实性文案「约剩 N 天·按计划估算」
    private var refillItems: [RefillItem] {
        hub.inventoryItems.compactMap { item in
            guard let days = item.approxDaysLeft, days <= 7 else { return nil }
            return RefillItem(medicationName: item.medicationName,
                              remainingPlanUnits: item.remainingPlanUnits,
                              memberId: app.currentPatientId)
        }
    }

    // ⑥ 观察提示摘要（仅 L1+）
    private var alertRefs: [AlertRef] {
        hub.alertEvents
            .filter { $0.severity != .L0 && $0.patientId == app.currentPatientId }
            .map { AlertRef(severity: $0.severity.rawValue,
                            title: $0.card.sourceRef ?? $0.card.facts,
                            memberId: app.currentPatientId) }
    }

    // ⑦ 最近异常观察（横向缩略图列，锁定态联动 F8 保护链）
    private var obsRefs: [ObsRef] {
        observationState.groups
            .flatMap { $0.occurrences }
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(3)
            .map { ObsRef(id: $0.id, kind: $0.kind.rawValue,
                          occurredAt: $0.occurredAt, memberId: app.currentPatientId) }
    }

    var body: some View {
        Group {
            if app.careMode {
                careModeHome   // FR18.5 四大卡版式覆写
            } else {
                standardHome
            }
        }
        .navigationTitle(headerTitle)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // FR17.9 全局语音入口（FR14.7 voiceEntryVisible 可隐藏）→ 语音速记面板 SP-55
                if settingsVoiceEntryVisible {
                    Button {
                        showVoicePanel = true
                    } label: {
                        Image(systemName: "mic.fill")
                    }
                    .accessibilityIdentifier("SP-04.home.mic")
                }
                // FR14.8 通知中心铃铛（未读角标不显示病名药名，§5 通知隐私）
                NavigationLink(value: AppRoute.notificationCenter) {
                    Image(systemName: "bell")
                }
                .accessibilityIdentifier("SP-04.home.bell")
                .badge(reminderStore.pendingCount > 0 ? reminderStore.pendingCount : 0)
            }
        }
        .sheet(isPresented: $showMemberPicker) {
            MemberPickerSheet()
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showSOS) { SOSHelpView() }
        .sheet(isPresented: $showVoicePanel) { VoiceQuickLaunchView() }
        .sheet(isPresented: $showVoiceNote) { VoiceNotePanelView() }
        .task(id: app.currentPatientId) { await load() }
    }

    // MARK: - 标准八卡

    private var standardHome: some View {
        ScrollView {
            VStack(spacing: 16) {
                if isEmptyNewUser {
                    newUserGuide
                } else {
                    if notifDenied && !dismissNotifBanner {
                        notifDeniedBanner
                    }
                    if !snapshot.todoItems.isEmpty {
                        todoCard
                    }
                    if app.profileCompletion.done < app.profileCompletion.total {
                        profileProgressCard   // mock 对齐项：档案完善进度卡（成熟用户续填入口）
                    }
                    if snapshot.pendingOCRCount > 0 {
                        pendingOcrCard
                    }
                    if !snapshot.expiringSoon.isEmpty {
                        expiringSoonCard
                    }
                    if !snapshot.refill.isEmpty {
                        refillCard
                    }
                    if !snapshot.alertSummary.isEmpty {
                        alertSummaryCard
                    }
                    if !snapshot.recentObservations.isEmpty {
                        recentObservationsCard
                    }
                    quickCaptureCard
                    // mock 对齐项：底部免责声明（医疗产品信任资产，呼应「不联网·不诊断」承诺）
                    Text(L10n.homeDisclaimer)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                        .accessibilityIdentifier("SP-04.home.disclaimer")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .accessibilityIdentifier("SP-04.home.standard")
    }

    // 空态：新用户三引导任务（建档/拍第一份资料/设第一个提醒），完成打勾消失
    private var isEmptyNewUser: Bool {
        snapshot.todoItems.isEmpty && app.timeline.isEmpty
            && observationState.groups.isEmpty
    }

    private var newUserGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            GuideTaskCard(icon: "person.crop.circle.badge.plus", title: L10n.homeGuide1, done: !app.members.isEmpty) {
                router.navigate(to: .memberList)
            }
            GuideTaskCard(icon: "camera.fill", title: L10n.homeGuide2, done: !app.timeline.isEmpty) {
                router.navigate(to: .scanCapture(.record))
            }
            GuideTaskCard(icon: "bell.badge.fill", title: L10n.homeGuide3, done: !reminderStore.todaySlots.isEmpty) {
                router.navigate(to: .medicationPlanForm(nil))
            }
        }
        .accessibilityIdentifier("SP-04.home.emptyGuide")
    }

    private var notifDeniedBanner: some View {
        HStack {
            Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
            Text(L10n.homeNotifDenied)
                .font(.footnote)
            Spacer()
            Button(L10n.homeNotifOpen) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.footnote)
            Button {
                dismissNotifBanner = true
            } label: {
                Image(systemName: "xmark").font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("SP-04.home.notifDenied.dismiss")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
        .accessibilityIdentifier("SP-04.home.notifDenied")
    }

    private var todoCard: some View {
        CardSection(title: L10n.homeTodayTodos) {
            ForEach(snapshot.todoItems) { item in
                Button {
                    switch item.kind {
                    case .doseSlot:
                        // 直达服药确认（FR2.2）：切到提醒 Tab 的时段确认面板
                        router.navigate(to: .appointmentList)   // Phase 3 换时段确认路由
                    case .appointment:
                        router.navigate(to: .appointmentList)
                    case .stockBacklog:
                        router.navigate(to: .medicationCabinet)
                    default:
                        break
                    }
                } label: {
                    HStack {
                        Image(systemName: item.kind == .doseSlot ? "pills.fill" : "stethoscope")
                            .foregroundStyle(Color("brand-primary", bundle: .main))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.subheadline)
                            Text(item.at.formatted(date: .omitted, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("SP-04.home.todo.\(item.kind.rawValue)")
            }
        }
    }

    /// 档案完善进度卡（mock 对齐项）：显示已完善 X/Y 项 + 一键续填语音访谈
    private var profileProgressCard: some View {
        let c = app.profileCompletion
        return Button {
            router.navigate(to: .voiceGuideProfile)   // 续填走语音访谈（可手输，FR17.11）
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.text.rectangle")
                    .foregroundStyle(Color("brand-primary", bundle: .main))
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.homeProfileProgressTitle).font(.subheadline).bold()
                    Text(L10n.homeProfileProgressFmt(c.done, c.total))
                        .font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: Double(c.done), total: Double(c.total))
                        .tint(Color("brand-primary", bundle: .main))
                }
                Spacer()
                Text(L10n.homeProfileContinue)
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(Color("brand-primary", bundle: .main))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SP-04.home.profileProgress")
    }

    private var pendingOcrCard: some View {
        Button {
            router.navigate(to: .pendingOcrQueue)
        } label: {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(L10n.homePendingOcrCount(snapshot.pendingOCRCount))
                    .font(.subheadline).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.yellow.opacity(0.15)))
        }
        .accessibilityIdentifier("SP-04.home.pendingOcr")
    }

    private var expiringSoonCard: some View {
        CardSection(title: L10n.homeExpiringSoon) {
            ForEach(snapshot.expiringSoon) { item in
                HStack {
                    Image(systemName: "calendar.badge.clock").foregroundStyle(.blue)
                    Text(item.title).font(.subheadline)
                    Spacer()
                    Text(item.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var refillCard: some View {
        CardSection(title: L10n.homeRefill) {
            ForEach(snapshot.refill) { item in
                Button {
                    router.navigate(to: .medicationCabinet)
                } label: {
                    HStack {
                        Image(systemName: "pills.circle.fill").foregroundStyle(.orange)
                        Text(item.medicationName).font(.subheadline).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .accessibilityIdentifier("SP-04.home.refill")
    }

    private var alertSummaryCard: some View {
        CardSection(title: L10n.homeAlertSummary) {
            ForEach(snapshot.alertSummary) { ref in
                Button {
                    router.navigate(to: .alertHistory)
                } label: {
                    HStack {
                        Image(systemName: "waveform.path.ecg").foregroundStyle(.red)
                        Text(ref.title).font(.subheadline).foregroundStyle(.primary)
                        Spacer()
                        Text(ref.severity).font(.caption).foregroundStyle(.red)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var recentObservationsCard: some View {
        CardSection(title: L10n.homeRecentObs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(snapshot.recentObservations) { obs in
                        Button {
                            router.navigate(to: .observationDetail(obs.id))
                        } label: {
                            VStack(spacing: 4) {
                                // 锁定态缩略图联动（FR11.3）：敏感媒体以锁图标占位
                                Image(systemName: "lock.rectangle.fill")
                                    .font(.title2)
                                    .foregroundStyle(Color("brand-primary", bundle: .main))
                                    .frame(width: 64, height: 48)
                                    .background(RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(.systemGray5)))
                                Text(L10n.observationKindName(forKey: obs.kind))
                                    .font(.caption2)
                                Text(obs.occurredAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // ⑧ 快速拍摄四入口（病历/报告/处方/症状 → 对应类型的资料采集）
    private var quickCaptureCard: some View {
        CardSection(title: L10n.homeQuickCapture) {
            HStack(spacing: 12) {
                QuickCaptureButton(icon: "doc.text.fill", label: L10n.homeCaptureRecord) {
                    router.navigate(to: .scanCapture(.record))
                }
                QuickCaptureButton(icon: "chart.bar.doc.horizontal.fill", label: L10n.homeCaptureReport) {
                    router.navigate(to: .scanCapture(.report))
                }
                QuickCaptureButton(icon: "pills.fill", label: L10n.homeCapturePrescription) {
                    router.navigate(to: .scanCapture(.prescription))
                }
                QuickCaptureButton(icon: "waveform.path.ecg", label: L10n.homeCaptureSymptom) {
                    router.navigate(to: .observationCreate)
                }
            }
        }
        .accessibilityIdentifier("SP-04.home.quickCapture")
    }

    // MARK: - FR18.5 关怀模式四大卡覆写

    private var careModeHome: some View {
        ScrollView {
            VStack(spacing: 20) {
                // FR18.5 极简导航：四大卡（今日服药/续药/拍摄记录/呼救）
                BigCareCard(icon: "pills.fill", title: L10n.homeCareMeds, tint: .blue) {
                    router.navigate(to: .appointmentList)   // Phase 3 换时段确认路由
                }
                BigCareCard(icon: "pills.circle.fill", title: L10n.homeCareRefill, tint: .orange) {
                    router.navigate(to: .medicationCabinet)
                }
                BigCareCard(icon: "camera.fill", title: L10n.homeCareCapture, tint: .green) {
                    router.navigate(to: .observationCreate)
                }
                BigCareCard(icon: "sos", title: L10n.homeCareSOS, tint: .red) {
                    showSOS = true
                }
                // FR19.1：关怀模式首页大卡 [开始语音]（与四大卡并列、互不干扰）
                VoiceSessionLaunchCard()
            }
            .padding(20)
        }
        .accessibilityIdentifier("SP-04.home.careMode")
    }

    // MARK: - 数据加载

    private var headerTitle: String {
        let name = app.members.first(where: { $0.id == app.currentPatientId })?.displayName
            ?? app.owner?.displayName ?? L10n.help_appName
        return L10n.homeGreeting(name)
    }

    private var settingsVoiceEntryVisible: Bool { true }   // Phase 5 接 AppSettingsStore

    private func load() async {
        await reminderStore.refresh(patientId: app.currentPatientId)
        await hub.load(patientId: app.currentPatientId)
        await observationState.load(patientId: app.currentPatientId)
        await app.loadMembers()
        // FR9.6：通知权限关闭时首页常驻提示（可关、次日重现——以 dismiss 态重置实现）
        notifDenied = await reminderStore.notificationDenied
        dismissNotifBanner = false
    }
}

// MARK: - 组件

private struct CardSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(spacing: 0) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        }
    }
}

private struct QuickCaptureButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .frame(width: 56, height: 56)   // 56pt 图标区（ui-ux §5.2）
                    .background(RoundedRectangle(cornerRadius: 14)
                        .fill(Color("brand-primary", bundle: .main).opacity(0.12)))
                    .foregroundStyle(Color("brand-primary", bundle: .main))
                Text(label).font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

private struct GuideTaskCard: View {
    let icon: String
    let title: String
    let done: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : icon)
                    .font(.title3)
                    .foregroundStyle(done ? Color.green : Color("brand-primary", bundle: .main))
                Text(title).font(.subheadline).foregroundStyle(.primary)
                Spacer()
                if done {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SP-04.home.guide.\(title)")
    }
}

/// FR18.5 关怀模式大卡（≥72pt 主高度，FR18.2）
private struct BigCareCard: View {
    let icon: String
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 40))
                    .foregroundStyle(tint)
                    .frame(width: 64, height: 64)
                    .background(RoundedRectangle(cornerRadius: 16).fill(tint.opacity(0.12)))
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }
}

/// FR2.1① 成员切换抽屉（SP-05 切片）：半屏 BottomSheet，当前成员打勾
struct MemberPickerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(app.members) { member in
                Button {
                    app.setCurrentPatient(member.id)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.displayName).font(.body)
                            Text(member.relation).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if member.id == app.currentPatientId {
                            Image(systemName: "checkmark").foregroundStyle(Color("brand-primary", bundle: .main))
                        }
                    }
                }
                .accessibilityIdentifier("SP-05.member.\(member.id.uuidString)")
            }
            .navigationTitle(L10n.homeMemberSwitch)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.member_add) {
                        dismiss()
                        // 添加家人（FR3.7 入口）：去成员管理页
                        router.navigate(to: .memberList)
                    }
                }
            }
        }
    }
}
