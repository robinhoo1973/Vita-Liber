import SwiftUI
import Domain
import Protocols
import Infrastructure

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
@Observable
final class SearchViewState {
    private(set) var query = ""
    private(set) var docHits: [EntityReference] = []
    private(set) var loading = false
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
        loading = true
        defer { loading = false }
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
        return hub.inventoryItems.filter {
            $0.medicationName.localizedCaseInsensitiveContains(query)
                || ($0.spec ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private var allEmpty: Bool {
        state.docHits.isEmpty && observationHits.isEmpty && medicationHits.isEmpty
    }

    var body: some View {
        // 第八轮全仓审查修复（每帧重复计算）：observationHits 对全量观察
        // 事件做 flatMap+两次本地化子串过滤+排序，medicationHits 同族——
        // 原实现每帧 body 求值各算两遍（allEmpty 一遍 + 分区一遍）。改为
        // 每帧求值一次的局部常量，两次消费同一结果。
        let obsHits = observationHits
        let medHits = medicationHits
        return List {
            if query.isEmpty {
                ContentUnavailableView(L10n.searchTitle, systemImage: "magnifyingglass",
                                       description: Text(L10n.searchPlaceholderHint))
                    .accessibilityIdentifier("SP-20.search.idle")
            } else if state.loadFailed {
                // 四态纪律：检索失败独立呈现（不冒充「未找到」）
                ContentUnavailableView {
                    Label(L10n.searchLoadFailed, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(L10n.searchLoosenHint)
                } actions: {
                    Button(L10n.searchRetry) {
                        Task { await state.search(patientId: app.currentPatientId) }
                    }
                }
                .accessibilityIdentifier("SP-20.search.failed")
            } else if state.docHits.isEmpty && obsHits.isEmpty && medHits.isEmpty {
                ContentUnavailableView {
                    Label(L10n.searchNoResult(query), systemImage: "magnifyingglass")
                } description: {
                    Text(L10n.searchLoosenHint)
                } actions: {
                    Button(L10n.searchClear) { filterText = "" }
                }
                .accessibilityIdentifier("SP-20.search.empty")
            } else {
                if !state.docHits.isEmpty {
                    Section(L10n.searchGroupDocs) {
                        ForEach(state.docHits, id: \.refID) { hit in
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
                if !obsHits.isEmpty {
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
                                                    snippet: nil, badge: nil,
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
                if !medHits.isEmpty {
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
        .onChange(of: state.injectedQuery) { _, injected in
            // 第八轮全仓审查修复（栈顶去重下的语音搜索）：搜索页已是 AI
            // Tab 栈顶时 router 去重守卫把「搜索 X」变成静默 no-op——注入词
            // 滞留共享状态，直到下次新开搜索页才被 onAppear 消费（陈旧词
            // 劫持一次无关搜索）。注入词变化即就地消费：更新输入框并触发
            // 既有防抖检索，任何路径都即时生效。
            guard let injected, injected != filterText else { return }
            filterText = injected
            _ = state.consumeInjectedQuery()
        }
        .task(id: app.currentPatientId) {
            await hub.load(patientId: app.currentPatientId)
            await observationState.load(patientId: app.currentPatientId)
        }
        .onChange(of: filterText) { _, newValue in
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
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
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
