import SwiftUI
import Domain
import Infrastructure
import Perception

// MARK: - F11 健康时间轴（SP-19 · FR11.1-11.4）

/// 时间轴状态仓：主卡/子卡分页查询（v27 `hubPage`）+ 筛选 + 展开记忆 + 健康问题（BR-001 成员隔离）
@MainActor
@Perceptible
final class TimelineViewState {
    /// v27（子项目 J · round1 §E.3）：主卡 + 无枢纽叶子的游标分页累积（`hubPage` 逐页追加、按 id 去重）。
    private(set) var hubs: [TimelineHubEntry] = []
    private(set) var nextCursor: TimelineCursor?
    private(set) var isLoadingMore = false
    private(set) var loadMoreFailed = false
    private(set) var filter: TimelineFilter = .all
    private(set) var problems: [HealthProblemStore.HealthProblemRow] = []
    /// SP-19 展开记忆（UserDefaults，按主卡 id）；筛选态的展开/收起只落 `transientExpansion`（不写记忆）。
    let expansion: TimelineExpansionStore
    private var transientExpansion: [String: Bool] = [:]
    private let store: TimelineQueryStore
    private let problemStore: HealthProblemStore
    private var loadingPatientId: UUID?
    /// 在途请求的筛选身份（审查修复，与 loadingPatientId 同款守卫）：快速连点
    /// 筛选 chip 会并发跑两个 load——旧查询先发的可能后到，最后落库者覆盖
    /// `hubs`，使列表显示旧筛选的行集而 chip 已是新筛选（无守卫则永久错配，
    /// 直到再次点 chip 或数据变更）。
    private var loadingFilter: TimelineFilter?
    /// BR-001 消费侧守卫（2026-09-15 实测修复）：已渲染列表的成员身份。此前只在成功
    /// 路径写列表，失败/取消时**上一个成员**的 hubs/entries 继续渲染，而表头与行内导航
    /// 已按新成员解析（跨成员显示 + 跨成员打开）。与 `RecordsHubStore.loadedPatientId`
    /// 同款守卫。
    private var loadedPatientId: UUID?
    static let pageSize = 30

    /// expansion 默认 nil：默认实参在调用方隔离域求值（State(initialValue:) 的
    /// autoclosure 非隔离），MainActor 初始化器不能作默认实参（Swift 6 严格并发，
    /// macOS CI 实证）——移入 init 体（本类型 @MainActor）构造。
    init(store: TimelineQueryStore, problemStore: HealthProblemStore, expansion: TimelineExpansionStore? = nil) {
        self.store = store
        self.problemStore = problemStore
        self.expansion = expansion ?? TimelineExpansionStore()
    }

    func load(patientId: UUID) async {
        // BR-001 成员隔离（2026-09-15 实测修复）：**换成员立即清屏**——失败或取消时
        // 旧成员的条目不得在新成员身份下继续渲染（表头/成员切换器已是新成员，行内导航
        // 携带的 `entry.memberId` 却是旧成员 = 跨成员打开）。同一成员的重载（筛选变更 /
        // 保存后刷新 / 归档）不清屏，失败仍保留旧列表（原 doctrine 只对同成员成立）。
        if loadedPatientId != patientId {
            loadedPatientId = patientId
            hubs = []
            problems = []
            nextCursor = nil
            loadMoreFailed = false
            transientExpansion = [:]
        }
        loadingPatientId = patientId
        loadingFilter = filter
        do {
            // 2026-09-15 审查修复（效率/简化）：删去并行的平铺投影查询 `entries(for:limit:100)`——
            // 视图只渲染 `visibleHubs`，该投影自空态判据改为只看 visible 后已无任何读者
            // （旧注释称「保留供搜索/健康问题页复用」，实际搜索走 FTS、问题页走 problems），
            // 却让本页每次加载（首屏/切筛选/切成员/保存文档）都多跑一条九分支 UNION ALL。
            async let hubPage = store.hubPage(patientId: patientId, filter: filter, limit: Self.pageSize)
            async let probs = problemStore.list(patientId: patientId)
            let (h, pr) = try await (hubPage, probs)
            guard loadingPatientId == patientId, loadingFilter == filter else { return }
            hubs = h.entries
            nextCursor = h.nextCursor
            loadMoreFailed = false
            transientExpansion = [:]
            problems = pr
        } catch {
            // 同一成员：读取失败保留旧列表（EncountersState/DocumentsState 同款
            // doctrine）——置空会把存在记录渲染成「暂无记录」假空态。换成员时上面
            // 已清屏，此处不得把旧成员列表放回。
        }
    }

    /// 游标翻页（末行 onAppear 触发；替代旧「取 100 条即止」）：同成员、有游标、未在加载中才取下一页；追加去重。
    func loadMore(patientId: UUID) async {
        guard loadingPatientId == patientId, let cursor = nextCursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await store.hubPage(patientId: patientId, filter: filter, cursor: cursor, limit: Self.pageSize)
            guard loadingPatientId == patientId, nextCursor == cursor else { return }
            let known = Set(hubs.map(\.id))
            hubs += page.entries.filter { !known.contains($0.id) }
            nextCursor = page.nextCursor
            loadMoreFailed = false
        } catch {
            loadMoreFailed = true
        }
    }

    /// 筛选后的可见主卡/叶子（Domain `visible`：主卡类型命中整卡保留，否则只留命中子卡；叶子按自身类型）。
    var visibleHubs: [TimelineHubEntry] {
        TimelineHierarchyRules.visible(hubs, filter: filter)
    }

    /// 展开集：Domain 默认（业主 2026-09-17 定：无筛选 = 记忆 ?? **全部折叠**——主卡默认收起、
    /// 不显示关联子卡；筛选 = 命中主卡全展开）+ 筛选态的瞬态覆盖。
    /// 读 `expansion.version` 参与感知：写记忆后本集合重算。
    var expandedIds: Set<String> {
        _ = expansion.version
        var result = TimelineHierarchyRules.expanded(visibleHubs, filter: filter, remembered: expansion.remembered)
        if case .kinds = filter {
            for (id, open) in transientExpansion {
                if open { result.insert(id) } else { result.remove(id) }
            }
        }
        return result
    }

    func isExpanded(_ id: String) -> Bool { expandedIds.contains(id) }

    /// 用户展开/收起：无筛选 → 写记忆（下次打开沿用）；筛选态 → 仅瞬态（不写记忆，round1 §E.3）。
    func setExpanded(_ id: String, _ open: Bool) {
        if case .kinds = filter {
            transientExpansion[id] = open   // 感知属性：写入即令 expandedIds 重算
            return
        }
        expansion.set(id, expanded: open)
    }

    func setFilter(_ kinds: Set<TimelineEntryKind>?) {
        filter = kinds.map { TimelineFilter.kinds($0) } ?? .all
        transientExpansion = [:]
    }

    /// 返回是否写入成功——调用侧据此决定 dismiss 或呈现错误
    @discardableResult
    func createProblem(patientId: UUID, name: String) async -> Bool {
        do {
            _ = try await problemStore.create(patientId: patientId, name: name)
            await load(patientId: patientId)
            return true
        } catch {
            // 错误经调用侧呈现；UI 保留输入可重试
            return false
        }
    }

    func setArchived(problemId: UUID, archived: Bool) async {
        do {
            try await problemStore.setArchived(id: problemId, archived: archived)
            if let patientId = loadingPatientId { await load(patientId: patientId) }
        } catch {
            // 同上
        }
    }

    /// FR11.4 合并：主问题保留、被合并问题归档（各自历史不丢）
    func mergeProblems(primary: UUID, secondary: UUID) async {
        do {
            try await problemStore.merge(primary: primary, into: secondary)
            if let patientId = loadingPatientId { await load(patientId: patientId) }
        } catch {
            // 同上
        }
    }
}

/// SP-19 健康时间轴：六类事件色点 + 过敏高亮 + 类型筛选 chips + 健康问题筛选入口。
/// 条目点击直达详情；空态给筛选引导（不显示误导性「暂无健康问题」结论）。
struct TimelineFullView: View {
    @Environment(AppState.self) private var app
    @Environment(TimelineViewState.self) private var state
    @Environment(AppRouter.self) private var router
    @Environment(AppDataChangeCenter.self) private var dataChange

    var body: some View {
        WithPerceptionTracking {
            let visible = state.visibleHubs
            Group {
                // 2026-09-15 实测修复：空态只看**本列表真正渲染的投影**（visible = 主卡 +
                // 无枢纽叶子）。原判据 `&& state.entries.isEmpty` 与平铺投影相与，而两者
                // 口径不同（平铺按 .lab/.selfMeasured/.healthData 任一命中即取指标行且不带
                // origin 谓词，主卡叶子按各自 origin 谓词）——「只有自测/导入指标、无就诊无
                // 体检」的用户筛「检验」时 visible 为空而 entries 非空，判据为假，页面只渲染
                // 快捷入口区、连「暂无记录」引导都没有。
                if visible.isEmpty {
                    VLUnavailableView(L10n.timelineEmptyTitle, systemImage: "calendar",
                                           description: Text(L10n.timelineEmptyHint))
                        .accessibilityIdentifier("SP-19.timeline.empty")
                } else {
                    // §9.1 正文行宽 ≤672pt（iPad 常宽列可读性；共享内容视图自身约束，ADR-021）
                    // v27（子项目 J · round1 §E.3）：主卡 + 折叠子卡（DisclosureGroup，iOS 14+ 原生）；叶子行形态不变。
                    List {
                        ForEach(visible) { item in
                            // ForEach 行闭包逃逸：同步读 state / expansion 感知对象，须自行包裹（子项目 I）
                            WithPerceptionTracking {
                                if let hub = item.hub {
                                    DisclosureGroup(isExpanded: Binding(
                                        get: { state.isExpanded(item.id) },
                                        set: { expanded in state.setExpanded(item.id, expanded) })) {
                                        ForEach(item.children) { child in
                                            Button {
                                                open(child)
                                            } label: {
                                                TimelineChildRowView(entry: child)
                                            }
                                            .accessibilityIdentifier("SP-19.child.\(child.kind.rawValue).\(child.refID.uuidString)")
                                        }
                                    } label: {
                                        TimelineHubRowView(item: item, hub: hub) { openHub(item) }
                                    }
                                    .accessibilityElement(children: .contain)
                                    .accessibilityIdentifier("SP-19.hub.\(item.entry.refID.uuidString)")
                                } else {
                                    Button {
                                        open(item.entry)
                                    } label: {
                                        TimelineRowView(entry: item.entry)
                                    }
                                    .accessibilityIdentifier("SP-19.timeline.row.\(item.entry.kind.rawValue)")
                                }
                            }
                            .onAppear {
                                // 游标翻页：末行进入视口即取下一页（替代旧「取 100 条即止」）
                                if item.id == visible.last?.id {
                                    Task { await state.loadMore(patientId: app.currentPatientId) }
                                }
                            }
                        }
                        if state.isLoadingMore {
                            HStack { Spacer(); ProgressView(); Spacer() }
                                .accessibilityLabel(L10n.timelineLoadingMore)
                                .accessibilityIdentifier("SP-19.timeline.loadingMore")
                        } else if state.loadMoreFailed {
                            Button(L10n.timelineLoadMoreFailed) {
                                Task { await state.loadMore(patientId: app.currentPatientId) }
                            }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("SP-19.timeline.loadMoreRetry")
                        }
                        // mock 对齐项：快捷入口区（只挂真实可用的落点，不放未落地入口）
                        Section(L10n.timelineQuickEntry) {
                            NavigationLink(value: AppRoute.documentList) {
                                Label(L10n.docLibraryTitle, systemImage: "folder")
                            }
                            .accessibilityIdentifier("SP-19.quick.documents")
                            NavigationLink(value: AppRoute.allergyList) {
                                Label(L10n.allergyTitle, systemImage: "allergens")
                            }
                            .accessibilityIdentifier("SP-19.quick.allergy")
                            NavigationLink(value: AppRoute.medicationCabinet) {
                                Label(L10n.inventory_title, systemImage: "pills")
                            }
                            .accessibilityIdentifier("SP-19.quick.cabinet")
                            // §5.45 指标总览入口（V3.72）：records 模块此前无任何指标入口
                            NavigationLink(value: AppRoute.metricOverview) {
                                Label(L10n.metricOverviewTitle, systemImage: "waveform.path.ecg")
                            }
                            .accessibilityIdentifier("SP-19.quick.metrics")
                        }
                    }
                    .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出
                    .tintedCanvas()   // 渐变直挂本容器（根级背景会被 TabView/导航栈系统底色覆盖，V4.06 修正）
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("SP-19.timeline.list")
                }
            }
            // §9.1 正文行宽 ≤672pt（iPad 常宽列可读性）——必须挂在 Group 上：
            // 裸修饰符位于 ViewBuilder 内 if/else 之后会以 View 类型为基解析失败
            // （CI 34027680175 实证 "instance member 'frame' cannot be used on type 'View'"）
            .frame(maxWidth: 672)
            .safeAreaInset(edge: .top) { filterBar }
            .navigationTitle(L10n.timelineTitle)
            .task(id: app.currentPatientId) { await state.load(patientId: app.currentPatientId) }
            // FR17.18 保存后跨页刷新（V3.49）：文档确认保存（含健康问题懒创建）
            // 后按类型化版本计数重载——时间轴/健康问题条目即时反映新文档/新问题
            .onChangeCompat(of: dataChange.documentsVersion) { _, _ in
                Task { await state.load(patientId: app.currentPatientId) }
            }
            // 2026-09-15 审查修复（业主第 3/7 项同族）：指标行（手输自测）经 metric_sample 落库后**也**
            // 投影进本页（`.selfMeasured` 叶子）——此前本页只观察 documentsVersion，落库后仍显示
            // 录入前的列表，须切成员/切 Tab 才刷新。
            // FR11.2 V4.05（2026-09-23）：Apple 健康导入（`.healthData`）已移出健康档案（专属
            // 「健康数据」tab），但本观察仍必需——手输自测行只经该信号刷新；其余设备数据面
            // （SP-29 展示区/详情页、指标总览、SP-13）各自观察。
            .onChangeCompat(of: dataChange.metricsVersion) { _, _ in
                Task { await state.load(patientId: app.currentPatientId) }
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: L10n.timelineFilterAll, selected: isAllSelected) {
                    state.setFilter(nil)
                    Task { await state.load(patientId: app.currentPatientId) }
                }
                // FR11.2 V4.05：筛选目录同读 Domain 单一事实源（Apple 健康导入 `.healthData` 不入健康档案，
                // 专属「健康数据」tab——此前 allCases 使该 chip 存于本页但恒空）
                ForEach(TimelineEntryKind.recordsArchiveKinds, id: \.rawValue) { kind in
                    // ForEach 行闭包逃逸：行内同步读感知对象属性，须自行包裹（子项目 I）
                    WithPerceptionTracking {
                        FilterChip(title: L10n.timelineKindName(kind), selected: selectedKinds.contains(kind)) {
                            toggle(kind)
                        }
                    }
                }
                // 评审修正 H15：走类型安全路由（注册表覆盖 SP-49）
                NavigationLink(value: AppRoute.healthProblemList) {
                    Text(L10n.timelineProblemsFilter)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)   // 审查修复：触点 ≥44pt
                        .background(Capsule().fill(Color("bg-grouped", bundle: .main)))   // 语义令牌（token-only 纪律，不用系统调色板）
                }
                // §5.35 时间轴成员切换（V3.72）：此前时间轴无成员切换入口
                Menu {
                    ForEach(app.members) { m in
                        Button(m.displayName) { app.setCurrentPatient(m.id) }
                    }
                } label: {
                    Text(currentMemberName)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(Color("bg-grouped", bundle: .main)))   // 语义令牌（token-only 纪律，不用系统调色板）
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(.thinMaterial)
    }

    private var currentMemberName: String {
        app.members.first(where: { $0.id == app.currentPatientId })?.displayName
            ?? app.owner?.displayName ?? L10n.help_appName
    }

    private var isAllSelected: Bool {
        if case .all = state.filter { return true }
        return false
    }

    private var selectedKinds: Set<TimelineEntryKind> {
        if case .kinds(let k) = state.filter { return k }
        return []
    }

    private func toggle(_ kind: TimelineEntryKind) {
        var kinds = selectedKinds
        if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
        state.setFilter(kinds.isEmpty ? nil : kinds)
        Task { await state.load(patientId: app.currentPatientId) }
    }

    /// 主卡行「详情」：就诊/住院期 → 就诊详情（修 A.1「点就诊进列表」）；体检 → 体检详情。
    private func openHub(_ item: TimelineHubEntry) {
        guard let hub = item.hub else { open(item.entry); return }
        switch hub {
        case .encounter, .hospitalization: router.navigate(to: .encounterDetail(item.entry.refID))
        case .healthExam: router.navigate(to: .healthExamDetail(patientId: item.entry.memberId, id: item.entry.refID))
        }
    }

    private func open(_ entry: TimelineEntry) {
        switch entry.kind {
        // 就诊恒为主卡（叶子形态不存在），保留以穷尽；落点同 openHub（不再进列表）
        case .encounter: router.navigate(to: .encounterDetail(entry.refID))
        // v27 主卡/子卡（round1 §D）：已确认卡详情 = medicalCard(kind = 事实表名)；体检/结论聚合 → 体检详情；
        // 预约/提醒走各自已登记路由（RecordChildKind.cardKind == nil）
        case .hospitalization, .diagnosis, .prescription, .labReport, .examReport, .claim, .surgery, .treatmentRecord:
            if let kind = RecordChildKind(rawValue: entry.kind.rawValue)?.cardKind {
                router.navigate(to: .medicalCard(kind: kind, id: entry.refID, patientId: entry.memberId))
            }
        case .healthExam, .clinicalConclusion:
            router.navigate(to: .healthExamDetail(patientId: entry.memberId, id: entry.refID))
        case .appointment: router.navigate(to: .appointmentDetail(entry.refID))
        case .reminder: router.navigate(to: .reminderToday)
        case .medication: router.navigate(to: .medicationPlan(entry.refID))
        case .observation: router.navigate(to: .observationDetail(entry.refID))
        // 2026-09-15 实测修复（业主第 3 项「Apple 健康导入的记录无法打开查看」）：
        // 指标行（手输自测 / Apple 健康导入）的 refID 是 `metric_sample.id`，不是
        // `observation.id`——原实现与 .observation 同路 → `ObservationStore.fetch`
        // 恒查无 → 每条导入记录点开都是「这条观察记录加载失败」。与 .lab 同口径：
        // 按 entry.metricKey 进该指标的已有趋势图（点 = 一次读数，归属由 memberId 下传）。
        // 2026-09-16 业主实测（第 5 项）：设备行**不再直跳趋势图**（「感觉突兀」）——
        // 落该类型的数据列表页（= 详细数据：逐条读数 + 统计事实），页内已有趋势入口按钮。
        // 手输自测保持原口径（点 = 一次手输读数，趋势图承载即可）。
        // V4.05（FR11.2）：本页不再投影 `.healthData`（专属「健康数据」tab）——
        // 本分支保留为穷举防御（子卡/平铺路径若未来再次喂入仍然正确落点）。
        case .healthData:
            if let m = entry.metricKey, let kind = HealthDataKind.forMetricKey(m) {
                router.navigate(to: .healthImportedData(kind: kind, patientId: entry.memberId))
            } else if let m = entry.metricKey {
                router.navigate(to: .trendChart(patientId: entry.memberId, metric: m))   // 非六类设备键（防御）
            } else {
                router.navigate(to: .metricQuickEntry)
            }
        case .selfMeasured:
            if let m = entry.metricKey {
                router.navigate(to: .trendChart(patientId: entry.memberId, metric: m))
            } else {
                router.navigate(to: .metricQuickEntry)
            }
        // 审查修复：用条目携带的真实指标键跳转——原硬编码 "glucose"，
        // 血压/心率化验点开的是血糖趋势图（张冠李戴）；无键时降级快速录入
        case .lab:
            if let m = entry.metricKey {
                router.navigate(to: .trendChart(patientId: entry.memberId, metric: m))
            } else {
                router.navigate(to: .metricQuickEntry)
            }
        // 第七轮全仓审查修复（三处错路）：疫苗条目落到就诊列表、健康问题
        // 落到成员管理、语音速记落到 AI 聊天——全部张冠李戴。疫苗/健康问题
        // 均有已登记的专用路由（immunizationList/healthProblemList，注册表
        // 全覆盖）；语音速记落点 = 速记面板（voiceNotePanel，FR17.14）。
        case .vaccination: router.navigate(to: .immunizationList)   // SP-54
        case .allergy: router.navigate(to: .allergyList)
        case .voiceNote: router.navigate(to: .voiceNotePanel)       // FR17.14 速记面板
        case .healthProblem: router.navigate(to: .healthProblemList)   // SP-49
        case .document: router.navigate(to: .documentDetail(entry.refID))
        }
    }
}

/// 时间轴行：六类事件色点 + 过敏高亮（FR11.1）
private struct TimelineRowView: View {
    let entry: TimelineEntry

    /// 行标题组装（L10n 单出口）：类别前缀经 timelineKindName 渲染——
    /// 此前前缀硬编码在 TimelineQueryStore SQL 内，zh-Hant/en 用户看到
    /// 简体残留；指标键经 MetricType(grammarKey:) 映射本地化指标名
    private var entryTitle: String {
        switch entry.kind {
        case .voiceNote:
            return L10n.timelineKindName(.voiceNote)
        case .document:
            return entry.title.isEmpty ? L10n.timelineKindName(.document) : entry.title
        case .lab, .selfMeasured, .healthData:
            let name = entry.metricKey.flatMap { MetricType(grammarKey: $0) }
                .map { L10n.metricName($0) } ?? entry.title
            return "\(L10n.timelineKindName(entry.kind)) · \(name)"
        default:
            // 2026-09-17：`entry.title` 对就诊/住院行是 `kind` canonical raw
            // （`TimelineQueryStore` 的 `e.kind AS title`）——此前本行直出英文 raw。
            // 与主卡行/子卡行同经 `DocumentsDisplay.timelineEntryTitle` 单一出口。
            return "\(L10n.timelineKindName(entry.kind)) · \(DocumentsDisplay.timelineEntryTitle(entry))"
        }
    }

    var body: some View {
        WithPerceptionTracking {
            HStack(alignment: .top, spacing: 10) {
                // 审查修复（健康数据指标图标）：Apple 导入健康数据行此前与
                // 其它六类共用品牌色圆点，指标间不可分辨——按 MetricType
                // 走 CardKindIcon.spec(metric:) 单一出口（与健康 Tab 同符号，
                // 跨面同符号纪律）
                if entry.kind == .healthData {
                    let symbol = entry.metricKey
                        .flatMap(MetricType.init(grammarKey:))
                        .map { CardKindIcon.spec(metric: $0).symbol }
                        ?? CardKindIcon.symbol(for: .healthData)
                    let tint = entry.metricKey
                        .flatMap(MetricType.init(grammarKey:))
                        .map { CardKindIcon.tint(metric: $0) }
                        ?? color
                    Image(systemName: symbol)
                        .font(.subheadline)
                        .foregroundStyle(tint)
                        .frame(width: 18)
                        .padding(.top, 4)
                } else {
                    Circle()
                        .fill(color)
                        .frame(width: 10, height: 10)
                        .padding(.top, 5)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entryTitle)
                            .font(.subheadline)
                            .foregroundStyle(entry.kind == .allergy
                                             ? Color("semantic-danger", bundle: .main)
                                             : .primary)
                        // 来源徽章（设计系统：每个结构化数据有来源徽章）；
                        // D = 机器识别未确认（不进入检索/AI 事实链，BR-003）。
                        // 2026-09-15 实测修复（业主第 6 项）：C 级（用户确认）此前逐行常驻
                        // 「C 我已确认」——健康档案里 100% 的行都有、零信息量，只剩噪声。
                        // 徽章只保留需要提醒的差异态：D/E（未确认）与 A/B（医院原文/信源库）；
                        // C = 默认事实态，不再出徽章。
                        if let grade = entry.grade, grade != "C" {
                            GradeBadge(grade: grade)
                        }
                    }
                    if let summary = entry.summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.vertical, 2)
        }
    }

    /// 色令牌唯一出口 `CardKindIcon`（v27：原本地 switch 已删——新增卡类只在出口登记，语义令牌随主题重映射不变）。
    private var color: Color { CardKindIcon.tint(for: entry.kind) }
}

private struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        WithPerceptionTracking {
            Button(action: action) {
                Text(title)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)   // 审查修复：触点 ≥44pt（原 ≈25pt，违反 ui-ux §4.2）
                    .background(Capsule().fill(selected
                                               ? Color("brand-primary", bundle: .main)
                                               : Color(.systemGray5)))
                    .foregroundStyle(selected ? .white : .primary)
            }
            .buttonStyle(PressScaleButtonStyle())   // 按压反馈统一（§3.3 V4.05）
        }
    }
}

// MARK: - FR11.4 健康问题管理（SP-49 · ui-ux §5.25）

/// 健康问题管理：列表（问题名+归档开关）+ 新建 + 合并。
/// 合并 = 选择主问题，被合并问题归档（各自历史不丢，FR11.4）。
struct HealthProblemListView: View {
    @Environment(AppState.self) private var app
    @Environment(TimelineViewState.self) private var state
    @Environment(AppDataChangeCenter.self) private var dataChange
    @State private var showCreate = false
    @State private var showMerge = false
    @State private var mergePrimary: HealthProblemStore.HealthProblemRow?

    var body: some View {
        WithPerceptionTracking {
            List {
                if state.problems.isEmpty {
                    VLUnavailableView(L10n.problemEmpty, systemImage: "cross.case",
                                           description: Text(L10n.problemEmptyHint))
                        .accessibilityIdentifier("SP-49.problem.empty")
                } else {
                    ForEach(state.problems) { problem in
                        HStack {
                            Text(problem.name).font(.subheadline)
                            Spacer()
                            Button {
                                showMerge = true
                                mergePrimary = problem
                            } label: {
                                Text(L10n.problemMerge)
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .frame(minHeight: 44)   // 触点≥44pt（审查修复）
                            Button(problem.archived ? L10n.problemUnarchive : L10n.problemArchive) {
                                Task { await state.setArchived(problemId: problem.id,
                                                               archived: !problem.archived) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .frame(minHeight: 44)   // 触点≥44pt（审查修复）
                        }
                        .accessibilityIdentifier("SP-49.problem.row.\(problem.id.uuidString)")
                    }
                }
            }
            .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出
            .tintedCanvas()   // 渐变直挂本容器（根级背景会被 TabView/导航栈系统底色覆盖，V4.06 修正）
            .navigationTitle(L10n.problemTitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.problemAdd)
                    .accessibilityIdentifier("SP-49.problem.add")
                }
            }
            .sheet(isPresented: $showCreate) {
                ProblemCreateSheet()
            }
            .confirmationDialog(L10n.problemMergeTitle, isPresented: $showMerge,
                                titleVisibility: .visible) {
                // confirmationDialog 动作区闭包逃逸：同步读 state.problems，须自行包裹（子项目 I）
                WithPerceptionTracking {
                    if let primary = mergePrimary {
                        ForEach(state.problems.filter { $0.id != primary.id && !$0.archived }) { other in
                            Button(L10n.problemMergeInto(other.name)) {
                                Task {
                                    // 「合并到哪个问题？」——被点选的问题为主问题（存活），
                                    // 长按发起的问题并入归档（ui-ux §5.25：选择主问题，
                                    // 两问题历史并入主问题下）。此前参数颠倒：按钮承诺
                                    // 「并入「B」」而实际归档 B 保留 A。
                                    await state.mergeProblems(primary: other.id, secondary: primary.id)
                                }
                            }
                        }
                    }
                    Button(L10n.commonCancel, role: .cancel) { mergePrimary = nil }
                }
            } message: {
                Text(L10n.problemMergeHint)
            }
            .task(id: app.currentPatientId) { await state.load(patientId: app.currentPatientId) }
        }
    }
}

private struct ProblemCreateSheet: View {
    @Environment(AppState.self) private var app
    @Environment(TimelineViewState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saveFailed = false

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                Form {
                    TextField(L10n.problemNamePlaceholder, text: $name)
                }
                .navigationTitle(L10n.problemCreateTitle)
                .saveFailedAlert(title: L10n.encounterSaveFailed,
                                 hint: L10n.problemSaveFailedHint,
                                 isPresented: $saveFailed)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.reminder_save) {
                            Task {
                                // 写库失败保留输入并提示——此前吞错后无条件 dismiss
                                if await state.createProblem(patientId: app.currentPatientId, name: name) {
                                    dismiss()
                                } else {
                                    saveFailed = true
                                }
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }
}

// MARK: - FR10.4 就诊准备包（ui-ux §5.34）

/// 就诊准备包：一页式摘要，固定分区顺序——患者信息 → 当前用药（过敏高亮）→
/// 症状观察 → 我要问的问题 → 上次医嘱与未办事项。
/// F16/F7 分区按功能可用性动态出现，P0 阶段以「无相关数据」占位而非报错。
struct VisitPrepView: View {
    @Environment(AppState.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(ReminderStore.self) private var reminders
    @Environment(ObservationStoreState.self) private var observationState
    @Environment(M2HubStore.self) private var hub
    @Environment(QuestionsState.self) private var questionsState

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                // §5.34 顶部 [给医生看]（V3.72 点亮——复用 5.8 展示模式）
                HStack {
                    Spacer()
                    Button {
                        router.navigate(to: .doctorShowcase(patientId: app.currentPatientId))
                    } label: {
                        Label(L10n.showcaseTitle, systemImage: "stethoscope")
                    }
                    .buttonStyle(.bordered)
                    .padding(.trailing, 16)
                }
                .padding(.top, 8)
            }

            List {
                // 患者信息
                Section(L10n.prepPatient) {
                    let profile = app.members.first(where: { $0.id == app.currentPatientId })
                    Text(profile?.displayName ?? app.owner?.displayName ?? L10n.help_appName)
                        .font(.headline)
                    if let relation = profile?.relation {
                        // 审查修复（L10n 单出口）：relation 存储值是 MemberRelation 的中文
                        // rawValue（配偶/子女/…），此前直出——该页是给医生看的打印页，
                        // en/zh-Hant 用户会看到简体中文关系词。全仓其余 4 处均已映射。
                        Text(L10n.memberRelationDisplayName(relation))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let bloodType = hub.loadedPatientId == app.currentPatientId ? hub.bloodType : nil {
                        LabeledContent(L10n.prepBloodType, value: bloodType)
                    }
                }
                // 当前用药（过敏高亮）——BR-001 门控（第九轮审查 M1c 同族修复，
                // 与下方观察分区同一判据）：hub 是成员级缓存、分节异步提交，
                // 成员切换后 loadedPatientId 未变期间渲染的是**上一成员**的
                // 血型/用药/过敏，与表头新成员姓名错配（跨成员医疗信息泄露）。
                Section(L10n.prepMeds) {
                    let meds = hub.loadedPatientId == app.currentPatientId ? hub.inventoryItems : []
                    if meds.isEmpty {
                        Text(L10n.prepNoData).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(meds) { item in
                            HStack {
                                Text(item.medicationName).font(.subheadline)
                                Spacer()
                                if let days = item.approxDaysLeft {
                                    Text(L10n.prepDaysLeft(days)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    // 过敏高亮（BR-001 门控：同上方判据——成员切换期间不得
                    // 在新成员姓名下渲染上一成员的过敏高亮）
                    let allergies = hub.loadedPatientId == app.currentPatientId
                        ? hub.emergencySelected.allergies : []
                    if !allergies.isEmpty {
                        ForEach(allergies) { a in
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color("semantic-danger", bundle: .main))
                                Text(a.title).font(.subheadline)
                                    .foregroundStyle(Color("semantic-danger", bundle: .main))
                            }
                        }
                    }
                }
                // 症状观察（最近）——BR-001 门控（第九轮审查 M1c 同族修复）：
                // 共享观察组仅当属于当前成员时才渲染，切换窗口/加载失败不串成员
                Section(L10n.prepObservations) {
                    let obs = observationState.loadedPatientId == app.currentPatientId
                        ? observationState.groups.flatMap(\.occurrences).prefix(5) : [].prefix(5)
                    if obs.isEmpty {
                        Text(L10n.prepNoData).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(obs)) { o in
                            Text("\(L10n.observationKindName(o.kind)) · \(o.occurredAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                        }
                    }
                }
                // 我要问的问题（FR10.5 自动汇入）
                Section(L10n.prepQuestions) {
                    let questions = questionsState.openQuestions
                    if questions.isEmpty {
                        Text(L10n.prepNoQuestions).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(questions) { q in
                            Text(q.body).font(.subheadline)
                        }
                    }
                }
                // 免责（BR-006：只呈现事实）
                Section {
                    Text(L10n.prepDisclaimer)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出
            .tintedCanvas()   // 渐变直挂本容器（根级背景会被 TabView/导航栈系统底色覆盖，V4.06 修正）
            .navigationTitle(L10n.prepTitle)
            .task(id: app.currentPatientId) {
                await reminders.refreshTriggered(patientId: app.currentPatientId)
                await hub.load(patientId: app.currentPatientId)
                await observationState.load(patientId: app.currentPatientId)
                await questionsState.load(patientId: app.currentPatientId)
            }
        }
    }
}

// MARK: - FR10.5 问诊问题状态仓

@MainActor
@Perceptible
final class QuestionsState {
    private(set) var questions: [QuestionStore.QuestionRow] = []
    private let store: QuestionStore
    private var loadingPatientId: UUID?

    init(store: QuestionStore) { self.store = store }

    var openQuestions: [QuestionStore.QuestionRow] {
        questions.filter { $0.status == "open" }
    }

    func load(patientId: UUID) async {
        loadingPatientId = patientId
        do {
            let rows = try await store.list(patientId: patientId)
            guard loadingPatientId == patientId else { return }
            questions = rows
        } catch {
            // 审查修复：读取失败保留旧列表（同上 doctrine）——原置空把
            // 存在的问题记录渲染成「暂无问题」假空态。
        }
    }

    /// 返回是否写入成功——调用侧据此决定反馈（写失败绝不播报「已记录」）
    @discardableResult
    func add(patientId: UUID, body: String) async -> Bool {
        do {
            _ = try await store.add(patientId: patientId, body: body)
            await load(patientId: patientId)
            return true
        } catch {
            // 失败保留输入可重试（错误经调用侧呈现）
            return false
        }
    }

    func markAsked(id: UUID) async {
        do {
            try await store.markAsked(id: id)
            if let patientId = loadingPatientId { await load(patientId: patientId) }
        } catch {
            // 同上
        }
    }
}

// MARK: - FR10.5 问诊问题列表

/// 问诊问题：随时记录，自动汇入准备包（FR10.4）。
struct QuestionListView: View {
    @Environment(AppState.self) private var app
    @Environment(QuestionsState.self) private var state
    @Environment(AppDataChangeCenter.self) private var dataChange
    @State private var newText = ""
    @State private var showAdd = false
    /// 写库失败保留输入并提示——QuestionsState.add 已返回 Bool，
    /// 本调用侧此前仍无条件清空关闭（问题静默丢失，BR-004 真实性）
    @State private var saveFailed = false

    var body: some View {
        WithPerceptionTracking {
            List {
                ForEach(state.questions) { q in
                    HStack {
                        Text(q.body).font(.subheadline)
                        Spacer()
                        if q.status == "asked" {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color("semantic-success", bundle: .main))
                        } else if q.status == "open" {
                            Button(L10n.questionMarkAsked) {
                                Task { await state.markAsked(id: q.id) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .frame(minHeight: 44)   // 触点≥44pt（审查修复）
                        }
                    }
                    .accessibilityIdentifier("FR10.5.question.row")
                }
            }
            .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出
            .tintedCanvas()   // 渐变直挂本容器（根级背景会被 TabView/导航栈系统底色覆盖，V4.06 修正）
            .navigationTitle(L10n.questionTitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.questionAdd)
                    .accessibilityIdentifier("FR10.5.question.add")
                }
            }
            .sheet(isPresented: $showAdd) {
                NavigationStack {
                    Form {
                        TextField(L10n.questionPlaceholder, text: $newText, axis: .vertical)
                            .lineLimit(3...8)
                    }
                    .navigationTitle(L10n.questionTitle)
                    // 警报必须挂在 sheet 内容内：父视图的 alert 会被 sheet
                    // 压住无法呈现（StockLotViews 第七轮同款教训）
                    .saveFailedAlert(title: L10n.encounterSaveFailed,
                                     hint: L10n.f19RecordFailed,
                                     isPresented: $saveFailed)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.reminder_save) {
                                Task {
                                    // 写库结果决定关闭/清空——此前吞错后无条件
                                    // 清空并 dismiss，问题静默丢失（BR-004）
                                    if await state.add(patientId: app.currentPatientId, body: newText) {
                                        newText = ""
                                        showAdd = false
                                    } else {
                                        saveFailed = true
                                    }
                                }
                            }
                            .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
            .task(id: app.currentPatientId) { await state.load(patientId: app.currentPatientId) }
            // FR11.4 懒创建后刷新（V3.49）：文档保存/健康问题创建 → 版本计数重载
            .onChangeCompat(of: dataChange.documentsVersion) { _, _ in
                Task { await state.load(patientId: app.currentPatientId) }
            }
        }
    }
}
