import SwiftUI
import Domain
import Protocols
import Infrastructure
import Perception

/// F12 全局搜索（SP-20 · ui-ux §5.36）：即输入即搜。
///
/// 结果分组展示（文档/观察/用药），每条显示来源徽章与日期，点击回原文；
/// 空结果明确说「未找到」并给降级建议。归档默认不进入结果（搜索服务
/// status IN ('active','favorite') 已保证）；敏感观察的文字描述可命中，
/// 但结果以锁定媒体态呈现（BR-007/008——不因搜索自动解锁图片）。
///
/// 文档检索走 FTS 三条路由（GRDBSearchService）；观察与用药在成员投影上
/// 内存过滤（FR12.1 覆盖范围的 P0 落地，FTS 扩展随 Phase 5）。
@MainActor
@Perceptible
final class SearchViewState {
    private(set) var query = ""
    private(set) var docHits: [EntityReference] = []
    /// 检索失败可见标记（四态纪律：失败 ≠ 无结果——此前 catch 清空 docHits
    /// 渲染「未找到」，DB/FTS 故障被谎报成空档案）
    private(set) var loadFailed = false

    private let search: any FullTextSearch
    init(search: any FullTextSearch) { self.search = search }

    /// 查询代际守卫（审查修复）：逐键发起的无约束 Task 存在乱序写回——
    /// 慢的旧查询晚于新查询返回时会覆盖新结果。取结果前校验代际，
    /// 与 ObservationViews 的 loadGeneration 同一纪律。
    private var searchGeneration = 0

    func setQuery(_ q: String) {
        query = q
        searchGeneration += 1
    }

    /// 成员切换代际推进（审查修复）：代际此前只随查询文本变化推进——
    /// 成员 A 的在途检索晚于成员 B 的检索返回时（同代际 N）覆盖 B 的
    /// docHits，A 的文档标题/OCR 片段在 B 身份下渲染（BR-001 越权显示）。
    func bumpGeneration() { searchGeneration += 1 }

    /// 第七轮全仓审查修复：语音「搜索 X」注入为**一次性投递**——
    /// 原实现把注入词写进持久 query，搜索页每次新开会复活上一次的注入词
    /// 并自动检索（用户新开搜索却撞上旧词的旧结果，意图被劫持）。
    /// 用户键入仍走 setQuery；注入走 injectQuery，视图 onAppear 经
    /// consumeInjectedQuery 取走即清（pendingVoiceDraft 同款一次性语义）。
    /// 第八轮修复：改为可观察（private(set)）——搜索页已在栈顶时
    /// onChange 就地消费注入词（router 去重下 onAppear 不再触发）。
    private(set) var injectedQuery: String?

    func injectQuery(_ q: String) {
        query = q
        injectedQuery = q
        searchGeneration += 1
    }

    func consumeInjectedQuery() -> String? {
        defer { injectedQuery = nil }
        return injectedQuery
    }

    func search(patientId: UUID) async {
        let generation = searchGeneration
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            docHits = []
            loadFailed = false
            return
        }
        do {
            let hits = try await search.search(trimmed,
                                               scope: DataAccessScope(patientIds: [patientId]),
                                               limit: 30)
            // 旧代际结果丢弃（查询文本已变）
            guard generation == searchGeneration else { return }
            docHits = hits
            loadFailed = false
        } catch {
            guard generation == searchGeneration else { return }
            // 检索失败 = 空结果 + 独立失败态（四态纪律：不把 DB/FTS 故障
            // 谎报成「没有找到」）
            docHits = []
            loadFailed = true
        }
    }
}

struct GlobalSearchView: View {
    @Environment(AppState.self) private var app
    @Environment(ObservationStoreState.self) private var observationState
    @Environment(M2HubStore.self) private var hub
    @Environment(SearchViewState.self) private var state
    @Environment(AppRouter.self) private var router
    @State private var filterText = ""

    private var query: String { filterText }

    /// FR17.14 审计修正（round3）：检索结果按 kind 分流——voice_note 命中必须单独
    /// 成组（此前统一并入「资料」组且点击跳文档详情，跳过去必然“未找到”）。
    private var documentHits: [EntityReference] {
        state.docHits.filter { $0.kind != "voice_note" }
    }

    private var voiceNoteHits: [EntityReference] {
        state.docHits.filter { $0.kind == "voice_note" }
    }

    /// 健康数据命中（2026-09-16 委员会评审②）：Apple 健康导入读数此前**搜不到**
    /// （FTS 无 metric_sample 路由）。口径：指标**本地化名**（L10n.metricName，
    /// 单出口在 App 层——Domain 不持文案）前缀/包含匹配 query → 命中该指标的
    /// 六类数据之一，点击落该类型数据列表页（SP-29 详情，页内可进趋势）。
    private var healthDataHits: [(kind: HealthDataKind, metric: MetricType)] {
        guard query.count >= 1 else { return [] }
        var seen = Set<HealthDataKind>()
        return MetricType.allCases.compactMap { metric in
            guard L10n.metricName(metric).contains(query) else { return nil }
            guard let kind = HealthDataKind.allCases.first(where: { $0.primaryMetric == metric }),
                  seen.insert(kind).inserted else { return nil }
            return (kind, metric)
        }
    }

    private var observationHits: [ObservationEvent] {
        guard !query.isEmpty else { return [] }
        return observationState.groups
            .flatMap(\.occurrences)
            .filter { $0.memberId == app.currentPatientId }
            .filter { ($0.description ?? "").localizedCaseInsensitiveContains(query)
                      || L10n.observationKindName($0.kind).localizedCaseInsensitiveContains(query) }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    private var medicationHits: [MedicationStore.InventorySummaryItem] {
        guard !query.isEmpty else { return [] }
        // 审查修复（BR-001 切换窗口）：inventoryItems 在成员切换加载窗口内
        // 仍是旧成员数据，且 InventorySummaryItem 无成员字段——此前直接
        // 过滤渲染，A 的药品名在 B 身份下命中展示。与 HomeView 同口径：
        // hub 全部节提交完成（loadedPatientId 一致）才取用缓存。
        guard hub.loadedPatientId == app.currentPatientId else { return [] }
        return hub.inventoryItems.filter {
            $0.medicationName.localizedCaseInsensitiveContains(query)
                || ($0.spec ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private var allEmpty: Bool {
        state.docHits.isEmpty && observationHits.isEmpty && medicationHits.isEmpty
    }

    var body: some View {
        WithPerceptionTracking {
            // 第八轮全仓审查修复（每帧重复计算）：observationHits 对全量观察
            // 事件做 flatMap+两次本地化子串过滤+排序，medicationHits 同族——
            // 原实现每帧 body 求值各算两遍（allEmpty 一遍 + 分区一遍）。改为
            // 每帧求值一次的局部常量，两次消费同一结果。
            let obsHits = observationHits
            let medHits = medicationHits
            // 审查修正（每帧重复计算，同第八轮修复同族）：healthDataHits 在
            // allEmpty/空态判据/分区渲染三处各求值一次——提升为同款局部常量。
            let healthHits = healthDataHits
            // WithPerceptionTracking 的 @ViewBuilder 闭包内不能显式 return（会关闭 result builder 变换）
            List {
                if query.isEmpty {
                    VLUnavailableView(L10n.searchTitle, systemImage: "magnifyingglass",
                                           description: Text(L10n.searchPlaceholderHint))
                        .accessibilityIdentifier("SP-20.search.idle")
                } else if state.loadFailed {
                    // 四态纪律：检索失败独立呈现（不冒充「未找到」）
                    VLUnavailableView {
                        Label(L10n.searchLoadFailed, systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(L10n.searchLoosenHint)
                    } actions: {
                        Button(L10n.searchRetry) {
                            Task { await state.search(patientId: app.currentPatientId) }
                        }
                    }
                    .accessibilityIdentifier("SP-20.search.failed")
                // 空态判据必须含 `healthDataHits`（评审 2026-09-16 发现）：此前漏了它，
                // 而健康分组只渲染在 else 分支内——**仅命中健康数据时**（搜「血糖」，
                // 文档/观察/用药皆空）页面渲染「未找到」且健康命中分组永不出现，
                // 使 FR16.l 健康数据搜索在其唯一价值场景（FTS 无 metric_sample 路由、
                // 只能靠本地化名匹配）静默失效。缺陷由 ce4d6d7 引入，e27f5e4 结构搬运时
                // 原样携带。
                } else if state.docHits.isEmpty && obsHits.isEmpty && medHits.isEmpty
                            && healthHits.isEmpty {
                    VLUnavailableView {
                        Label(L10n.searchNoResult(query), systemImage: "magnifyingglass")
                    } description: {
                        Text(L10n.searchLoosenHint)
                    } actions: {
                        Button(L10n.searchClear) { filterText = "" }
                    }
                    .accessibilityIdentifier("SP-20.search.empty")
                } else {
                    if !healthHits.isEmpty { healthDataSection }
                    if !documentHits.isEmpty { documentSection }
                    // FR17.14：语音速记正文命中（跳 SP-59 面板；列表内可选中所属条目）
                    if !voiceNoteHits.isEmpty { voiceNoteSection }
                    if !obsHits.isEmpty { observationSection(obsHits) }
                    if !medHits.isEmpty { medicationSection(medHits) }
                }
            }
            .navigationTitle(L10n.searchTitle)
            .searchable(text: $filterText, prompt: L10n.searchPlaceholder)
            .onAppear {
                // 语音会话「搜索 X」确认后经共享状态注入搜索词（第六轮全仓
                // 审查修复：词随 openSearch 指令丢弃，搜索页空开）。
                // 第七轮修复：改经一次性投递通道取词（consumeInjectedQuery 取走
                // 即清）——不再读持久 query，旧会话的搜索词不会在新开搜索页
                // 复活并自动检索；注入词由 filterText 变化驱动既有防抖检索。
                if filterText.isEmpty, let injected = state.consumeInjectedQuery() {
                    filterText = injected
                }
            }
            .onChangeCompat(of: state.injectedQuery) { _, injected in
                // 第八轮全仓审查修复（栈顶去重下的语音搜索）：搜索页已是 AI
                // Tab 栈顶时 router 去重守卫把「搜索 X」变成静默 no-op——注入词
                // 滞留共享状态，直到下次新开搜索页才被 onAppear 消费（陈旧词
                // 劫持一次无关搜索）。注入词变化即就地消费：更新输入框并触发
                // 既有防抖检索，任何路径都即时生效。
                // 审查修复（相等值滞留）：注入词与当前输入相等时也必须先取走
                // ——此前 guard 在 consume 之前对相等值早退，一次性投递词滞留
                // 共享状态，下次新开搜索页被 onAppear 消费成用户没要求的检索
                // （陈旧词劫持意图）。
                guard let injected else { return }
                _ = state.consumeInjectedQuery()
                guard injected != filterText else { return }
                filterText = injected
            }
            .task(id: app.currentPatientId) {
                await hub.load(patientId: app.currentPatientId)
                await observationState.load(patientId: app.currentPatientId)
                // 审查修复（BR-001 切换窗口）：docHits 是上次检索结果，成员切换
                // 不触发防抖 onChange——旧成员的文档命中（标题/OCR 片段）在 B
                // 身份下继续渲染。切成员即按当前词以新成员重查（空词同样清空）。
                // 代际推进：成员 A 的在途检索必须作废（否则晚到的 A 结果覆盖
                // B 的命中，跨成员显示）。
                state.bumpGeneration()
                await state.search(patientId: app.currentPatientId)
            }
            .onChangeCompat(of: filterText) { _, newValue in
                state.setQuery(newValue)
                // 审查修复：250ms 防抖——原实现逐键发起全量 FTS 查询（无取消、
                // 无代际守卫），连续输入既浪费 CPU/电池又存在乱序覆盖
                debounceTask?.cancel()
                debounceTask = Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)   // try?-ok: 防抖等待被新键入取消属预期（连续输入即连续 cancel），无需处理
                    guard !Task.isCancelled else { return }
                    await state.search(patientId: app.currentPatientId)
                }
            }
            .onDisappear { debounceTask?.cancel() }
        }
    }

    // MARK: - 命中分区（类型检查超时修复，CI 35053753500）

    /// 2026-09-16：五个分区原先全部内联在 `body` 的 `else` 分支里，整个 `List` 是
    /// **一个**巨型 ViewBuilder 表达式，Swift 类型检查器解不出来
    /// （`GlobalSearchView.swift:191: the compiler is unable to type-check this
    /// expression in reasonable time`）→ 编译门禁红、归档与上传全断。
    /// L0「长链高阶」启发式只覆盖链式调用（`.map/.filter/…` ≥6 段），不覆盖
    /// **嵌套深度**，故门禁不报——这是 Linux 预推通道的已知盲区（App/ 零类型检查）。
    /// 按分区拆成独立子视图：类型检查按属性分治，各自小到可解。
    /// 同族先例：`92a1301`（HealthImportRow 投影表达式拆分）。
    ///
    /// `obsHits`/`medHits` 以**参数**传入而非重算——`body` 里把它们绑成局部常量
    /// 是为避免每帧重复 flatMap + 本地化过滤 + 排序（见 body 顶部注释），
    /// 抽成属性后直接读计算属性会把那次优化抹掉。

    @ViewBuilder private var healthDataSection: some View {
        Section(L10n.searchGroupHealthData) {
            ForEach(healthDataHits, id: \.kind) { hit in
                Button {
                    router.navigate(to: .healthImportedData(kind: hit.kind, patientId: app.currentPatientId))
                } label: {
                    SearchResultRow(title: L10n.metricName(hit.metric),
                                    snippet: L10n.searchHealthDataHint,
                                    badge: L10n.gradeBadgeD, date: nil,
                                    icon: CardKindIcon.spec(metric: hit.metric).symbol)
                }
            }
        }
    }

    @ViewBuilder private var documentSection: some View {
        Section(L10n.searchGroupDocs) {
            ForEach(documentHits, id: \.refID) { hit in
                Button {
                    router.navigate(to: .documentDetail(hit.refID))
                } label: {
                    SearchResultRow(title: hit.title,
                                    snippet: hit.isSensitive ? L10n.searchObsLocked : hit.snippet,
                                    badge: hit.isSensitive ? L10n.searchSensitive : nil,
                                    date: nil)
                }
                .accessibilityIdentifier("SP-20.search.doc.\(hit.refID.uuidString)")
            }
        }
    }

    @ViewBuilder private var voiceNoteSection: some View {
        Section(L10n.voicenoteTitle) {
            ForEach(voiceNoteHits, id: \.refID) { hit in
                Button {
                    router.navigate(to: .voiceNotePanel)
                } label: {
                    SearchResultRow(title: hit.title, snippet: hit.snippet,
                                    badge: nil, date: nil)
                }
                .accessibilityIdentifier("SP-20.search.note.\(hit.refID.uuidString)")
            }
        }
    }

    @ViewBuilder private func observationSection(_ obsHits: [ObservationEvent]) -> some View {
        Section(L10n.searchGroupObservations) {
            ForEach(obsHits) { obs in
                Button {
                    router.navigate(to: .observationDetail(obs.id))
                } label: {
                    // BR-007/008：敏感观察命中仍以锁定媒体态呈现；
                    // 无媒体附件的普通观察不加敏感徽章、显示描述片段
                    // （此前无条件标敏感——GradeBadge 纪律要求徽章
                    // 如实反映属性，普通「头痛」条目被系统性误标）
                    if obs.mediaAssetIds.isEmpty {
                        SearchResultRow(title: obs.description ?? L10n.observationKindName(obs.kind),
                                        snippet: "", badge: nil,
                                        date: obs.occurredAt)
                    } else {
                        SearchResultRow(title: obs.description ?? L10n.observationKindName(obs.kind),
                                        snippet: L10n.searchObsLocked,
                                        badge: L10n.searchSensitive,
                                        date: obs.occurredAt)
                    }
                }
                .accessibilityIdentifier("SP-20.search.obs.\(obs.id.uuidString)")
            }
        }
    }

    @ViewBuilder private func medicationSection(_ medHits: [MedicationStore.InventorySummaryItem]) -> some View {
        Section(L10n.searchGroupMeds) {
            ForEach(medHits) { item in
                Button {
                    router.navigate(to: .medicationCabinet)
                } label: {
                    SearchResultRow(title: item.medicationName,
                                    snippet: item.spec ?? "",
                                    badge: "C",
                                    date: item.expireAt)
                }
                .accessibilityIdentifier("SP-20.search.med.\(item.lotId.uuidString)")
            }
        }
    }

    @State private var debounceTask: Task<Void, Never>?
}

/// 搜索结果行：来源徽章 + 标题 + 片段 + 日期（GradeBadge 全仓组件的 P0 形态）
/// 审查修复：badge 改可选——原对一切非敏感文档硬编码「A 级医院原始」徽章
/// 属来源等级造假（来源是属性，不是默认可赋值）；敏感命中显示「敏感」徽章。
private struct SearchResultRow: View {
    let title: String
    let snippet: String
    let badge: String?
    let date: Date?
    /// 行首图标（审查修复：健康数据命中此前无图标——经 CardKindIcon
    /// 单一出口传指标符号；其余分组不传保持原形态）
    var icon: String? = nil

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let badge {
                        Text(badge)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color(.systemGray5)))
                    }
                    Text(title).font(.subheadline)
                    Spacer()
                    if let date {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !snippet.isEmpty {
                    // 全仓审查 2026-09-18（F-A8-01）：经 SnippetText 单一出口拆段加粗，
                    // `<b>` 标记不再字面渲染
                    SnippetText(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 2)
        }
    }
}
