import SwiftUI
import Domain

/// §5.45 路由目的地映射：AppRoute → 具体视图的唯一分发表。
///
/// 纪律：新增 SP 页面必须在此登记 case → 视图；**未登记的 case 落入降级分支**——
/// 回到该路由所属 Tab 的模块根（§5.45 缺路由降级不 crash，绝不渲染假占位页）。
/// 页面陆续落地（M1c→M2 各批）时在此逐条点亮。
struct RouteDestinationView: View {
    let route: AppRoute

    var body: some View {
        switch route {
        // ---- F1 安全 ----
        case .sosHelp:
            SOSHelpView()

        // ---- F3 成员 ----
        case .memberList:
            MemberManagementView()
        case .memberDetail:
            RouteFallbackView(route: route)

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

        // ---- 尚未落地的页面：降级回所属 Tab 模块根（§5.45 缺路由降级不 crash） ----
        case .ocrConfirm,
             .observationDetail,
             .stockLotDetail, .stockLotEdit,
             .preferences,
             .privacyAuthorization, .guidelineSourceDetail:
            RouteFallbackView(route: route)
        }
    }
}

/// 未登记路由的降级落点：回所属 Tab 模块根（不 crash、不渲染假页面）
private struct RouteFallbackView: View {
    let route: AppRoute
    var body: some View {
        ModuleRoot(module: MainModule(tabID: MainModuleID.tab(of: route)))
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
                ContentUnavailableView(L10n.docDetailTitle, systemImage: "doc.text.magnifyingglass",
                                       description: Text(L10n.trendRangeUnavailable))
            }
        }
    }
}
