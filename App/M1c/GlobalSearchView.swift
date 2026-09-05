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

    private let search: any FullTextSearch
    init(search: any FullTextSearch) { self.search = search }

    func setQuery(_ q: String) { query = q }

    func search(patientId: UUID) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        loading = true
        defer { loading = false }
        guard !trimmed.isEmpty else {
            docHits = []
            return
        }
        do {
            docHits = try await search.search(trimmed,
                                              scope: DataAccessScope(patientIds: [patientId]),
                                              limit: 30)
        } catch {
            docHits = []   // 检索失败 = 空结果 + 降级建议（F22 边界：不阻塞）
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
        List {
            if query.isEmpty {
                ContentUnavailableView(L10n.searchTitle, systemImage: "magnifyingglass",
                                       description: Text(L10n.searchPlaceholderHint))
                    .accessibilityIdentifier("SP-20.search.idle")
            } else if allEmpty {
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
                                SearchResultRow(title: hit.title, snippet: hit.snippet,
                                                badge: hit.isSensitive ? L10n.searchSensitive : nil,
                                                date: nil)
                            }
                            .accessibilityIdentifier("SP-20.search.doc.\(hit.refID.uuidString)")
                        }
                    }
                }
                if !observationHits.isEmpty {
                    Section(L10n.searchGroupObservations) {
                        ForEach(observationHits) { obs in
                            Button {
                                router.navigate(to: .observationDetail(obs.id))
                            } label: {
                                // BR-007/008：敏感观察命中仍以锁定媒体态呈现
                                SearchResultRow(title: obs.description ?? L10n.observationKindName(obs.kind),
                                                snippet: L10n.searchObsLocked,
                                                badge: L10n.searchSensitive,
                                                date: obs.occurredAt)
                            }
                            .accessibilityIdentifier("SP-20.search.obs.\(obs.id.uuidString)")
                        }
                    }
                }
                if !medicationHits.isEmpty {
                    Section(L10n.searchGroupMeds) {
                        ForEach(medicationHits) { item in
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
        .task(id: app.currentPatientId) {
            await hub.load(patientId: app.currentPatientId)
            await observationState.load(patientId: app.currentPatientId)
        }
        .onChange(of: filterText) { _, newValue in
            state.setQuery(newValue)
            Task { await state.search(patientId: app.currentPatientId) }
        }
    }
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
