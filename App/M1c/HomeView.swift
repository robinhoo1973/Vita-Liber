import SwiftUI
import Domain
import Infrastructure

/// F2 首页（SP-04 · ui-ux §5.2）：统一提醒聚合中心（FR2.1，V3.57 术语）。
///
/// 布局（FR2.1）：①紧凑成员切换条②顶部快捷工具组（🎤/相机/🔔）
/// ③聚合列表（全部类型提醒时间倒序，统一不再分"行动/观察"子区）
/// ④类别图标过滤 chips ⑤时间窗 Menu（默认过去 7 日/未来 14 日，
/// FR2.1a；@AppStorage 键 actionFeedWindow——tech §5.33 冻结键名）。
///
/// 分级纪律（FR16.2/data-flow §4.4 双流裁决）：alert_event 源按 severity
/// 分流渲染——L0 = 应用内软提示（弱化行+「观察记录」注记，绝不弹通知）；
/// L1+ = 证据卡入口（级别徽章+置顶，点击 SP-30 五段证据卡）。每笔导入
/// 读数不是卡片：小时聚合只进趋势。聚合中心不做生成式解释（ADR-010）。
///
/// 置顶纪律（FR2.1a）：L1+/高风险 OCR（逾期 D 级）不受窗口与筛选约束，
/// priority≥2 恒置顶。数据全部来自环境仓当前成员投影（BR-001）。
/// 关怀模式开启后本页被 FR18.5 四大卡版式覆写（同 ADR-021 单视图双态）。
struct HomeView: View {
    @Environment(AppState.self) private var app
    @Environment(ReminderStore.self) private var reminderStore
    @Environment(M2HubStore.self) private var hub
    @Environment(ObservationStoreState.self) private var observationState
    @Environment(PendingCardCenterState.self) private var pendingCenter
    @Environment(AppRouter.self) private var router
    @Environment(AppSettingsStore.self) private var settingsStore
    @Environment(DocumentsState.self) private var docs
    @Environment(AppDataChangeCenter.self) private var dataChange
    @Environment(NotificationCenterState.self) private var notificationState
    @State private var showMemberPicker = false
    @State private var showSOS = false
    @State private var showVoicePanel = false
    @State private var notifDenied = false
    /// FR9.6「可关、次日重现」：持久化当日驳回标记——旧实现为会话级 @State
    /// 且 load() 每次无条件重置，成员切换/数据版本变化即横幅复活，
    /// 「关到次日」落空。按自然日判定，重启同日亦不复现。
    @AppStorage("notifDeniedBannerDismissedDay") private var dismissedDay = ""

    private var todayDayKey: String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        guard let y = comps.year, let m = comps.month, let d = comps.day else { return "" }
        return "\(y)-\(m)-\(d)"
    }
    /// FR2.1a 时间窗（AppSettingsStore 持久化键 actionFeedWindow 冻结不改，
    /// tech §5.33 存储契约）："过去日,未来日"；默认 7,14。
    @AppStorage("actionFeedWindow") private var windowRaw = "7,14"
    /// FR2.1④ 类别图标过滤（纯 View 参数，V3.87 契约：不调用写接口）。
    @State private var filterKind: AggregationKind?
    /// 「了解 AI」引导任务完成态（第四轮全仓审查修复：原为会话级 @State——
    /// 重启即复现；改持久化，与其余三项「数据驱动完成」同为准持久事实源）
    @AppStorage("homeGuide4Visited") private var aiGuideVisited = false
    /// 快速拍摄以 sheet 呈现（TestFlight 实测修复：navigate 会改导航上下文）。
    /// FR5.1/FR5.5 V3.61：📷 单击直接拍摄，不前置选类型——识别后由理解层判定
    @State private var showQuickCapture = false
    /// FR6.9 待办卡详情 sheet 选择项
    @State private var selectedPendingCard: AggregatedReminderItem?

    // MARK: - 聚合装配（每帧只算一次，body 内 let 承接）

    /// 各源仓投影 → 唯一聚合出口（Domain 纯函数）：
    /// 去重/成员隔离/窗口/置顶/周期压缩/排序全部在 Domain。
    private func aggregatedItems(profileCompletion: (done: Int, total: Int)?) -> [AggregatedReminderItem] {
        var items: [AggregatedReminderItem] = []
        items += ReminderHubLoader.doseItems(reminderStore.todaySlots,
                                             memberId: app.currentPatientId)
        items += ReminderHubLoader.appointmentItems(reminderStore.upcomingAppointments,
                                                    memberId: app.currentPatientId)
        items += ReminderHubLoader.inventoryItems(
            // 审查修复（BR-001 切换窗口）：hub 各节异步提交完成前
            // inventoryItems 仍是旧成员数据——此前直接以新成员身份投影，
            // A 的续药/补录待办在切换瞬间渲染为 B 的提醒。loadedPatientId
            // 与当前成员一致（全部节已提交）才允许取用缓存。
            hub.loadedPatientId == app.currentPatientId ? hub.inventoryItems : [],
            memberId: app.currentPatientId)
        items += ReminderHubLoader.alertItems(hub.qualifiedAlertEvents.filter {
            notificationState.itemStates["alert-\($0.id)"] != .archived
        },
                                              memberId: app.currentPatientId)
        items += ReminderHubLoader.ocrItems(docs.documents,
                                            memberId: app.currentPatientId)
        items += pendingCenter.items
        if let progress = profileCompletion {
            items += ReminderHubLoader.systemItems(done: progress.done, total: progress.total,
                                                    memberId: app.currentPatientId)
        }
        return ReminderAggregationCenter.aggregate(items, window: currentWindow,
                                                   memberId: app.currentPatientId)
    }

    private var currentWindow: AggregationWindow {
        let parts = windowRaw.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 2 else { return .init() }
        return .init(pastDays: parts[0], futureDays: parts[1])
    }

    // MARK: - Body

    var body: some View {
        Group {
            if app.careMode {
                careModeHome   // FR18.5 四大卡版式覆写
            } else {
                standardHome
            }
        }
        .navigationTitle(headerTitle)
        // principal 只替换标题内容，不约束自动继承的大标题高度（SP-04）。
        // 明确使用紧凑导航栏，内容为空时也不预留第二层标题区。
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // §5.2 首页成员切换入口：紧凑标题可点击 → 成员抽屉
            ToolbarItem(placement: .principal) {
                Button {
                    showMemberPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Text(headerTitle).font(.headline)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }
                .accessibilityIdentifier("SP-04.home.memberSwitch")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                // FR17.9 全局语音入口（FR14.7 voiceEntryVisible 可隐藏）→ 语音速记面板 SP-55
                if settingsVoiceEntryVisible {
                    Button {
                        showVoicePanel = true
                    } label: {
                        Image(systemName: "mic.fill")
                    }
                    .accessibilityLabel(L10n.homeVoice)
                    .accessibilityIdentifier("SP-04.home.mic")
                }
                // FR2.1② 相机 OCR/资料识别入口（V3.61 单入口）：单击直接进采集页，
                // 文档类型在识别后由共享理解层判定（FR5.5/FR6.2/ADR-029 不前置指定）；
                // 症状录入走语音面板意图与记录页观察创建，不再挂在相机图标下
                Button {
                    showQuickCapture = true
                } label: {
                    Image(systemName: "camera.fill")
                }
                .accessibilityLabel(L10n.homeQuickCapture)
                .accessibilityIdentifier("SP-04.home.capture")
                // FR14.8 通知中心铃铛（未读角标不显示病名药名，§5 通知隐私）
                NavigationLink(value: AppRoute.notificationCenter) {
                    Image(systemName: "bell")
                }
                .accessibilityLabel(L10n.notificationCenterTitle)
                .accessibilityIdentifier("SP-04.home.bell")
                .badge(reminderStore.pendingCount > 0 ? reminderStore.pendingCount : 0)
            }
        }
        .sheet(isPresented: $showMemberPicker) {
            MemberPickerSheet()
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showSOS) { SOSHelpView() }
        // SP-55 全屏工作台
        .fullScreenCover(isPresented: $showVoicePanel) { VoiceQuickLaunchView() }
        .sheet(isPresented: $showQuickCapture) {
            NavigationStack { QuickCaptureView(kind: nil) }
        }
        .sheet(item: $selectedPendingCard) { item in
            NavigationStack { PendingCardDetailSheet(item: item) }
                .environment(pendingCenter)
                .environment(app)
                .environment(docs)
                .environment(router)
        }
        .task(id: "\(app.currentPatientId)-\(dataChange.alertsVersion)-\(docs.pendingVersion)") { await load() }
    }

    // MARK: - 标准布局：统一提醒聚合中心

    private var standardHome: some View {
        // 第八轮全仓审查修复的每帧纪律延续：聚合与筛选各只求值一次，
        // 经 let 承接传入子视图（此前 snapshot 每帧重算 13 次的教训）
        let progress = app.profileCompletion
        let snap = aggregatedItems(profileCompletion: progress)
        let items = ReminderAggregationCenter.filtered(snap, kind: filterKind)
        // 资料完善是首日引导的一部分；单独存在时不能吞掉首日任务。
        // 任何其他真实提醒（尤其置顶项）仍优先进入聚合列表。
        let showsGuide = isNewUser && snap.allSatisfy { $0.id.kind == ReminderHubLoader.profileProgressKind }
        return ScrollView {
            VStack(spacing: 16) {
                pendingImportRecovery
                pendingLoadFailure
                if showsGuide {
                    if filterKind != nil {
                        filterHeader
                        if items.isEmpty { emptyAggregation }
                    }
                    aggregationList(items, profileCompletion: progress)
                    newUserGuide
                } else {
                    if notifDenied && dismissedDay != todayDayKey {
                        notifDeniedBanner
                    }
                    filterHeader
                    if items.isEmpty {
                        emptyAggregation
                    } else {
                        aggregationList(items, profileCompletion: progress)
                    }
                }
                // §5.2 免责声明恒显示（V3.72：新用户空态此前不渲染信任文案）
                Text(L10n.homeDisclaimer)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                    .accessibilityIdentifier("SP-04.home.disclaimer")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 672)   // §9.1 正文行宽 ≤672pt（iPad 常宽列可读性）
        }
        .accessibilityIdentifier("SP-04.home.aggregation")
    }

    /// 筛选区：标题 + 时间窗 Menu + 类别图标 chips（FR2.1④/⑤）。
    private var filterHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.homeAggregationTitle).font(.headline)
                Spacer()
                windowMenu
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(nil, L10n.homeFilterAll, icon: "square.grid.2x2")
                    ForEach(AggregationKind.allCases, id: \.self) { kind in
                        filterChip(kind, kindLabel(kind), icon: kindIcon(kind))
                    }
                }
            }
        }
        .accessibilityIdentifier("SP-04.home.filterHeader")
    }

    private func filterChip(_ kind: AggregationKind?, _ label: String, icon: String) -> some View {
        let selected = filterKind == kind
        return Button {
            filterKind = kind
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption)
                Text(label).font(.caption)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(selected
                                       ? Color("brand-primary", bundle: .main)
                                       : Color(.systemGray6)))
            .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SP-04.home.chip.\(kind?.rawValue ?? "all")")
    }

    /// FR2.1a 时间窗 Menu（FR14.7 完整档位在设置页期二；首页三档常用预设）。
    private var windowMenu: some View {
        Menu {
            Button(L10n.homeWindowDefault) { windowRaw = "7,14" }
            Button(L10n.homeWindowShort) { windowRaw = "1,7" }
            Button(L10n.homeWindowLong) { windowRaw = "30,30" }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                Text(windowLabel).font(.caption)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color(.systemGray6)))
            .foregroundStyle(Color.primary)
        }
        .accessibilityIdentifier("SP-04.home.windowMenu")
    }

    private var windowLabel: String {
        switch windowRaw {
        case "1,7": return L10n.homeWindowShort
        case "30,30": return L10n.homeWindowLong
        default: return L10n.homeWindowDefault
        }
    }

    // MARK: - 聚合行

    /// 空数据时整个容器不存在，padding/背景均不能留下空卡（SP-04）。
    @ViewBuilder
    private func aggregationList(_ items: [AggregatedReminderItem],
                                 profileCompletion: (done: Int, total: Int)?) -> some View {
        if !items.isEmpty {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    if item.id.kind == ReminderHubLoader.profileProgressKind, let progress = profileCompletion {
                        profileProgressCard(progress)
                    } else {
                        aggregationRow(item)
                    }
                    if item.id != items.last?.id {
                        Divider().padding(.leading, 46)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemGroupedBackground)))
        }
    }

    /// FR2.1b/FR17.11：实时资料状态，不伪装成「刚发生」的通知时间。
    private func profileProgressCard(_ progress: (done: Int, total: Int)) -> some View {
        Button {
            router.navigate(to: .voiceGuideProfile)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.text.rectangle")
                    .font(.title3)
                    .foregroundStyle(Color("brand-primary", bundle: .main))
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(L10n.homeProfileProgressTitle)
                            .font(.subheadline.bold()).foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text(L10n.homeProfileContinue)
                            .font(.caption).foregroundStyle(Color("brand-primary", bundle: .main))
                    }
                    Text(L10n.homeProfileProgressFmt(progress.done, progress.total))
                        .font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                        .tint(Color("brand-primary", bundle: .main))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.homeProfileProgressTitle)
        .accessibilityValue(L10n.homeProfileProgressFmt(progress.done, progress.total))
        .accessibilityHint(L10n.homeProfileContinue)
        .accessibilityIdentifier("SP-04.home.profileProgress")
    }

    private func aggregationRow(_ item: AggregatedReminderItem) -> some View {
        Button {
            open(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: kindIcon(item.aggregationKind))
                    .font(.title3)
                    .foregroundStyle(kindTint(item.aggregationKind))
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(kindTint(item.aggregationKind).opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.subheadline).foregroundStyle(.primary)
                            .lineLimit(1)
                        if let status = item.status, status != "L0" {
                            // FR16.2 证据卡入口：级别徽章（L1+ 才渲染）
                            Text(status)
                                .font(.caption2.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color("semantic-danger", bundle: .main)))
                        }
                    }
                    HStack(spacing: 6) {
                        Text(item.occurredAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        if item.status == "L0" {
                            // FR16.2 软提示注记：L0 是观察记录，不是警报
                            Text(L10n.homeL0Note)
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        if let remaining = item.remainingCount, remaining > 0 {
                            Text(L10n.homeRemainingFmt(remaining))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(Color("semantic-danger", bundle: .main))
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SP-04.home.row.\(item.id.sourceId)")
    }

    /// FR2.2 点击直达：待办卡开详情 sheet；其余按稳定 routeKey 跳转。
    private func open(_ item: AggregatedReminderItem) {
        switch item.aggregationKind {
        case .pendingCard:
            selectedPendingCard = item
        default:
            if let route = route(for: item) {
                router.navigate(to: route)
            }
        }
    }

    /// routeKey（Domain 稳定键，V3.97 契约）→ AppRoute。
    private func route(for item: AggregatedReminderItem) -> AppRoute? {
        switch item.routeKey {
        case "reminderToday": return .reminderToday
        case "appointmentList": return .appointmentList
        case "medicationCabinet": return .medicationCabinet
        case "pendingOcrQueue": return .pendingOcrQueue
        case "pendingCardDetail": return .pendingCard(item.id.sourceId)
        case "alertHistory": return .alertHistory
        case "alertEvidence":
            guard let id = UUID(uuidString: item.id.sourceId), let patient = item.patientID,
                  let severity = item.status.flatMap(AlertSeverity.init(rawValue:)) else { return nil }
            return .alertEvidence(patientId: patient, eventId: id, severity: severity)
        case "voiceGuideProfile": return .voiceGuideProfile
        default: return nil
        }
    }

    // MARK: - 空态

    /// 新用户空态：三条引导任务（V3.39 首日引导由本卡承载）
    private var isNewUser: Bool {
        reminderStore.todaySlots.isEmpty && docs.documents.isEmpty
            && observationState.groups.isEmpty && pendingCenter.items.isEmpty
    }

    /// FR2.1c 筛选空态：当前窗口/类别无结果 ≠ 全局无数据（不得误报
    /// 「没有提醒」）；筛选激活时给「一键回到全部」。
    private var emptyAggregation: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle).foregroundStyle(.tertiary)
            Text(L10n.homeEmptyFilter)
                .font(.subheadline).foregroundStyle(.secondary)
            if filterKind != nil {
                Button(L10n.homeEmptyReset) { filterKind = nil }
                    .font(.subheadline)
                    .foregroundStyle(Color("brand-primary", bundle: .main))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityIdentifier("SP-04.home.emptyAggregation")
    }

    private var newUserGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            GuideTaskCard(icon: "person.crop.circle.badge.plus", title: L10n.homeGuide1, done: !app.members.isEmpty) {
                router.navigate(to: .memberList)
            }
            GuideTaskCard(icon: "camera.fill", title: L10n.homeGuide2, done: !docs.documents.isEmpty) {
                showQuickCapture = true
            }
            GuideTaskCard(icon: "bell.badge.fill", title: L10n.homeGuide3, done: !reminderStore.todaySlots.isEmpty) {
                router.navigate(to: .medicationPlanForm(nil))
            }
            GuideTaskCard(icon: "sparkles", title: L10n.homeGuide4, done: aiGuideVisited) {
                aiGuideVisited = true
                router.navigate(to: .assistantChat)
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
                dismissedDay = todayDayKey
            } label: {
                // 审查修复：触控目标 ≥44pt（原 ~16pt 图标，关怀模式要求 64pt）
                Image(systemName: "xmark").font(.footnote).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.commonCancel)
            .accessibilityIdentifier("SP-04.home.notifDenied.dismiss")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
        .accessibilityIdentifier("SP-04.home.notifDenied")
    }

    // MARK: - 类别视觉映射（纯呈现）

    private func kindIcon(_ kind: AggregationKind) -> String {
        switch kind {
        case .medication: return "pills.fill"
        case .appointment: return "stethoscope"
        case .document: return "doc.text.fill"
        case .ocr: return "exclamationmark.triangle.fill"
        case .alert: return "waveform.path.ecg"
        case .pendingCard: return "clock.badge.checkmark"
        case .family: return "person.2.fill"
        case .sos: return "sos"
        case .system: return "gearshape.fill"
        }
    }

    private func kindTint(_ kind: AggregationKind) -> Color {
        switch kind {
        case .medication: return .blue
        case .appointment: return .teal
        case .document: return .indigo
        case .ocr: return .yellow
        case .alert: return .red
        case .pendingCard: return .orange
        case .family: return .green
        case .sos: return .red
        case .system: return .gray
        }
    }

    private func kindLabel(_ kind: AggregationKind) -> String {
        switch kind {
        case .medication: return L10n.homeFilterMedication
        case .appointment: return L10n.homeFilterAppointment
        case .document: return L10n.homeFilterDocument
        case .ocr: return L10n.homeFilterOcr
        case .alert: return L10n.homeFilterAlert
        case .pendingCard: return L10n.homeFilterPending
        case .family: return L10n.homeFilterFamily
        case .sos: return L10n.homeFilterSOS
        case .system: return L10n.homeFilterSystem
        }
    }

    // MARK: - FR18.5 关怀模式四大卡覆写

    private var careModeHome: some View {
        ScrollView {
            VStack(spacing: 20) {
                pendingImportRecovery
                pendingLoadFailure
                // FR18.5 极简导航：四大卡（今日服药/续药/拍摄记录/呼救）
                BigCareCard(icon: "pills.fill", title: L10n.homeCareMeds, tint: .blue) {
                    router.navigate(to: .reminderToday)
                }
                BigCareCard(icon: "pills.circle.fill", title: L10n.homeCareRefill, tint: .orange) {
                    router.navigate(to: .medicationCabinet)
                }
                BigCareCard(icon: "camera.fill", title: L10n.homeCareCapture, tint: .green) {
                    router.navigate(to: .scanCapture(nil))
                }
                // 评审修正 U7：§7.1 防误触——SOS 大卡按住 600ms 才进入
                BigCareCard(icon: "sos", title: L10n.homeCareSOS, tint: .red) {
                    // 常规点击被下面手势接管后 Button action 不再触发；
                    // 保留 action 仅为 accessibilityAction 兜底
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: HoldToConfirm.requiredSeconds(mode: .care))
                        .onEnded { _ in showSOS = true }
                )
                .accessibilityAction { showSOS = true }
                // FR19.1：关怀模式首页大卡 [开始语音]
                VoiceSessionLaunchCard()
            }
            .padding(20)
        }
        .accessibilityIdentifier("SP-04.home.careMode")
    }

    // MARK: - 数据加载

    @ViewBuilder private var pendingImportRecovery: some View {
        if let session = docs.activeImport {
            Button { showQuickCapture = true } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.pendingCardResume, systemImage: "doc.text.viewfinder")
                    Text(app.members.first { $0.id == session.patientId }?.displayName ?? session.patientId.uuidString)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("OCR.home.resumeImport")
        } else if !docs.queuedImports.isEmpty {
            Button(L10n.pendingCardResume) { router.navigate(to: .documentList) }
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var pendingLoadFailure: some View {
        if pendingCenter.loadError != nil {
            HStack {
                Label(L10n.docImportFailed, systemImage: "exclamationmark.triangle")
                Spacer()
                Button(L10n.retry) { Task { await pendingCenter.load(patientId: app.currentPatientId) } }
                    .frame(minHeight: 44)
            }
            .font(.footnote)
        }
    }

    private var headerTitle: String {
        let name = app.members.first(where: { $0.id == app.currentPatientId })?.displayName
            ?? app.owner?.displayName ?? L10n.help_appName
        return L10n.homeGreeting(name)
    }

    /// FR14.7 语音入口显示开关（审查修复：原硬编码 true——设置页开关零效果）
    private var settingsVoiceEntryVisible: Bool {
        settingsStore.values[.voiceEntryVisible] != "false"
    }

    private func load() async {
        // 六个相互独立的仓并发加载（第四轮全仓审查效率修复）
        async let r: Void = reminderStore.refreshTriggered(patientId: app.currentPatientId)
        async let h: Void = hub.load(patientId: app.currentPatientId)
        async let o: Void = observationState.load(patientId: app.currentPatientId)
        async let d: Void = docs.load(patientId: app.currentPatientId)
        async let p: Void = pendingCenter.load(patientId: app.currentPatientId)
        async let m: Void = app.loadMembers()
        _ = await (r, h, o, d, p, m)
        // FR9.6：通知权限关闭时首页常驻提示（可关、次日重现——
        // 驳回状态为持久化自然日标记，见 dismissedDay/todayDayKey）
        notifDenied = await reminderStore.notificationDenied
        // FR14.8 归档状态消费：首页证据卡过滤依赖 itemStates，此前只在通知
        // 中心加载——重启后用户已归档的 L1+ 预警证据卡被重新置顶（归档
        // 持久化形同虚设）。首页每次装载先按当前预警集拉取归档状态。
        await notificationState.load(keys: hub.qualifiedAlertEvents.map { "alert-\($0.id)" })
    }
}

// MARK: - 组件

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
                    .font(VLFont.homeActionIcon)
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
                            Text(L10n.memberRelationDisplayName(member.relation))
                                .font(.caption).foregroundStyle(.secondary)
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

/// Pending detail owns its lookup; another route cannot replace its action target.
private struct PendingCardDetailSheet: View {
    let item: AggregatedReminderItem
    @Environment(PendingCardCenterState.self) private var pendingCenter
    @Environment(DocumentsState.self) private var docs
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var resuming = false
    @State private var showDiscard = false
    @State private var showSource = false
    @State private var detail: PendingCard?
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var discardFailed = false
    @State private var discarding = false

    var body: some View {
        List {
            if let detail {
                Section {
                    OCRReviewOwnerRow(patientId: detail.patientId)
                    GradeBadge(grade: "D")
                }
                if !detail.incompleteFields.isEmpty {
                    Section(L10n.docConfirmSkipTitle) {
                        ForEach(Array(detail.incompleteFields.enumerated()), id: \.offset) { _, field in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(field.label ?? DocumentsState.fieldLabel(forKey: field.key))
                                    .font(.subheadline)
                                Text(L10n.docConfirmHint).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !detail.partialData.shared.isEmpty || !detail.partialData.rows.isEmpty {
                    Section(L10n.docConfirmSkipSaved) {
                        if let snapshot = detail.partialData.card {
                            ForEach(snapshot.shared.indices.filter { snapshot.shared[$0].key != "metric_key" }, id: \.self) { index in
                                pendingField(snapshot.shared[index])
                            }
                            ForEach(Array(snapshot.rows.enumerated()), id: \.element.id) { index, row in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L10n.entityCardRowIndex(index + 1)).font(.caption)
                                    ForEach(row.fields.indices.filter { row.fields[$0].key != "metric_key" }, id: \.self) { field in
                                        pendingField(row.fields[field])
                                    }
                                }
                            }
                        } else {
                            ForEach(detail.partialData.shared.filter { $0.key != "metric_key" }.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                LabeledContent(DocumentsState.fieldLabel(forKey: key), value: value)
                            }
                            ForEach(Array(detail.partialData.rows.enumerated()), id: \.offset) { index, row in
                                VStack(alignment: .leading) {
                                    Text(L10n.entityCardRowIndex(index + 1)).font(.caption)
                                    ForEach(row.filter { $0.key != "metric_key" }.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                        LabeledContent(DocumentsState.fieldLabel(forKey: key), value: value)
                                    }
                                }
                            }
                        }
                    }
                }
                if !detail.rawText.isEmpty {
                    Section {
                        Text(detail.rawText).font(.footnote)
                    } header: {
                        Text(L10n.pendingCardRawText)
                    }
                }
            } else if loadFailed {
                Label(L10n.docImportFailed, systemImage: "exclamationmark.triangle")
                Button(L10n.retry) { Task { await loadDetail() } }
            } else if loaded {
                Text(L10n.pendingCardNotFound)
            } else { ProgressView() }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: item.id.sourceId) {
            await loadDetail()
        }
        .safeAreaInset(edge: .bottom) {
            if let detail {
                VStack(spacing: 8) {
                    Button {
                        resuming = true
                    } label: {
                        Label(L10n.pendingCardResume, systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("SP-04.home.pendingCard.resume")
                    HStack(spacing: 12) {
                        Button {
                            showSource = true
                        } label: {
                            Label(L10n.pendingCardViewSource, systemImage: "doc.text.magnifyingglass")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(detail.sourceDocId == nil || detail.sourcePage == nil)
                        .accessibilityIdentifier("SP-04.home.pendingCard.viewSource")
                        Button(role: .destructive) {
                            showDiscard = true
                        } label: {
                            Label(L10n.pendingCardDiscard, systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(docs.retainedImport(for: detail) != nil)
                        .accessibilityIdentifier("SP-04.home.pendingCard.discard")
                    }
                }
                .padding(16)
                .background(.bar)
                .disabled(discarding)
            }
        }
        .sheet(isPresented: $resuming, onDismiss: {
            pendingCenter.refresh(patientId: app.currentPatientId)
            Task {
                await loadDetail()
                if detail?.status == "resolved" { dismiss() }
            }
        }) {
            NavigationStack { PendingCardResumeRouteView(cardId: item.id.sourceId) }
        }
        .sheet(isPresented: $showSource) {
            if let detail, let documentID = detail.sourceDocId, let page = detail.sourcePage {
                DocumentSourcePageView(documentId: documentID, patientId: detail.patientId, pageIndex: page)
            }
        }
        .confirmationDialog(L10n.pendingCardDiscard, isPresented: $showDiscard, titleVisibility: .visible) {
            Button(L10n.pendingCardDiscard, role: .destructive) {
                guard let detail else { return }
                discarding = true
                Task {
                    let discarded = await docs.discardPendingCard(detail)
                    discarding = false
                    pendingCenter.refresh(patientId: app.currentPatientId)
                    if discarded { dismiss() } else { discardFailed = true }
                }
            }
            Button(L10n.commonCancel, role: .cancel) {}
        }
        .alert(L10n.docConfirmSaveFailedTitle, isPresented: $discardFailed) {
            Button(L10n.onboard_gotIt, role: .cancel) {}
        } message: { Text(detail.flatMap { docs.pendingReviews[$0.id]?.notificationError } ?? L10n.entityCardSaveFailed) }
        .interactiveDismissDisabled(discarding)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.onboard_gotIt) {
                    dismiss()
                }
                .disabled(discarding)
                .accessibilityIdentifier("SP-04.home.pendingCard.close")
            }
        }
    }

    private func loadDetail() async {
        loaded = false; loadFailed = false
        do {
            let fetched = try await docs.loadPendingCard(id: item.id.sourceId)
            guard !Task.isCancelled else { return }
            detail = fetched
        } catch { loadFailed = true; detail = nil }
        loaded = true
    }

    private func pendingField(_ field: FieldDraft) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(DocumentsState.fieldLabel(forKey: field.key)).font(.caption).foregroundStyle(.secondary)
            Text(field.value).strikethrough(field.grade == .rejected)
        }
    }
}
