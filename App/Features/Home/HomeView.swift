import SwiftUI
import Domain
import Infrastructure
import Perception

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
    /// 后台任务（模型下载）中心（2026-09-16 业主）：进行中即在首页显示进度条目。
    @Environment(ASRInstallCenter.self) private var installCenter
    @State private var showMemberPicker = false
    @State private var showSOS = false
    @State private var showVoicePanel = false
    @State private var notifDenied = false
    /// FR2.1⑦ 首页滑动处置底部条（round2 U2/U3）：撤销（写成功）/ 重试（写失败）双态，
    /// 载荷 id 为动作代次——计时与撤销均以代次判「仍是同一条」。
    @State private var actionToast: HomeActionToast?
    /// 待办卡「继续补全」（leading 动作）：直接打开续确认流，不经详情 sheet。
    @State private var resumingCard: ResumeTarget?
    /// round2 U-N6：Reduce Motion 开启时行移除/底部条不做动画。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private struct ResumeTarget: Identifiable { let id: String }
    private var rowAnimation: Animation? { reduceMotion ? nil : .snappy(duration: 0.22) }
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
    /// 第四条引导（查看健康数据）完成态（第四轮全仓审查修复：原为会话级 @State——
    /// 重启即复现；改持久化，与其余三项「数据驱动完成」同为准持久事实源）。
    /// 2026-09-15 实测修复：卡片落点随 AI 助手退役改为健康 Tab 根，文案同步为
    /// 「查看健康数据」；存储键保持不变（改名会重置老用户的引导完成态）。
    /// 业主裁决 D2（2026-09-18）：`.assistantChat` 路由已随 F12 永久退役删除，
    /// 落点改为 `router.select(.health)` 直切健康 Tab 根。
    @AppStorage("homeGuide4Visited") private var healthGuideVisited = false
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
        items += ReminderHubLoader.alertItems(hub.qualifiedAlertEvents,
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

    // MARK: - FR2.1⑦ 按源滑动处置（round2 U-N1…N6 / U1–U3）

    /// 读侧隐藏判定：键集由 Domain 给出（`NotificationItemKey.hideKeys`），
    /// 用药时段 / 逾期高风险 OCR / 资料完善为空集——任何持久键都不能把它们藏起来
    /// （BR-004 / BR-003）。稍后 = 次日键，日期一变自然重现。
    private func isHidden(_ item: AggregatedReminderItem, now: Date) -> Bool {
        NotificationItemKey.hideKeys(for: item, now: now).contains { notificationState.itemStates[$0] == .archived }
    }

    /// 动作分派：导航类立即执行；写类（用药三动作 / 归档 / 稍后）先落库、成功才动画，
    /// 失败行不动、底部条「操作失败 [重试]」（round2 U2：原实现先动画后写、回调无返回值）。
    private func perform(_ d: ReminderDisposition, on item: AggregatedReminderItem) {
        switch d {
        case .openCabinet:
            router.navigate(to: .medicationCabinet)
        case .viewEvidence, .view:
            open(item)
        case .resumePendingCard:
            resumingCard = ResumeTarget(id: item.id.sourceId)
        case .markTaken, .snoozeDose, .skipDose, .archive, .snoozeUntilTomorrow:
            Task {
                if await write(d, item: item) { return }            // 成功：行/底部条已在 write 内 withAnimation 更新
                withAnimation(rowAnimation) {
                    actionToast = HomeActionToast(title: L10n.homeSwipeFailed,
                                                  kind: .failed(retry: { perform(d, on: item) }))
                }
            }
        }
    }

    /// 写成功才动画。归档/稍后：`persistArchive` 落库 → `applyArchived` 改可观察态（两阶段，
    /// FR14.8）；用药三动作：时段级逐剂写 dose_log（BR-004），`== doses.count` 才算成功，
    /// 部分成功时重试只处理仍未决的剂量（幂等）。
    private func write(_ d: ReminderDisposition, item: AggregatedReminderItem) async -> Bool {
        switch d {
        case .archive, .snoozeUntilTomorrow:
            guard let key = NotificationItemKey.writeKey(for: item, disposition: d, now: Date()) else { return false }
            do { try await notificationState.persistArchive(key) } catch { return false }
            let title = d == .archive ? L10n.homeSwipeArchived(item.title) : L10n.homeSwipeSnoozedTomorrow(item.title)
            withAnimation(rowAnimation) {
                notificationState.applyArchived(key)
                actionToast = HomeActionToast(title: title, kind: .undo(key: key))
            }
            return true
        case .markTaken, .snoozeDose, .skipDose:
            guard let slot = reminderStore.todaySlots.first(where: { $0.id == item.id.sourceId }) else { return false }
            let doses = slot.records.filter { $0.isUnresolved }.map(\.dose)   // Domain 单一出口：nil 或 snoozed 均待处理
            guard !doses.isEmpty else { return false }
            let done: Int
            switch d {
            case .markTaken:
                done = await reminderStore.confirmSlotAllTaken(patientId: app.currentPatientId, doses: doses, careMode: app.careMode)
            case .snoozeDose:
                done = await reminderStore.snoozeSlotPending(patientId: app.currentPatientId, doses: doses, careMode: app.careMode)
            default:
                done = await reminderStore.skipSlotPending(patientId: app.currentPatientId, doses: doses, careMode: app.careMode)
            }
            return done == doses.count
        default:
            return false
        }
    }

    /// 撤销（归档/稍后）：先落库再恢复可观察态；失败换成重试条。代次守卫：
    /// 只有底部条仍是本次动作那一条时才顺带清条，否则只恢复行、不动新条。
    private func undo(_ toast: HomeActionToast, key: String) {
        Task {
            do { try await notificationState.persistUnarchive(key) } catch {
                actionToast = HomeActionToast(title: L10n.homeSwipeFailed,
                                              kind: .failed(retry: { undo(toast, key: key) }))
                return
            }
            guard actionToast?.id == toast.id else {
                withAnimation(rowAnimation) { notificationState.applyUnarchived(key) }
                return
            }
            withAnimation(rowAnimation) {
                notificationState.applyUnarchived(key)
                actionToast = nil
            }
        }
    }

    /// 底部条：撤销 / 重试双态（渲染原子已分解至 HomeActionToastBanner，
    /// 2026-09-26 原子结构轮第三批）。到点回调里仍须核对代次——旧计时器不得清掉
    /// 新条（round2 U3）。
    @ViewBuilder private var actionToastBanner: some View {
        if let toast = actionToast {
            HomeActionToastBanner(
                toast: toast,
                onUndo: { key in undo(toast, key: key) },
                onRetry: {
                    actionToast = nil
                    if case .failed(let retry) = toast.kind { retry() }
                },
                onExpire: {
                    guard actionToast?.id == toast.id else { return }
                    withAnimation(rowAnimation) { actionToast = nil }
                }
            )
        }
    }

    private var currentWindow: AggregationWindow {
        let parts = windowRaw.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 2 else { return .init() }
        return .init(pastDays: parts[0], futureDays: parts[1])
    }

    // MARK: - Body

    var body: some View {
        WithPerceptionTracking {
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
            // FR2.1⑦ 首页滑动处置底部条：撤销（5s）/ 重试（8s）双态，自动隐去以代次判定。
            .overlay(alignment: .bottom) { actionToastBanner }
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
            // FR2.1⑦ 待办卡 leading「继续补全」：直达续确认流；关闭后刷新待办投影
            .sheet(item: $resumingCard, onDismiss: { pendingCenter.refresh(patientId: app.currentPatientId) }) { target in
                NavigationStack { PendingCardResumeRouteView(cardId: target.id) }
                    .environment(pendingCenter)
                    .environment(app)
                    .environment(docs)
                    .environment(router)
            }
            .task(id: "\(app.currentPatientId)-\(dataChange.alertsVersion)-\(docs.pendingVersion)") { await load() }
        }
    }

    // MARK: - 标准布局：统一提醒聚合中心

    /// 非行类内容（横幅/筛选头/空态/引导/免责声明）的行内边距；聚合行用 cardRowInsets。
    private let plainRowInsets = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
    private let cardRowInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)

    /// FR2.1⑦ 原生 `List`（round2 U1/U-N6：自绘 DragGesture 归档行删除——纵滑与横滑
    /// 由系统手势仲裁，滑动按钮自动成为 VoiceOver 自定义动作）。ADR-021 单一自适应视图：
    /// iPad 行宽由 `.frame(maxWidth: 672)` 承担，不做 idiom 分支。
    private var standardHome: some View {
        // 第八轮全仓审查修复的每帧纪律延续：聚合与筛选各只求值一次，
        // 经 let 承接传入子视图（此前 snapshot 每帧重算 13 次的教训）
        let progress = app.profileCompletion
        // 读侧隐藏：键集由 Domain 按源给出（归档基键 + 稍后次日键；用药/逾期 OCR/
        // 资料完善为空集）。过滤只作用于展示快照：load() 的键集取未过滤聚合。
        let now = Date()
        let snap = aggregatedItems(profileCompletion: progress).filter { !isHidden($0, now: now) }
        let items = ReminderAggregationCenter.filtered(snap, kind: filterKind)
        // I7 审查修复：引导优先级是业务规则，下沉 Domain 纯函数
        //（规则 4）；资料完善是首日引导的一部分，单独存在时不能吞掉首日
        // 任务，任何其他真实提醒（尤其置顶项）仍优先进入聚合列表。
        let showsGuide = ReminderAggregationCenter.showsFirstDayGuide(
            items: snap, isNewUser: isNewUser, progressKind: ReminderHubLoader.profileProgressKind)
        return List {
            Group {
                pendingImportRecovery
                pendingLoadFailure
                if showsGuide {
                    if filterKind != nil { filterHeader }
                    if filterKind != nil && items.isEmpty { emptyAggregation }
                } else {
                    if notifDenied && dismissedDay != todayDayKey { notifDeniedBanner }
                    filterHeader
                    if items.isEmpty { emptyAggregation }
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(plainRowInsets)
            aggregationRows(items, profileCompletion: progress)
            Group {
                if showsGuide { newUserGuide }
                // §5.2 免责声明恒显示（V3.72：新用户空态此前不渲染信任文案）
                Text(L10n.homeDisclaimer)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                    .accessibilityIdentifier("SP-04.home.disclaimer")
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(plainRowInsets)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // M1aE2E 约束：首内容 minY − 成员按钮 maxY ≤ 48pt（行 inset 8 + 行内 padding 8，无顶部留白）
            .contentMarginsCompat(.top, 0, for: .scrollContent)
            .listSectionSpacingCompat(.compact)
        .frame(maxWidth: 672)          // §9.1 正文行宽 ≤672pt——靠 frame，不做 idiom 分支（ADR-021）
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
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
                        filterChip(kind, kind.homeFilterLabel, icon: CardKindIcon.spec(aggregation: kind).symbol)
                    }
                }
            }
        }
        .accessibilityIdentifier("SP-04.home.filterHeader")
    }

    private func filterChip(_ kind: AggregationKind?, _ label: String, icon: String) -> some View {
        // 渲染原子已分解至 HomeFilterChip（2026-09-26 原子结构轮第二批）。
        HomeFilterChip(kind: kind, label: label, icon: icon, selected: filterKind == kind) {
            filterKind = kind
        }
    }

    /// FR2.1a 时间窗 Menu（FR14.7 完整档位在设置页期二；首页三档常用预设）。
    private var windowMenu: some View {
        // 渲染原子已分解至 HomeWindowMenu（2026-09-26 原子结构轮第二批）。
        HomeWindowMenu(label: windowLabel) { windowRaw = $0 }
    }

    private var windowLabel: String {
        switch windowRaw {
        case "1,7": return L10n.homeWindowShort
        case "30,30": return L10n.homeWindowLong
        default: return L10n.homeWindowDefault
        }
    }

    // MARK: - 聚合行

    /// 聚合行：按源动作表挂 leading/trailing swipeActions + 长按 contextMenu。
    /// 全滑判定在 Domain（仅纯信息行的 稍后/归档；用药三动作与置顶行禁全滑，BR-004/BR-003）。
    /// 动作表为空的行（资料完善 / 已服或已处置的用药时段）不挂任何滑动或长按菜单。
    @ViewBuilder
    private func aggregationRows(_ items: [AggregatedReminderItem],
                                 profileCompletion: (done: Int, total: Int)?) -> some View {
        // 后台任务进度（2026-09-16 业主）：模型下载进行中时显示——形如档案完善进度卡
        // （图标 + 标题 + 进度条 + 取消），数据源 = App 层安装中心（离开设置页/切后台仍可见）。
        ForEach(installCenter.active) { install in
            modelDownloadCard(install)
                .listRowBackground(Color(.secondarySystemGroupedBackground))
                .listRowInsets(cardRowInsets)
        }
        // 失败终态（2026-09-16 评审）：下载失败在首页可见（此前失败只在设置页
        // 三跳外、首页卡片静默消失）——含 [重试] 与关闭。
        if let failedChoice = installCenter.lastFailure, installCenter.active.isEmpty {
            modelDownloadFailedCard(failedChoice)
                .listRowBackground(Color(.secondarySystemGroupedBackground))
                .listRowInsets(cardRowInsets)
        }
        ForEach(items) { item in
            if item.id.kind == ReminderHubLoader.profileProgressKind, let progress = profileCompletion {
                profileProgressCard(progress)     // 保持 Button + SP-04.home.profileProgress；动作表为空 → 无滑动
                    .listRowBackground(Color(.secondarySystemGroupedBackground))
                    .listRowInsets(cardRowInsets)
            } else if ReminderAggregationCenter.dispositions(for: item).isEmpty {
                aggregationRow(item)
                    .listRowBackground(Color(.secondarySystemGroupedBackground))
                    .listRowInsets(cardRowInsets)
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 46 }
            } else {
                aggregationRow(item)
                    .listRowBackground(Color(.secondarySystemGroupedBackground))
                    .listRowInsets(cardRowInsets)
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 46 }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        dispositionButtons(item, side: .leading)
                    }
                    .swipeActions(edge: .trailing,
                                  allowsFullSwipe: ReminderAggregationCenter.allowsFullSwipe(for: item, side: .trailing)) {
                        dispositionButtons(item, side: .trailing)
                    }
                    .contextMenu { dispositionButtons(item, side: nil) }
            }
        }
    }

    /// side == nil → 全部动作（长按菜单）；List 自动把 swipeActions 暴露为 VoiceOver 自定义动作。
    /// 顺序即 Domain 动作表顺序（trailing 首项 = 全滑候选）。
    @ViewBuilder
    private func dispositionButtons(_ item: AggregatedReminderItem, side: SwipeSide?) -> some View {
        ForEach(ReminderAggregationCenter.dispositions(for: item).filter { side == nil || $0.side == side }, id: \.self) { d in
            Button { perform(d, on: item) } label: { Label(d.title, systemImage: d.systemImage) }
                .tint(d.tint)
                .accessibilityIdentifier("SP-04.home.action.\(d.rawValue)")
        }
    }

    /// FR2.1b/FR17.11：实时资料状态，不伪装成「刚发生」的通知时间。
    private func profileProgressCard(_ progress: (done: Int, total: Int)) -> some View {
        // 渲染原子已分解至 HomeProfileProgressCard（2026-09-26 原子结构轮第二批）。
        HomeProfileProgressCard(progress: progress) {
            router.navigate(to: .voiceGuideProfile)
        }
    }

    /// 后台任务（模型下载）卡片（2026-09-16 业主）——渲染原子已分解至
    /// HomeModelDownloadCard（独立观察域纪律随迁，2026-09-26 原子结构轮第三批）。
    private func modelDownloadCard(_ install: ASRInstallCenter.Install) -> some View {
        HomeModelDownloadCard(install: install) {
            router.navigate(to: .voiceLanguageSettings)
        } onCancel: {
            installCenter.cancel(install.choice)
        }
    }

    /// 后台任务失败卡（2026-09-16 评审）——渲染原子已分解至
    /// HomeModelDownloadFailedCard（2026-09-26 原子结构轮第三批）。
    private func modelDownloadFailedCard(_ choice: VoiceEngineChoice) -> some View {
        HomeModelDownloadFailedCard(choice: choice) { installCenter.dismissFailure() }
    }

    private func aggregationRow(_ item: AggregatedReminderItem) -> some View {
        // 渲染原子已分解至 HomeAggregationRow（2026-09-26 原子结构轮第二批）。
        HomeAggregationRow(item: item) { open(item) }
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
        // 渲染原子已分解至 HomeEmptyAggregation（2026-09-26 原子结构轮第二批）。
        HomeEmptyAggregation(showsReset: filterKind != nil) { filterKind = nil }
    }

    private var newUserGuide: some View {
        // 渲染原子已分解至 HomeNewUserGuide（2026-09-26 原子结构轮第二批）。
        HomeNewUserGuide(
            memberDone: !app.members.isEmpty,
            captureDone: !docs.documents.isEmpty,
            medDone: !reminderStore.todaySlots.isEmpty,
            healthDone: healthGuideVisited,
            onNavigateMembers: { router.navigate(to: .memberList) },
            onQuickCapture: { showQuickCapture = true },
            onNavigateMedForm: { router.navigate(to: .medicationPlanForm(nil)) },
            onVisitHealth: {
                healthGuideVisited = true
                router.select(.health)   // F12 退役：落点 = 健康 Tab 根（原 .assistantChat 弹栈语义已删除）
            }
        )
    }

    private var notifDeniedBanner: some View {
        // 渲染原子已分解至 HomeNotifDeniedBanner（2026-09-26 原子结构轮第二批；
        // 顺带 token-only 修复：硬编码 .orange → semantic-warning）。
        HomeNotifDeniedBanner { dismissedDay = todayDayKey }
    }

    // MARK: - 类别视觉映射（纯呈现）

    // 筛选 chips 文案已迁移为 `AggregationKind.homeFilterLabel`（App/Features/Home/HomeSubviews.swift，
    // 2026-09-26 原子结构轮第二批；单一出口同前）。

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
        // FR14.8 归档状态消费：首页每次装载按未过滤聚合的**读侧隐藏键集**拉取
        // （归档基键 + 稍后次日键，Domain `NotificationItemKey.hideKeys`；键与通知中心
        // 同命名空间）。门面只合并所请求键并带写代次守卫——加载期间的本地写不被陈旧读回滚。
        let now = Date()
        await notificationState.load(keys: aggregatedItems(profileCompletion: nil).flatMap { NotificationItemKey.hideKeys(for: $0, now: now) })
    }
}

// MARK: - 组件

// 原子结构轮第二批/第三批迁移（2026-09-26）：
// - GuideTaskCard / BigCareCard / HomeModelDownloadCard / HomeModelDownloadFailedCard /
//   HomeActionToastBanner → App/Features/Home/HomeSubviews.swift
// - MemberPickerSheet → App/Features/Home/MemberPickerSheet.swift
// - PendingCardDetailSheet → App/Features/Home/PendingCardDetailSheet.swift
