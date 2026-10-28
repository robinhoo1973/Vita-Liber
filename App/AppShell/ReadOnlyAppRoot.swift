import SwiftUI
import Domain
import Infrastructure
import Perception

/// 只读降级壳（2026-10-28 只读降级 B2 骨架 → B3 页面：急救卡只读）。
///
/// 环境装配：`AppState` + `M2HubStore` 由只读容器直造（参数同 AppSession.init）；
/// 急救卡视图沿用既有 `readOnly` 形态（2026-09-18 审查既有参数——无管理/选择器
/// 入口），页面自足加载（`.task(id:)` → `hub.load`）。Timeline/文档只读页拆
/// B3.1 后续批（需 TimelineViewState/DocumentsState/路由等更多环境）。
///
/// 零写纪律：容器由 `AppContainer.readOnly` 装配（no-op 调度器、无切片 facade/
/// checker/updater/通告面、无会话/holder）；本壳不挂任何写入口，只读 store。
struct ReadOnlyAppRoot: View {
    let container: AppContainer
    @State private var appState: AppState
    @State private var m2Hub: M2HubStore

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
                    EmergencyCardHubView(readOnly: true)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("READONLY.emergency")
                }
                .navigationTitle(L10n.startupReadonlyTitle)
            }
            .environment(appState)
            .environment(m2Hub)
            .tintedCanvas()
            // 容器标识必须配 .contain 才能与子元素共存（L0 第 17 节）。
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("READONLY.root")
        }
    }
}
