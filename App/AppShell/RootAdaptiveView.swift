import SwiftUI
import Domain   // MainModuleID（AppRoute 路由所属 Tab）
import Protocols // EngineRegistry（EAL 引擎注册表抽象）
import Infrastructure   // Preview 装配直连适配器：OCRPipeline/OCRRecognizerFactory/GrayscaleImageDecoder
import Perception
// （App 层是组装根，与 AppContainer 同权接 Infrastructure——架构图 App(组装根) → Infrastructure）

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
    case home, records, reminders, health, me
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return L10n.navHome
        case .records: return L10n.navRecords
        case .reminders: return L10n.navReminders
        case .health: return L10n.navHealth
        case .me: return L10n.navMe
        }
    }

    var systemGlyph: String {
        switch self {
        case .home: return "house"
        case .records: return "folder"
        case .reminders: return "bell"
        case .health: return "heart.text.clipboard"
        case .me: return "person"
        }
    }
}

/// L1 外壳（§5.26.1）＋ L2 模块根占位（M0）。
struct RootAdaptiveView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ReminderStore.self) private var reminderStore
    @Environment(AppRouter.self) private var router
    @Environment(MediaUnlockSession.self) private var mediaSession

    /// 选中模块由 AppRouter 单一状态源驱动（TestFlight 实测：SceneStorage 与
    /// navigate 双源分离导致跨 Tab 路由只 append 不切 Tab、点击无反应）。
    /// SceneStorage 持久化并入 router 的 defaults 持久化（§5.48 同族）。
    private var selection: Binding<MainModule> {
        Binding(
            get: { MainModule(tabID: router.selection) },
            set: { router.select(MainModuleID(rawValue: $0.rawValue) ?? .home) })
    }

    /// 单 tab 内容（2026-10-04 拆出：TabView 巨型表达式在慢 runner 上触发
    /// 类型检查预算超时——CI #648「unable to type-check in reasonable time」；
    /// 与 regularSidebar 同族拆分纪律）。
    @ViewBuilder
    private func moduleTab(_ m: MainModule) -> some View {
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

    /// iPad 详情列导航栈（同族拆分：与 compact 分支共享同一栈形态）。
    @ViewBuilder
    private func moduleStack(_ selection: Binding<MainModule>) -> some View {
        NavigationStack(path: router.binding(for: MainModuleID(selection.wrappedValue))) {
            ModuleRoot(module: selection.wrappedValue)
                .navigationDestination(for: AppRoute.self) { route in
                    RouteDestinationView(route: route)
                }
        }
    }

    /// 侧栏单选绑定（iPad regular）：`List(selection:)` 要求 `Optional<SelectionValue>`，
    /// 而模块选中态是单一状态源（`selection` ← router）。此处只做 Optional 适配——
    /// 取消选择（点侧栏空白）**不回写**，保持当前模块，避免详情列被清空成占位。
    private var sidebarSelection: Binding<MainModule?> {
        Binding(
            get: { selection.wrappedValue },
            set: { if let new = $0 { selection.wrappedValue = new } })
    }

    /// 侧栏（2026-09-20 拆出：body 类型检查 1261ms 超预算，分支体移出主表达式）。
    private var regularSidebar: some View {
        // 侧栏用 `List(selection:)` 驱动，**不是** `NavigationLink(value:)`——
        // 业主 2026-09-16 iPad 实测「无法切换到其他页面」的根因：
        // 侧栏**没有自己的 NavigationStack**（下面的栈属于 detail 列），
        // `NavigationLink` 无处可推，点击静默无效；原先补偿性的
        // `.navigationDestination(for: MainModule.self)` 挂在 detail 列的栈上，
        // 同样接不到侧栏的行选择。选中态改由 `selection` 单源驱动，
        // detail 列随 `selection` 换根——与 compact 分支的 TabView 同源同语义。
        List(selection: sidebarSelection) {
            ForEach(MainModule.allCases) { m in
                // ForEach 行闭包逃逸：行内同步读感知对象属性，须自行包裹（子项目 I）
                WithPerceptionTracking {
                    Label(m.title, systemImage: m.systemGlyph)
                        // §11-14：iPad 侧边栏补未读角标（compact 已有）
                        .badge(m == .reminders && reminderStore.pendingCount > 0
                               ? reminderStore.pendingCount : 0)
                        .tag(m)
                }
            }
        }
        .navigationTitle(L10n.help_appName)
    }

    var body: some View {
        WithPerceptionTracking {
            // 容器驱动重排（ADR-021）：compact=TabView、regular=侧边栏。
            // 外层包 Group 再挂统一修饰器——if/else 两个分支类型的并集上
            // 直接调 View 扩展方法有类型歧义（CI 编译错：instance member
            // 'withPaywallHost' cannot be used on type 'View'）
            Group {
            if sizeClass == .compact {
                TabView(selection: selection) {
                    ForEach(MainModule.allCases) { m in
                        // ForEach 行闭包逃逸：行内同步读感知对象属性，须自行包裹（子项目 I）
                        WithPerceptionTracking {
                            moduleTab(m)
                        }
                    }
                }
            } else {
                NavigationSplitView {
                    regularSidebar
                } detail: {
                    moduleStack(selection)
                }
            }
            }
            .withPaywallHost()   // 五时机弹墙统一宿主（comercial §3 / M2 收尾）
            // 评审修正第二轮（会话令牌退后台）：MediaUnlockSession.onBackground 此前
            // 零调用方——展示模式等会话级解锁退后台不重锁（BR-007 快照防护缺口）；
            // 逐视图的 SensitiveMediaContainer/OriginalView 已自行重锁，此处补
            // 会话级统一钩子（含 300s showcase 会话的退后台终止）。
            .onChangeCompat(of: scenePhase) { _, phase in
                // 2026-10-03 评审修复（展示模式「认证成功即秒回锁」）：
                // background = 真离开恒立即重锁（BR-007 不松）；
                // inactive 可能是**认证浮层自身**的瞬态——在途认证
                // （authPromptInFlight）或宽限窗内不得杀会话，与媒体链
                // 三视图同纪律（MediaUnlockPolicy.shouldRelockOnInactive）。
                if phase == .background {
                    mediaSession.onBackground()
                } else if phase != .active,
                          !appState.authPromptInFlight,
                          MediaUnlockPolicy.shouldRelockOnInactive(
                            lastUnlockAt: mediaSession.lastUnlockedAt ?? Date(), now: Date()) {
                    mediaSession.onBackground()
                }
            }
            // 导航外壳挂载钩子：挂载后才允许恢复持久化 path / 投递暂存的通知路由。
            // 2026-09-19 修正：锁门禁已由分支替换改为根级 fullScreenCover 覆盖层，
            // 本视图冷启动即挂载（锁屏之下），markNavigationReady 会在锁定期间
            // 放行（幂等且内部再延一拍——挂载帧提交后才 push，避开 iOS 26 转场
            // 环境断言，TestFlight 2026-09-05 crash 2 根因修正）。markNavigationSuspended
            // 仅剩外壳卸载（onboarding 分支互换）路径生效。
            .onAppear {
                Task { @MainActor in router.markNavigationReady() }
            }
            // 卸载钩子（markNavigationSuspended）挂在 AppRootView 的 RootAdaptiveView()
            // 调用点而非本 Group——本处修饰符逐子视图生效：iPad 旋转 compact↔regular
            // 分支互换、相机/语音/SOS 等 fullScreenCover 盖住外壳都会触发 onDisappear，
            // 挂在本处会把「外壳已卸载」误判成覆盖/换分支瞬间，通知深链被滞留
            // pendingRoutes 至覆盖层消失（第十一轮审查修正）。
            // FR18.6 右下角常驻 SOS 悬浮球（仅关怀模式；可半透明；设置可关闭——
            // 悬浮球被关闭后关怀首页「呼救」大卡仍保留，求助能力不因单一开关消失）
            .overlay(alignment: .top) { InAppBannerHost() }   // §4.22 前台到期横幅（V3.72）
            // S-1（第九轮审查 U1#6，ui-ux §7.1「手势降级：每页必有等效大号返回钮
            // ≥64pt 常驻左上」）：关怀模式此前只有系统 ~44pt 返回箭头 + 边缘右滑
            // （纯手势路线对震颤用户不可达）。栈深 > 0 时渲染 64×64 常驻返回钮；
            // 栈空（模块根）无返回语义不渲染。onCompletion 后由 router.pop 出栈。
            .overlay(alignment: .topLeading) {
                if appState.careMode, let topRoute = careTopRoute {
                    Button {
                        router.pop(topRoute)
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.title3.bold())
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(.ultraThinMaterial))
                            .contentShape(Circle())
                    }
                    .accessibilityLabel(L10n.commonBack)
                    .accessibilityIdentifier("care.back")
                    .padding(.leading, 8)
                    .padding(.top, 8)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if appState.careMode && careSettingsSOSOrbVisible {
                    SOSOrb()
                        .padding(.trailing, 16)
                        // V4.06：此前贴底 16pt——悬浮球压在 Tab 栏右端、遮挡导航按钮
                        // （业主实测）；让出 Tab 栏 + home indicator（≈88pt）
                        .padding(.bottom, 92)
                        .accessibilityIdentifier("F18.sos.orb")
                }
            }
        }
    }

    @Environment(AppState.self) private var appState
    @AppStorage("vl.care.sosOrbVisible") private var careSettingsSOSOrbVisible = true

    /// S-1：当前 Tab 栈顶路由（关怀返回钮的存在性判据；栈空 nil）。
    private var careTopRoute: AppRoute? {
        router.binding(for: router.selection).wrappedValue.last
    }
}

extension MainModuleID {
    init(_ m: MainModule) {
        switch m {
        case .home: self = .home
        case .records: self = .records
        case .reminders: self = .reminders
        case .health: self = .health
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
        WithPerceptionTracking {
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
            case .health:
                HealthTabView()
            case .me:
                SettingsView()
            case .home:
                // F2 首页八卡（SP-04）；F19 关怀语音入口卡随关怀模式版式呈现
                HomeView()
            }
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
    /// 与 VitaLiberApp 同构：单实例数据变更信号——首页/趋势/通知中心/证据页
    /// 均按 `@Environment(AppDataChangeCenter.self)` 读取，缺注入即断言崩溃。
    private let dataChange = AppDataChangeCenter()
    /// 预览同构：安装中心与生产同源（页面 .environment(ASRInstallCenter.self) 依赖）。
    private let asrInstallCenter: ASRInstallCenter
    /// 预览同构（2026-10-09 换型+下载化批）：T2 模型安装中心同源注入。
    private let llmModelInstallCenter: LLMModelInstallCenter
    /// 设置仓（业主 2026-09-17：F16DeviceState 构造与环境注入共用同一实例——
    /// 此前 body 内联新建 AppSettingsStore，F16DeviceState 拿不到同一仓）。
    private let settingsStore: AppSettingsStore
    private let medicalCatalogState: MedicalCatalogState
    /// P3（2026-10-07）：预览同构——provider 缺省（preview 装配默认 nil）→
    /// 读取后呈「不可用」，fail-closed 路径可视。
    private let updateAdviceState: UpdateAdviceState
    /// 统一更新中心批（2026-10-07）：预览同构——ASR 检查态 + 中心编排。
    private let asrCheckState: ASRIndexCheckState
    private let updateCenterState: UpdateCenterState

    init() {
        // 与 VitaLiberApp 同构装配：内存库 + 内存调度器，仅 live 路径换成 preview。
        // 局部常量中转（同款 definite-initialization 纪律）：后续对象构造引用它们，
        // 不触 self 属性访问。
        let installCenter = ASRInstallCenter(dataChange: dataChange)
        asrInstallCenter = installCenter
        llmModelInstallCenter = LLMModelInstallCenter(dataChange: dataChange)
        let assembled: AppContainer
        do {
            assembled = try AppContainer.preview()
        } catch {
            fatalError("Preview container assembly failed (in-memory DB unavailable): \(error)")
        }
        container = assembled
        let medicalState = MedicalCatalogState(store: assembled.medicalCatalog,
                                               updater: assembled.medicalCatalogUpdater,
                                               checker: assembled.medicalCatalogChecker,
                                               opener: assembled.medicalCatalogOpener)
        medicalCatalogState = medicalState
        appState = AppState(persistor: assembled.persistor)
        settingsStore = AppSettingsStore(store: assembled.settings)
        let adviceState = UpdateAdviceState(provider: assembled.updateAdvice)
        updateAdviceState = adviceState
        // 统一更新中心批（2026-10-07）：ASR 检查态 + 中心编排（与生产同构）。
        let checkState = ASRIndexCheckState(
            isInstallActive: { installCenter.active.contains { !$0.isPaused } })
        asrCheckState = checkState
        updateCenterState = UpdateCenterState(
            advice: adviceState,
            chains: [.asrModels: checkState, .medicalData: medicalState])
    }

    var body: some View {
        WithPerceptionTracking {
            RootAdaptiveView()
                .environment(appState)
                .environment(ReminderStore(meds: container.meds, apts: container.apts,
                                           reconciler: container.reconciler,
                                           // 预览与生产同构：统一经组装根单实例调度器
                                           // （此前此处 new 新实例——reconciler 排程落在
                                           // assemble 注入的实例 A，本 store 经实例 B，
                                           // 对账/取消互不可见，预览无法充当接线回归探针）
                                           scheduler: container.reminderScheduler,
                                            composer: container.composer))
                .environment(settingsStore)
                .environment(medicalCatalogState)
                .environment(updateAdviceState)
                .environment(asrCheckState)
                .environment(updateCenterState)
                .environment(ObservationStoreState(store: container.observations,
                                                   allergyStore: container.allergies,
                                                   mediaAssets: container.mediaAssets))
                .environment(AppEntitlementStore(store: container.entitlements))
                .environment(TrendEntryState(store: container.trends, audit: container.audit))
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
                .environment(HealthExamViewState(store: container.healthExams))
                .environment(TimelineViewState(store: container.timelineQuery,
                                               problemStore: container.healthProblems))
                .environment(QuestionsState(store: container.questions))
                // 评审修正：与 VitaLiberApp.mainRoot 的 21 项注入对齐——此前缺 6 项，
                // Preview 一旦导航到通知中心/资料详情/导出向导/备份/设备/历史页即
                // 命中「No Observable object found」断言（与 build-147 同类崩溃，
                // 且 Preview 无法充当该崩溃族的回归探针）。预览禁触生产目录：
                // originalsDir 用临时目录，调度器用内存桩。
                .environment(dataChange)
                .environment(asrInstallCenter)
                .environment(llmModelInstallCenter)
                .environment(container.notificationCenterState)
                .environment(PendingCardCenterState(store: container.pendingCards))
                .environment(DocumentsState(
                    store: container.documents,
                    pipeline: OCRPipeline(
                        recognizer: EngineRegistry.shared.resolve(OCRRecognizerFactory.self),
                        grayscaleDecoder: GrayscaleImageDecoder()),
                    ocrAuthorized: { true },
                    originalsDir: FileManager.default.temporaryDirectory,
                    prescriptionStore: container.prescriptions,
                    dataChange: dataChange,
                    pendingCards: container.pendingCards,
                    scheduler: container.reminderScheduler,
                    cardStore: OCRCardStore(writer: container.store.writer),
                    suggestionStore: ProfileSuggestionStore(writer: container.store.writer)))
                .environment(ExportWizardState(service: container.pdfExport))
                // 健康导入二轮（V3.98）：F16DeviceState 只依赖同步协调器 + 数据变更信号；
                // 业主 2026-09-17：增 settings（写回开关裁决）——与下方环境注入同实例
                .environment(F16DeviceState(syncService: container.healthSync,
                                            dataChange: dataChange,
                                            settings: settingsStore))
                .environment(BackupState(service: container.backup))
        }
    }
}
