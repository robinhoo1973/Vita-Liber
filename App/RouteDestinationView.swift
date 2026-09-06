import SwiftUI
import Domain
import Infrastructure

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
        case .encounterDetail(let id):
            EncounterDetailRouteView(encounterId: id)
        case .encounterForm:
            EncounterFormView()

        // ---- F5 文档 ----
        case .documentList:
            DocumentLibraryView()
        case .documentDetail(let id):
            DocumentDetailRouteView(documentId: id)
        case .importSource:
            // SP-10 导入来源选择：资料库 + 自动弹出五入口确认弹窗
            // （第六轮全仓审查修复：此前渲染完整资料库 = documentList 的
            // 翻版，注册表对 .importSource 的真实落点名不副实）
            DocumentLibraryView(autoPresentImport: true)

        // ---- F6 OCR ----
        case .pendingOcrQueue:
            PendingOcrQueueView()

        // ---- F7 指标 ----
        case .trendChart(let patientId, let metric):
            TrendChartRouteView(patientId: patientId, metricKey: metric)
        case .metricOverview:
            MetricOverviewView()
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
        case .reminderToday:
            RemindersView()

        // ---- F10 预约 ----
        case .appointmentList:
            AppointmentListView()
        case .appointmentDetail(let id):
            AppointmentDetailRouteView(appointmentId: id)
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

        // ---- 评审批 H15：补登记曾缺失的活跃页面（§5.45 注册表必须覆盖全部 SP；
        // 此前仅内联 NavigationLink 可达 → 通知深链/跨启动恢复均落空） ----
        case .healthProblemList:
            HealthProblemListView()
        case .immunizationList:
            ImmunizationHubView()
        case .helpPermissionDiagnostics:
            HelpPermissionDiagnostics()
        case .helpReminderDiagnostics:
            HelpReminderDiagnostics()
        case .termsAndPrivacy:
            HelpAboutView()

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
        // ---- FR8.11 观察详情页（V3.65 实装：四入口直达——首页待办/搜索/
        //      时间轴/随访通知深链） ----
        case .observationDetail(let id):
            ObservationDetailView(observationId: id)
        case .doctorShowcase(let patientId):
            DoctorShowcaseView(patientId: patientId)

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

        // ---- FR14.1 分目的授权面板（V3.66 实装：七开关 + 两说明行） ----
        case .privacyAuthorization:
            PrivacyAuthorizationView()

        // ---- SP-26 偏好中心（V3.66 实装：真实生效项聚合，假偏好已按
        //      FR14.7 移除）----
        case .preferences:
            PreferencesView()

        // ---- FR16.3/16.4 信源原文详情（V3.66 实装：B 级徽章 + 完整阈值表
        //      + 原文链接 + 准入说明）----
        case .guidelineSourceDetail(let id):
            GuidelineSourceDetailView(entryId: id)
        }
    }
}

/// §5.48 已删除实体降级落点（第七轮全仓审查修复）：目标实体查无（已删除/
/// 跨成员）时渲染「该资料已不存在」并**自弹回根**——原「即将上线」页把
/// 数据缺失误报成功能未上线，且路由项滞留在栈里（返回观感失效），与
/// §5.48「目的地视图自弹回根 + 提示」契约不符。「未登记路由」语义已随
/// switch 穷尽化退役（未登记 case 编译期即不可达，缺路由通知走
/// degradeToHome）。短暂停留让提示可见，随后经 AppRouter.pop 弹栈。
struct RouteFallbackView: View {
    let route: AppRoute
    @Environment(AppRouter.self) private var router

    var body: some View {
        ContentUnavailableView(L10n.routeEntityGone, systemImage: "exclamationmark.circle",
                               description: Text(L10n.routeEntityGoneHint))
            .navigationTitle(L10n.help_appName)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)   // try?-ok: 睡眠被取消（视图已弹出销毁）即停
                guard !Task.isCancelled else { return }
                router.pop(route)
            }
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

/// §5.45 文档详情路由适配：route 携带 UUID，经 DocumentStore 单源查找
/// （V3.39：旧 app.timeline 投影镜像已随向导简化删除——DocumentStore
/// 是唯一生产事实源）；查无（已删除）回降级落点（不 crash）。
struct DocumentDetailRouteView: View {
    let documentId: UUID
    @Environment(DocumentsState.self) private var documentsState
    @Environment(AppRouter.self) private var router
    @State private var storeRow: DocumentStore.DocumentRow?
    @State private var lookupDone = false

    var body: some View {
        Group {
            if let storeRow {
                DocumentStoreDetailView(doc: storeRow)
            } else if lookupDone {
                // 审查修复：原错用趋势页文案「趋势范围不可用」——补专用文案
                // 第七轮修复：§5.48 契约——查无实体（已删除）自弹回根
                ContentUnavailableView(L10n.docDetailTitle, systemImage: "doc.text.magnifyingglass",
                                       description: Text(L10n.docDetailNotFound))
                    .task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)   // try?-ok: 睡眠被取消（视图已弹出销毁）即停
                        guard !Task.isCancelled else { return }
                        router.pop(.documentDetail(documentId))
                    }
            } else {
                ProgressView()
                    .task {
                        storeRow = await documentsState.fetch(id: documentId)
                        lookupDone = true
                    }
            }
        }
    }
}
