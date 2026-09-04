import SwiftUI
import Domain   // MainModuleID（AppRoute 路由所属 Tab）
import Protocols   // InMemoryReminderScheduler（Preview 装配）

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

    /// 展示文案走 L10n 单出口（评审 S2-1：枚举不兼职 UI 串）。
    /// 返回已解析的本地化串（L10n.navHome 等）——Label 直接消费，
    /// 避免原始 key 字面量散落枚举、绕开 Localization/L10n.swift 纪律。
    var title: String {
        switch self {
        case .home: return L10n.navHome
        case .records: return L10n.navRecords
        case .reminders: return L10n.navReminders
        case .ai: return L10n.navAI
        case .me: return L10n.navMe
        }
    }

    /// Tab/侧边栏字形（V3.35，TestFlight 实测）：设计库 ic-tab-* 瓷砖为带背景 pad 的
    /// app-icon 式图形（@1x 48pt，@2x 母版 96px），放进 tab 栏会与文字标签互相挤压
    /// 致其截断——改回系统 SF Symbols 线条字形，随选中态自动着色。注意：这只修复
    /// 默认字号下的图标挤压；辅助功能超大字号（AX）下 Tab 标签仍可能被系统截断，
    /// 属系统 Tab 栏行为，非本字形回归。瓷砖图形保留于设计资源库（design/icons，
    /// ui-ux-spec V3.35「保留不删」）供未来模块内大尺寸场景复用，当前无代码消费。
    var systemGlyph: String {
        switch self {
        case .home: return "house"
        case .records: return "folder"
        case .reminders: return "bell"
        case .ai: return "sparkles"
        case .me: return "person"
        }
    }
}

/// L1 外壳（§5.26.1）＋ L2 模块根占位（M0）。
struct RootAdaptiveView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(ReminderStore.self) private var reminderStore
    @Environment(AppRouter.self) private var router
    @SceneStorage("selectedModule") private var selection: MainModule = .home

    var body: some View {
        // 容器驱动重排（ADR-021）：compact=TabView、regular=侧边栏。
        // 外层包 Group 再挂统一修饰器——if/else 两个分支类型的并集上
        // 直接调 View 扩展方法有类型歧义（CI 编译错：instance member
        // 'withPaywallHost' cannot be used on type 'View'）
        Group {
        if sizeClass == .compact {
            TabView(selection: $selection) {
                ForEach(MainModule.allCases) { m in
                    // 每个 tab 自带导航栈。放在这里而不是 ModuleRoot 内部：
                    // ModuleRoot 为两种 idiom 共用（ADR-021 单一内容视图），
                    // 若在其内部无条件包 NavigationStack，iPad 详情列会在
                    // NavigationSplitView 已提供的导航上下文里再套一层嵌套栈。
                    // §5.45：栈绑定 AppRouter 对应 path + 全量路由目的地分发表
                    NavigationStack(path: router.binding(for: MainModuleID(m))) {
                        ModuleRoot(module: m)
                            .navigationDestination(for: AppRoute.self) { route in
                                RouteDestinationView(route: route)
                            }
                    }
                    .tabItem { Label(m.title, systemImage: m.systemGlyph) }
                    .tag(m)
                    // FR14.8/SP-27: Unread badge on reminders tab
                    .badge(m == .reminders ? reminderStore.pendingCount : 0)
                }
            }
        } else {
            NavigationSplitView {
                List {
                    ForEach(MainModule.allCases) { m in
                        NavigationLink(value: m) {
                            Label(m.title, systemImage: m.systemGlyph)
                        }
                        // §11-14：iPad 侧边栏补未读角标（compact 已有）
                        .badge(m == .reminders && reminderStore.pendingCount > 0
                               ? reminderStore.pendingCount : 0)
                    }
                }
                .navigationTitle(L10n.help_appName)
            } detail: {
                NavigationStack(path: router.binding(for: MainModuleID(selection))) {
                    ModuleRoot(module: selection)
                        .navigationDestination(for: AppRoute.self) { route in
                            RouteDestinationView(route: route)
                        }
                }
                .navigationDestination(for: MainModule.self) { m in
                    // 评审修正：侧边栏推入后回写 selection——
                    // ① 旋转至 compact 时 TabView 落在用户最后所在的模块，不再丢上下文回首页；
                    // ② 详情列弹出后回到根时，根视图 = 最后所选模块而非恒 .home。
                    // 异步延后一拍写：onAppear 期间直接写导航驱动状态属再入（重复 push 风险）。
                    ModuleRoot(module: m)
                        .onAppear { DispatchQueue.main.async { selection = m } }
                }
            }
        }
        }
        .withPaywallHost()   // 五时机弹墙统一宿主（comercial §3 / M2 收尾）
        // FR18.6 右下角常驻 SOS 悬浮球（仅关怀模式；可半透明；设置可关闭——
        // 悬浮球被关闭后关怀首页「呼救」大卡仍保留，求助能力不因单一开关消失）
        .overlay(alignment: .bottomTrailing) {
            if appState.careMode && careSettingsSOSOrbVisible {
                SOSOrb()
                    .padding(16)
                    .accessibilityIdentifier("F18.sos.orb")
            }
        }
    }

    @Environment(AppState.self) private var appState
    @AppStorage("vl.care.sosOrbVisible") private var careSettingsSOSOrbVisible = true
}

extension MainModuleID {
    init(_ m: MainModule) {
        switch m {
        case .home: self = .home
        case .records: self = .records
        case .reminders: self = .reminders
        case .ai: self = .ai
        case .me: self = .me
        }
    }
}

/// L2 模块根（M1a：records 挂真实时间轴——评审修正「完成后时间轴不可达」；
/// 其余模块随 M1c 已挂载真实视图）
struct ModuleRoot: View {
    @Environment(AppState.self) private var app
    let module: MainModule

    var body: some View {
        // 评审修正：if/else 链的末尾 else 兼作 .home 兜底——新增枚举 case 时会
        // 静默渲染首页占位。显式 switch 无 default：MainModule 新增 case 即编译错，
        // 强制为每个模块显式挂载视图。
        switch module {
        case .records:
            // 导航栈由外层提供（iPhone: 每个 tab 一个；iPad: NavigationSplitView 详情列），
            // 此处不得再包，否则 iPad 出现嵌套栈。
            // FR11.1-11.4：八类事件联合查询时间轴（SP-19 全量）
            TimelineFullView()
        case .reminders:
            RemindersView()
        case .ai:
            AssistantView()
        case .me:
            SettingsView()
        case .home:
            // F2 首页八卡（SP-04）；F19 关怀语音入口卡随关怀模式版式呈现
            HomeView()
        }
    }
}

#Preview("五模块外壳") {
    PreviewRoot()
}

/// 预览装配容器（评审修正）：PaywallHost 读 AppEntitlementStore、ModuleRoot 读 AppState——
/// 两者均未注入时预览渲染即崩（"No Observable object of type ... found"），
/// 此前预览实际不可用。#Preview 宏的 PreviewMacroBodyBuilder 不接受 do/catch 等
/// 控制流语句（CI 编译错：no exact matches in call to macro 'Preview'），
/// 装配必须移出预览闭包，落在专用视图的 init 中。
private struct PreviewRoot: View {
    private let container: AppContainer
    private let appState: AppState

    init() {
        // 与 VitaLiberApp 同构装配：内存库 + 内存调度器，仅 live 路径换成 preview。
        let assembled: AppContainer
        do {
            assembled = try AppContainer.preview()
        } catch {
            fatalError("Preview container assembly failed (in-memory DB unavailable): \(error)")
        }
        container = assembled
        appState = AppState(persistor: assembled.persistor,
                            capture: FakeOcrProvider(fixture: false))
    }

    var body: some View {
        RootAdaptiveView()
            .environment(appState)
            .environment(ReminderStore(meds: container.meds, apts: container.apts,
                                       reconciler: container.reconciler,
                                       scheduler: InMemoryReminderScheduler(),
                                       composer: container.composer))
            .environment(AssistantStore(provider: container.aiProvider))
            .environment(AppSettingsStore(store: container.settings))
            .environment(ObservationStoreState(store: container.observations,
                                               allergyStore: container.allergies,
                                               mediaAssets: container.mediaAssets))
            .environment(AppEntitlementStore(store: container.entitlements))
            .environment(TrendEntryState(store: container.trends))
            .environment(VoiceNoteState(store: container.voiceNotes))
            .environment(M2HubStore(meds: container.meds,
                                    emergency: container.emergencyCards,
                                    immunizations: container.immunizations,
                                    claims: container.claims,
                                    messages: container.messages,
                                    guidelines: container.guidelines,
                                    audit: container.audit))
            .environment(container.mediaSession)
            .environment(AppRouter())
            .environment(SearchViewState(search: container.search))
            .environment(EncountersState(store: container.encounters))
            .environment(TimelineViewState(store: container.timelineQuery,
                                           problemStore: container.healthProblems))
            .environment(QuestionsState(store: container.questions))
    }
}
