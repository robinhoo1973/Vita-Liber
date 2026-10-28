import SwiftUI
import Domain
import Infrastructure
import Perception

/// 只读降级壳（2026-10-28 只读降级 B2 骨架 → B3 急救卡只读 → B3.1 时间线只读）。
///
/// 环境装配：`AppState` + `M2HubStore` + `TimelineViewState` + `AppDataChangeCenter` +
/// `AppRouter` 由只读容器直造（AppSession.init 同参；router/dataChange 为轻量内存件）。
/// 页面：急救卡沿用既有 `readOnly` 形态；时间线为**自建只读列表**——只复用纯行组件
/// （`TimelineHubRowView`/`TimelineChildRowView`，零 `@Environment`），不做跨页钻取
/// （详情链视图的环境闭包未证，B3.2+ 再议）。文档页需 OCRPipeline 装配，后批。
///
/// 零写纪律：容器由 `AppContainer.readOnly` 装配（no-op 调度器、无切片 facade/
/// checker/updater/通告面、无会话/holder）；本壳不挂任何写入口，只读 store。
struct ReadOnlyAppRoot: View {
    let container: AppContainer
    @State private var appState: AppState
    @State private var m2Hub: M2HubStore
    @State private var timelineState: TimelineViewState
    @State private var dataChange: AppDataChangeCenter = AppDataChangeCenter()
    @State private var router: AppRouter = AppRouter()

    init(container: AppContainer) {
        self.container = container
        _appState = State(initialValue: AppState(
            persistor: container.persistor,
            audit: container.audit,
            memberDeletion: container.memberDeletion,
            codeIndex: container.codeIndex,
            lexiconSource: container.codeIndex))
        _m2Hub = State(initialValue: M2HubStore(
            meds: container.meds, emergency: container.emergencyCards,
            immunizations: container.immunizations,
            messages: container.messages, guidelines: container.guidelines,
            audit: container.audit))
        _timelineState = State(initialValue: TimelineViewState(
            store: container.timelineQuery, problemStore: container.healthProblems))
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                VStack(spacing: 0) {
                    Label(L10n.startupReadonlyBanner, systemImage: "lock.doc")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(Color("semantic-warning", bundle: .main).opacity(0.12))
                        .accessibilityIdentifier("READONLY.banner")
                    NavigationLink {
                        ReadOnlyTimelineView()
                            .navigationTitle(L10n.timelineTitle)
                    } label: {
                        HStack {
                            Label(L10n.timelineTitle, systemImage: "clock.arrow.circlepath")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("READONLY.timeline.link")
                    Divider()
                    EmergencyCardHubView(readOnly: true)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("READONLY.emergency")
                }
                .navigationTitle(L10n.startupReadonlyTitle)
            }
            .environment(appState)
            .environment(m2Hub)
            .environment(timelineState)
            .environment(dataChange)
            .environment(router)
            .tintedCanvas()
            // 容器标识必须配 .contain 才能与子元素共存（L0 第 17 节）。
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("READONLY.root")
        }
    }
}

/// 时间线只读列表（B3.1）：只复用纯行组件；主卡行可展开子行（详情按钮即展开切换），
/// 不跨页钻取（详情链环境闭包未证——B3.2+ 再议）。
private struct ReadOnlyTimelineView: View {
    @Environment(AppState.self) private var app
    @Environment(TimelineViewState.self) private var state
    @State private var expanded: Set<String> = []

    var body: some View {
        WithPerceptionTracking {
            List {
                ForEach(state.visibleHubs) { item in
                    if let hub = item.hub {
                        DisclosureGroup(isExpanded: expansionBinding(item.id)) {
                            ForEach(item.children) { child in
                                TimelineChildRowView(entry: child)
                            }
                        } label: {
                            TimelineHubRowView(item: item, hub: hub,
                                               onOpen: { toggle(item.id) })
                        }
                    } else {
                        TimelineChildRowView(entry: item.entry)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if state.visibleHubs.isEmpty {
                    Text(L10n.timelineEmptyTitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .task { await state.load(patientId: app.currentPatientId) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("READONLY.timeline")
        }
    }

    private func expansionBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { isOn in toggle(id, force: isOn) })
    }

    private func toggle(_ id: String, force: Bool? = nil) {
        let target = force ?? !expanded.contains(id)
        if target { expanded.insert(id) } else { expanded.remove(id) }
    }
}
