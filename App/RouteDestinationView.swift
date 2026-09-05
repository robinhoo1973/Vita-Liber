import SwiftUI
import Domain

/// §5.45 路由目的地映射：AppRoute → 具体视图的唯一分发表。
///
/// 纪律：新增 SP 页面必须在此登记 case → 视图；**未登记的 case 落入降级分支**——
/// 渲染可见的「即将上线」提示页（不 crash）。历史注记：原「回到所属 Tab 模块根」
/// 会在路由已 push 进栈时形成栈内套娃（推进一个一模一样的模块根副本），
/// 故降级落点改为提示页，返回即弹回原页——缺路由降级绝不 crash 的纪律不变。
/// 页面陆续落地（M1c→M2 各批）时在此逐条点亮。
struct RouteDestinationView: View {
    let route: AppRoute
    @Environment(AppState.self) private var app

    var body: some View {
        switch route {
        // ---- F1 安全 ----
        case .sosHelp:
            SOSHelpView()

        // ---- F3 成员 ----
        case .memberList:
            MemberManagementView()

        // ---- F4 就诊 ----
        case .encounterList:
            EncounterListView()
        case .encounterDetail:
            RouteFallbackView(route: route)   // 需 store 查询上下文，从列表进入
        case .encounterForm:
            EncounterFormView()

        // ---- F5 文档 ----
        case .documentList:
            DocumentLibraryView()
        case .documentDetail(let id):
            DocumentDetailRouteView(documentId: id)
        case .importSource:
            DocumentLibraryView()

        // ---- F6 OCR ----
        case .pendingOcrQueue:
            PendingOcrQueueView()

        // ---- F7 指标 ----
        case .trendChart(let patientId, let metric):
            TrendChartRouteView(patientId: patientId, metricKey: metric)
        case .metricQuickEntry:
            MetricQuickEntryView()

        // ---- F8 观察 ----
        case .observationCreate:
            ObservationCreateRouteView()

        // ---- F9 用药 ----
        case .medicationCabinet:
            InventoryHubView()
        case .medicationPlan(let id):
            MedicationPlanDetailView(planId: id)
        case .medicationPlanForm:
            MedicationPlanFormView()

        // ---- F10 预约 ----
        case .appointmentList:
            AppointmentListView()
        case .appointmentForm:
            AppointmentFormView()
        case .visitPrepPackage:
            VisitPrepView()
        case .questionList:
            QuestionListView()

        // ---- F12 ----
        case .assistantChat:
            AssistantView()
        case .globalSearch:
            GlobalSearchView()
        case .assistantHistory:
            AssistantHistoryView()

        // ---- F13 ----
        case .backupRestore:
            BackupView()
        case .exportWizard:
            ExportWizardView()

        // ---- F14 设置 ----
        case .settingsRoot:
            SettingsView()
        case .notificationCenter:
            NotificationCenterView()
        case .auditLog:
            AuditLogView()
        case .languageSettings:
            LanguageSettingsView()
        case .themeSettings:
            ThemeSettingsView()
        case .voiceLanguageSettings:
            VoiceLanguageSettingsView()

        // ---- F15 ----
        case .emergencyCardConfig:
            EmergencyCardHubView()   // 自带 hub 数据加载与选择器装配（ADR-021 单视图复用）

        // ---- F16 ----
        case .alertHistory:
            AlertHistoryView()
        case .deviceConnection:
            DeviceConnectionView()

        // ---- F17 语音挂载（SP-55 目标落点；FR17.13 模板确认在视图内） ----
        case .voiceGuideProfile:
            VoiceGuidedProfileRouteView()
        case .voiceReminderDraft:
            VoiceReminderDraftRouteView()
        case .voiceNotePanel:
            VoiceNotePanelRouteView()

        // ---- F18 ----
        case .careModeConfig:
            CareModeSettingsView()

        // ---- F19 ----
        case .voiceSession:
            VoiceSessionView()

        // ---- F22 ----
        case .helpCenter:
            HelpRootView()
        case .feedbackReport:
            FeedbackView()

        // ---- F23 过敏 ----
        case .allergyList:
            AllergyListView()
        case .allergyCreate:
            AllergyCreateView()

        // ---- F24 ----
        case .caregiverTasks:
            CaregiverViews()
        case .sentStatusHub:
            SentStatusHubView()

        // ---- 商业化 ----
        case .paywall:
            PaywallView()

        // ---- SP-11 快速拍摄（TestFlight 实测修复：原先列入「尚未落地」降级，
        //      三入口点击静默回档案根——现接真实相机流 + 资料库入库管线） ----
        case .scanCapture(let kind):
            QuickCaptureView(kind: kind)

        // ---- 审查修复：已落地视图补登记（原落入降级分支，用户点观察项/成员
        //      通知深链落到重复的模块根套娃） ----
        case .memberDetail(let id):
            if let member = app.members.first(where: { $0.id == id }) {
                MemberDetailView(member: member)
            } else {
                RouteFallbackView(route: route)
            }
        case .ocrConfirm:
            OcrConfirmView()

        // ---- FR8.11 观察详情页（V3.65 实装：四入口直达——首页待办/搜索/
        //      时间轴/随访通知深链） ----
        case .observationDetail(let id):
            ObservationDetailView(observationId: id)

        // ---- SP-17 批次详情/编辑（V3.65 实装：药箱批次卡 → 详情 → 编辑/
        //      盘点/废弃；过期批次零用药建议 BR-006） ----
        case .stockLotDetail(let id):
            StockLotDetailView(lotId: id)
        case .stockLotEdit(let id):
            if let id {
                StockLotDetailView(lotId: id)   // 编辑经详情页 sheet 呈现（单一宿主，防双弹）
            } else {
                RouteFallbackView(route: route)
            }

        // ---- 尚未落地的页面：可见的「即将上线」提示（§5.45 缺路由降级
        //      不 crash）——审查修复：原渲染所属 Tab 模块根导致栈内套娃
        //      （用户在时间轴点观察项会「推进」一个一模一样的时间轴副本） ----
        case .preferences,
             .privacyAuthorization, .guidelineSourceDetail:
            RouteFallbackView(route: route)
        }
    }
}

/// 未登记路由的降级落点（不 crash、不渲染假页面）。
/// 审查修复：原渲染所属 Tab 模块根——路由已 push 进栈时再挂一个模块根
/// 形成「栈内套娃」（用户点观察项推进一个一模一样的时间轴副本，返回
/// 观感失效）。改为可见的「即将上线」提示页，返回即弹回原页。
private struct RouteFallbackView: View {
    let route: AppRoute
    var body: some View {
        ContentUnavailableView(L10n.routeComingSoon, systemImage: "hammer",
                               description: Text(L10n.routeComingSoonHint))
            .navigationTitle(L10n.help_appName)
            .navigationBarTitleDisplayMode(.inline)
    }
}

extension MainModule {
    init(tabID: MainModuleID) {
        switch tabID {
        case .home: self = .home
        case .records: self = .records
        case .reminders: self = .reminders
        case .ai: self = .ai
        case .me: self = .me
        }
    }
}

/// F8 观察创建路由适配：ObservationCreateSheet 要求 onCreate 闭包——
/// 路由上下文中接线到 ObservationStoreState.create（敏感媒体资产仓全链路）。
struct ObservationCreateRouteView: View {
    @Environment(AppState.self) private var app
    @Environment(ObservationStoreState.self) private var state

    var body: some View {
        ObservationCreateSheet { kind, description, selfMark, photoData in
            Task {
                await state.create(patientId: app.currentPatientId, kind: kind,
                                   description: description, selfMark: selfMark,
                                   photoData: photoData)
            }
        }
    }
}

/// §5.45 文档详情路由适配：route 携带 UUID，视图消费 TimelineDocumentEntry——
/// 从当前时间轴投影按 id 查找；查无（已删除/未入轴）回降级落点（不 crash）。
struct DocumentDetailRouteView: View {
    let documentId: UUID
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if let entry = app.timeline.first(where: { $0.id == documentId }) {
                TimelineDocumentDetailView(entry: entry)
            } else {
                // 审查修复：原错用趋势页文案「趋势范围不可用」——补专用文案
                ContentUnavailableView(L10n.docDetailTitle, systemImage: "doc.text.magnifyingglass",
                                       description: Text(L10n.docDetailNotFound))
            }
        }
    }
}
