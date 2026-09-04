import Foundation

/// 类型安全路由目标（tech-spec §5.45）：编译期穷举，禁止字符串拼接路径。
/// 全量路由注册表——新增 SP 页面必须同步添加 case（代码评审检查项）。
///
/// 落 Domain 而非 App 的理由：Infrastructure 的通知调度器需要把 Codable AppRoute
/// 写进 UNMutableNotificationContent.userInfo（通知点击→路由映射契约），
/// 而 Infrastructure 不得 import App 层；Domain 零框架依赖，纯 Foundation Codable。
public enum AppRoute: Hashable, Sendable, Codable {
    // ---- F1 安全 ----
    case sosHelp                         // SP-33（唯一免门禁路径，FR1.8）

    // ---- F3 成员 ----
    case memberList                      // SP-06
    case memberDetail(UUID)              // SP-06 子页

    // ---- F4 就诊 ----
    case encounterList                   // SP-08 列表
    case encounterDetail(UUID)           // SP-08 详情
    case encounterForm(UUID?)            // 新建/编辑（nil=新建）

    // ---- F5 文档 ----
    case documentList                    // SP-09
    case documentDetail(UUID)            // SP-09 详情
    case importSource                    // SP-10
    case scanCapture                     // SP-11 相机流

    // ---- F6 OCR ----
    case ocrConfirm(documentId: UUID)    // SP-12 单文档确认
    case pendingOcrQueue                 // SP-53 待确认聚合队列

    // ---- F7 指标 ----
    case trendChart(patientId: UUID, metric: String)   // SP-13
    case metricQuickEntry                // SP-13 快速录入

    // ---- F8 观察 ----
    case observationCreate               // SP-14 三步流程
    case observationDetail(UUID)         // SP-14 详情/对比

    // ---- F9 用药 ----
    case medicationPlan(UUID)            // SP-15 计划详情
    case medicationPlanForm(UUID?)       // SP-15 创建/编辑
    case stockLotDetail(UUID)            // SP-17 批次详情
    case stockLotEdit(UUID?)             // SP-17 批次编辑（nil=新建，含效期/位置/照片）
    case medicationCabinet               // SP-16 药箱（FR9.8.9 家庭总览为 Pro）

    // ---- F10 预约 ----
    case appointmentList                 // SP-18
    case appointmentForm(UUID?)          // SP-18 新建/改期
    case visitPrepPackage                // FR10.4 就诊准备包

    // ---- F12 搜索/AI ----
    case globalSearch                    // SP-20
    case assistantChat                   // SP-21
    case assistantHistory                // FR12.10 / SP-51

    // ---- F13 导出 ----
    case exportWizard                    // SP-22
    case backupRestore                   // SP-23

    // ---- F14 设置 ----
    case settingsRoot                    // SP-25
    case preferences                     // SP-26 偏好中心
    case notificationCenter              // SP-27
    case auditLog                        // FR14.2
    case privacyAuthorization            // FR14.1 九开关面板
    case themeSettings                   // FR14.4 外观与主题
    case languageSettings                // FR14.5 语言选择
    case voiceLanguageSettings           // FR17.15/17.16 语音语言选择

    // ---- F15 紧急卡 ----
    case emergencyCardConfig             // SP-28

    // ---- F16 设备预警 ----
    case deviceConnection                // SP-29
    case alertHistory                    // SP-30
    case guidelineSourceDetail(UUID)     // 信源原文

    // ---- F18 关怀 ----
    case careModeConfig                  // SP-32
    case voiceGuideProfile               // SP-58 档案语音引导
    case voiceReminderDraft              // FR17.10 语音提醒设定（SP-55 目标）
    case questionList                    // FR10.5 问诊问题列表
    case voiceNotePanel                  // FR17.14 语音速记面板（任意文本目标）

    // ---- F19 ----
    case voiceSession                    // SP-34 关怀语音会话

    // ---- F22 ----
    case helpCenter                      // SP-42
    case feedbackReport                  // SP-46 反馈提交

    // ---- F23 过敏 ----
    case allergyList                     // SP-50
    case allergyCreate                   // SP-50 三步录入

    // ---- F24 ----
    case caregiverTasks                  // SP-57 同机照护者
    case sentStatusHub                   // SP-56 发送状态

    // ---- 商业化 ----
    case paywall                         // SP-61
}

/// 路由所属 Tab（§5.45：通知点击按 route 所属 Tab 切换 selection 并 append 到对应 path）
public enum MainModuleID: String, Sendable, Hashable, Codable {
    case home, records, reminders, ai, me

    public static func tab(of route: AppRoute) -> MainModuleID {
        switch route {
        case .sosHelp, .memberList, .memberDetail, .encounterList, .encounterDetail,
             .encounterForm, .documentList, .documentDetail, .importSource, .scanCapture,
             .ocrConfirm, .pendingOcrQueue, .trendChart, .metricQuickEntry,
             .observationCreate, .observationDetail, .allergyList, .allergyCreate,
             .caregiverTasks, .voiceNotePanel:
            return .records
        case .medicationPlan, .medicationPlanForm, .stockLotDetail, .stockLotEdit,
             .medicationCabinet, .appointmentList, .appointmentForm, .visitPrepPackage,
             .sentStatusHub, .questionList:
            return .reminders
        case .globalSearch, .assistantChat, .assistantHistory, .voiceSession:
            return .ai
        case .settingsRoot, .preferences, .notificationCenter, .auditLog,
             .privacyAuthorization, .themeSettings, .languageSettings,
             .voiceLanguageSettings, .emergencyCardConfig, .deviceConnection,
             .alertHistory, .guidelineSourceDetail, .careModeConfig,
             .voiceGuideProfile, .voiceReminderDraft, .helpCenter, .feedbackReport,
             .exportWizard, .backupRestore, .paywall:
            return .me
        }
    }
}
