import SwiftUI

/// ADR-021 / tech-spec §5.26：五模块单一枚举，iPhone Tab 与 iPad Sidebar
/// 是同一枚举的两种容器渲染——导航外壳统一为 NavigationSplitView，
/// compact 宽度下系统自动折叠为 tab 形态，不写 idiom 分支。
enum MainModule: String, CaseIterable, Identifiable {
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

/// L1 外壳（§5.26.1）：compact → Tab 形态；regular → 侧边栏 + 详情。
/// L2 模块根：每 SP 恰一个内容视图，M0 阶段为占位（M1a 起逐 SP 替换）。
struct RootAdaptiveView: View {
    @State private var selection: MainModule = .home

    var body: some View {
        NavigationSplitView {
            // List(_, selection:, rowContent:) 是 macOS-only；iOS 用 List(selection:)
            // + ForEach + .tag（ADR-021：compact 宽度下系统自动折叠为 tab 形态）
            List(selection: $selection) {
                ForEach(MainModule.allCases) { m in
                    Label(m.titleKey, image: iconName(m)).tag(m)
                }
            }
            .navigationTitle("Vita Liber")
        } detail: {
            ModuleRoot(module: selection)
        }
    }

    private func iconName(_ m: MainModule) -> String {
        switch m {
        case .home: return "ic-tab-home"
        case .records: return "ic-tab-records"
        case .reminders: return "ic-tab-reminders"
        case .ai: return "ic-tab-assistant"
        case .me: return "ic-tab-me"
        }
    }
}

/// L2 模块根占位（M0）。M1a 起按 tech-spec §5.26.3 逐 SP 挂载真实内容视图。
struct ModuleRoot: View {
    let module: MainModule

    var body: some View {
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

#Preview("五模块外壳") {
    RootAdaptiveView()
}
