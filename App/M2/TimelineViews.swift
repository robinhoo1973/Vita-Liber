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
            entries = []
            problems = []
        }
    }

    func setFilter(_ kinds: Set<TimelineEntryKind>?) {
        filter = kinds.map { TimelineFilter.kinds($0) } ?? .all
    }

    func createProblem(patientId: UUID, name: String) async {
        do {
            _ = try await problemStore.create(patientId: patientId, name: name)
            await load(patientId: patientId)
        } catch {
            // 错误经日志；UI 保留输入可重试
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

    var body: some View {
        Group {
            if state.entries.isEmpty {
                ContentUnavailableView(L10n.timelineEmptyTitle, systemImage: "calendar",
                                       description: Text(L10n.timelineEmptyHint))
                    .accessibilityIdentifier("SP-19.timeline.empty")
            } else {
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
                    }
                }
                .accessibilityIdentifier("SP-19.timeline.list")
            }
        }
        .safeAreaInset(edge: .top) { filterBar }
        .navigationTitle(L10n.timelineTitle)
        .task(id: app.currentPatientId) { await state.load(patientId: app.currentPatientId) }
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
                NavigationLink {
                    HealthProblemListView()
                } label: {
                    Text(L10n.timelineProblemsFilter)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)   // 审查修复：触点 ≥44pt
                        .background(Capsule().fill(Color(.systemGray5)))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(.thinMaterial)
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
        case .vaccination: router.navigate(to: .encounterList)   // SP-54 列表经设置入口
        case .allergy: router.navigate(to: .allergyList)
        case .voiceNote: router.navigate(to: .assistantChat)
        case .healthProblem: router.navigate(to: .memberList)
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
                    Text(entry.title)
                        .font(.subheadline)
                        .foregroundStyle(entry.kind == .allergy ? .red : .primary)
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
                            // 合并语义由 HealthProblemStore.merge 承载（被合并问题归档）
                            await state.mergeProblems(primary: primary.id, secondary: other.id)
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

    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.problemNamePlaceholder, text: $name)
            }
            .navigationTitle(L10n.problemCreateTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.reminder_save) {
                        Task {
                            await state.createProblem(patientId: app.currentPatientId, name: name)
                            dismiss()
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
    @Environment(ReminderStore.self) private var reminders
    @Environment(ObservationStoreState.self) private var observationState
    @Environment(M2HubStore.self) private var hub
    @Environment(QuestionsState.self) private var questionsState

    var body: some View {
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
                                .foregroundStyle(.red)
                            Text(a.title).font(.subheadline).foregroundStyle(.red)
                        }
                    }
                }
            }
            // 症状观察（最近）
            Section(L10n.prepObservations) {
                let obs = observationState.groups.flatMap(\.occurrences).prefix(5)
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
            await reminders.refresh(patientId: app.currentPatientId)
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
            questions = []
        }
    }

    func add(patientId: UUID, body: String) async {
        do {
            _ = try await store.add(patientId: patientId, body: body)
            await load(patientId: patientId)
        } catch {
            // 失败保留输入可重试
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
    @State private var newText = ""
    @State private var showAdd = false

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
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.reminder_save) {
                            Task {
                                await state.add(patientId: app.currentPatientId, body: newText)
                                newText = ""
                                showAdd = false
                            }
                        }
                        .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .task(id: app.currentPatientId) { await state.load(patientId: app.currentPatientId) }
    }
}
