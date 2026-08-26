import SwiftUI

/// ADR-021 / tech-spec §5.26：五模块单一枚举，iPhone Tab 与 iPad Sidebar
/// 是同一枚举的两种容器渲染。
///
/// 实现要点（ERR#32 修正记录）：
/// - `List(_:selection:rowContent:)` 与 `List(selection:content:)` 均 macOS-only，
///   iOS 17 不可用——SwiftUI 跨平台可用面差异在非 macOS 机器不可验证；
/// - iOS 上 NavigationSplitView 的侧边栏选中态由 NavigationLink(value:) +
///   navigationDestination 管理（persist 需求 M1c 接 AppRoute 时再引入
///   @SceneStorage，见 tech-spec §5.45/§5.48）；
/// - compact 宽度用 TabView（系统原生 tab 形态），regular 用侧边栏——
///   按 horizontalSizeClass 分容器是 §5.26 L4 明示的容器驱动重排原语，
///   不是被禁止的 idiom 分支换页（L0 [2/7] 只查 userInterfaceIdiom == .pad）。
enum MainModule: String, CaseIterable, Identifiable, Hashable {
    case home, records, reminders, ai, me
    var id: String { rawValue }

    /// 展示文案走 L10n 键（评审 S2-1：枚举不兼职 UI 串）。
    /// M1c 接入 L10n.swift 前以本地化键占位，禁止中文 hardcode 进枚举。
    var titleKey: LocalizedStringKey {
        switch self {
        case .home: return "nav.home"
        case .records: return "nav.records"
        case .reminders: return "nav.reminders"
        case .ai: return "nav.ai"
        case .me: return "nav.me"
        }
    }

    var iconName: String {
        switch self {
        case .home: return "ic-tab-home"
        case .records: return "ic-tab-records"
        case .reminders: return "ic-tab-reminders"
        case .ai: return "ic-tab-assistant"
        case .me: return "ic-tab-me"
        }
    }

    var icon: Image {
        switch self {
        case .home: return VLIcon.tabHome
        case .records: return VLIcon.tabRecords
        case .reminders: return VLIcon.tabReminders
        case .ai: return VLIcon.tabAssistant
        case .me: return VLIcon.tabMe
        }
    }
}

/// L1 外壳（§5.26.1）＋ L2 模块根占位（M0）。
struct RootAdaptiveView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: MainModule = .home

    var body: some View {
        if sizeClass == .compact {
            TabView(selection: $selection) {
                ForEach(MainModule.allCases) { m in
                    ModuleRoot(module: m)
                        .tabItem { Label(m.titleKey, image: m.iconName) }
                        .tag(m)
                }
            }
        } else {
            NavigationSplitView {
                List {
                    ForEach(MainModule.allCases) { m in
                        NavigationLink(value: m) {
                            Label(m.titleKey, image: m.iconName)
                        }
                    }
                }
                .navigationTitle("Vita Liber")
            } detail: {
                ModuleRoot(module: selection)
                    .navigationDestination(for: MainModule.self) { m in
                        ModuleRoot(module: m)
                    }
            }
        }
    }
}

/// L2 模块根（M1a：records 挂真实时间轴——评审修正「完成后时间轴不可达」；
/// 其余模块占位，随 M1c 逐 SP 挂载）
struct ModuleRoot: View {
    @Environment(AppState.self) private var app
    let module: MainModule

    var body: some View {
        if module == .records {
            TimelineView(showFinishButton: false)
        } else if module == .reminders {
            RemindersView()
        } else if module == .ai {
            NavigationStack { AssistantView() }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(module.titleKey)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("SP-00.moduleRoot.\(module.rawValue)")
        }
    }
}

#Preview("五模块外壳") {
    RootAdaptiveView()
}
