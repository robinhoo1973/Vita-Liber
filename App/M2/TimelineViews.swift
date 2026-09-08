import SwiftUI
import Domain
import Infrastructure

// MARK: - F11 健康时间轴（SP-19 · FR11.1-11.4）

/// 时间轴状态仓：八类事件联合查询 + 筛选 + 健康问题（BR-001 成员隔离）
@MainActor
@Observable
final class TimelineViewState {
    private(set) var entries: [TimelineEntry] = []
    private(set) var filter: TimelineFilter = .all
    private(set) var problems: [HealthProblemStore.HealthProblemRow] = []
    private let store: TimelineQueryStore
    private let problemStore: HealthProblemStore
    private var loadingPatientId: UUID?

    init(store: TimelineQueryStore, problemStore: HealthProblemStore) {
        self.store = store
        self.problemStore = problemStore
    }

    func load(patientId: UUID) async {
        loadingPatientId = patientId
        do {
            async let page = store.entries(for: patientId, filter: filter, limit: 100)
            async let probs = problemStore.list(patientId: patientId)
            let (p, pr) = try await (page, probs)
            guard loadingPatientId == patientId else { return }
            entries = p.entries
            problems = pr
        } catch {
            // 审查修复：读取失败保留旧列表（EncountersState/DocumentsState
            // 同款 doctrine）——原置空把存在记录渲染成「暂无记录」假空态。
        }
    }

    func setFilter(_ kinds: Set<TimelineEntryKind>?) {
        filter = kinds.map { TimelineFilter.kinds($0) } ?? .all
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
        Group {
            if state.entries.isEmpty {
                ContentUnavailableView(L10n.timelineEmptyTitle, systemImage: "calendar",
                                       description: Text(L10n.timelineEmptyHint))
                    .accessibilityIdentifier("SP-19.timeline.empty")
            } else {
                // §9.1 正文行宽 ≤672pt（iPad 常宽列可读性；共享内容视图自身约束，ADR-021）
                List {
                    ForEach(state.entries) { entry in
                        Button {
                            open(entry)
                        } label: {
                            TimelineRowView(entry: entry)
                        }
                        .accessibilityIdentifier("SP-19.timeline.row.\(entry.kind.rawValue)")
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
        .onChange(of: dataChange.documentsVersion) { _, _ in
            Task { await state.load(patientId: app.currentPatientId) }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: L10n.timelineFilterAll, selected: isAllSelected) {
                    state.setFilter(nil)
                    Task { await state.load(patientId: app.currentPatientId) }
                }
                ForEach(TimelineEntryKind.allCases, id: \.rawValue) { kind in
                    FilterChip(title: L10n.timelineKindName(kind), selected: selectedKinds.contains(kind)) {
                        toggle(kind)
                    }
                }
                // 评审修正 H15：走类型安全路由（注册表覆盖 SP-49）
                NavigationLink(value: AppRoute.healthProblemList) {
                    Text(L10n.timelineProblemsFilter)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)   // 审查修复：触点 ≥44pt
                        .background(Capsule().fill(Color(.systemGray5)))
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
                        .background(Capsule().fill(Color(.systemGray5)))
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

    private func open(_ entry: TimelineEntry) {
        switch entry.kind {
        case .encounter: router.navigate(to: .encounterList)
        case .medication: router.navigate(to: .medicationPlan(entry.refID))
        case .observation, .selfMeasured: router.navigate(to: .observationDetail(entry.refID))
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(L10n.docTitle(entry.title))
                        .font(.subheadline)
                        .foregroundStyle(entry.kind == .allergy
                                         ? Color("semantic-danger", bundle: .main)
                                         : .primary)
                    // 来源徽章（设计系统：每个结构化数据有来源徽章）；
                    // D = 机器识别未确认（不进入检索/AI 事实链，BR-003）
                    if let grade = entry.grade {
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

    private var color: Color {
        // 审查修复：语义令牌替代 SwiftUI 调色板原色——深色/高对比度/关怀模式
        // 下随主题重映射，不会出现与语义令牌体系不一致的固定色
        switch entry.kind {
        case .encounter: return Color("brand-primary", bundle: .main)
        case .medication: return Color("grade-c", bundle: .main)
        case .observation: return Color("semantic-warning", bundle: .main)
        case .lab, .selfMeasured: return Color("brand-primary", bundle: .main)
        case .vaccination: return Color("semantic-success", bundle: .main)
        case .allergy: return Color("semantic-danger", bundle: .main)
        case .voiceNote: return Color("text-secondary", bundle: .main)
        case .healthProblem: return Color("brand-primary", bundle: .main)
        case .document: return Color("text-secondary", bundle: .main)
        }
    }
}

private struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
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
        .buttonStyle(.plain)
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
        List {
            if state.problems.isEmpty {
                ContentUnavailableView(L10n.problemEmpty, systemImage: "cross.case",
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
        } message: {
            Text(L10n.problemMergeHint)
        }
        .task(id: app.currentPatientId) { await state.load(patientId: app.currentPatientId) }
    }
}

private struct ProblemCreateSheet: View {
    @Environment(AppState.self) private var app
    @Environment(TimelineViewState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saveFailed = false

    var body: some View {
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
                    Text(relation).font(.caption).foregroundStyle(.secondary)
                }
                if let bloodType = hub.bloodType {
                    LabeledContent(L10n.prepBloodType, value: bloodType)
                }
            }
            // 当前用药（过敏高亮）
            Section(L10n.prepMeds) {
                let meds = hub.inventoryItems
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
                // 过敏高亮
                let allergies = hub.emergencySelected.allergies
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
        .navigationTitle(L10n.prepTitle)
        .task(id: app.currentPatientId) {
            await reminders.refreshTriggered(patientId: app.currentPatientId)
            await hub.load(patientId: app.currentPatientId)
            await observationState.load(patientId: app.currentPatientId)
            await questionsState.load(patientId: app.currentPatientId)
        }
    }
}

// MARK: - FR10.5 问诊问题状态仓

@MainActor
@Observable
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
        .onChange(of: dataChange.documentsVersion) { _, _ in
            Task { await state.load(patientId: app.currentPatientId) }
        }
    }
}
