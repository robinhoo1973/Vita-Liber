import Foundation
import os
import Domain
import Infrastructure
import Protocols

/// tech-spec §3 组装根：唯一共享 DatabasePool(WAL) + StoresBundle。
/// 评审修正（架构 A2）：M1a 起组装根被真实消费——VitaLiberApp 在此装配
/// 生产依赖（GRDB 库 + M1aPersisting + 审计写入口），AppState 只面向协议。
struct AppContainer {
    private static let logger = Logger(subsystem: "com.vitaliber", category: "container")
    /// 生产库打开失败的降级标记（非 nil = 只读安全模式，App 层据此显示
    /// 降级页而不是继续跑内存库——审查修复：原静默降级 preview 内存库，
    /// 用户看到空档案（以为数据丢失），期间写入随内存丢弃形成数据分裂）
    let degradedReason: String?
    let store: GRDBStore
    let audit: AuditLogWriter
    let persistor: GRDBM1aPersistor
    let meds: MedicationStore
    let apts: AppointmentStore
    let reconciler: ReminderReconciler
    /// FR9.15/§4.2 五表原子创建与计划生命周期（处方→计划参考模板）
    let composer: MedicationPlanComposer
    let search: GRDBSearchService
    /// §5.10 跨视图敏感媒体解锁会话
    let mediaSession: MediaUnlockSession
    /// 协议注入（架构规则 3）：装配处包了 SafeAIProvider 纵深防御装饰器，
    /// 消费方只依赖 AIProvider 协议，具体实现（本地检索 / P1 云端）可替换
    let aiProvider: any AIProvider
    let settings: SettingsStore
    let observations: ObservationStore
    /// F8.4/§5.10 敏感媒体资产仓（BR-007/008）：原始图 + blur 双产物、complete 保护
    let mediaAssets: any SensitiveAssetStoring
    let allergies: AllergyStore
    let entitlements: EntitlementStore
    let trends: TrendQueryStore
    let voiceNotes: VoiceNoteStore
    let guidelines: GuidelineStore
    let emergencyCards: EmergencyCardStore
    let immunizations: ImmunizationStore
    let claims: ClaimStore
    let messages: MessageDeliveryStore
    /// F4 就诊事件（SP-08）
    let encounters: EncounterStore
    /// F11 时间轴联合查询 + FR11.4 健康问题 + FR10.5 问诊问题
    let timelineQuery: TimelineQueryStore
    let healthProblems: HealthProblemStore
    let questions: QuestionStore
    /// FR3.4 删除成员影响清单与单事务删除（§5.51 UnitOfWork 语义）
    let memberDeletion: MemberDeletionService
    /// F5 资料库（SP-09）
    let documents: DocumentStore
    /// FR13.11 备份与恢复（SP-24）——BackupState 的服务端
    let backup: BackupService
    /// FR12.10 AI 会话历史（SP-51）
    let aiHistory: AIHistoryStore
    /// FR13.1/13.2 PDF 导出（SP-22）
    let pdfExport: PDFExportService
    /// F16 只读 Apple 健康接入（FR16.1）
    let healthReader: HealthKitReader

    /// 生产装配：文件库 + WAL（§4.4）+ UNUserNotificationCenter 适配。
    /// @MainActor：mediaSession（MediaUnlockSession）为 UI 会话令牌，装配根即主线程。
    @MainActor
    static func live(databasePath: String) throws -> AppContainer {
        let store = try GRDBStore.pool(at: databasePath)
        return assemble(store: store, scheduler: UNReminderScheduler())
    }

    /// Preview/测试装配：内存库 + 内存调度器 + 临时目录敏感资产仓
    /// （预览不得污染生产 Documents/MedicalNotes/sensitive）。
    @MainActor
    static func preview() throws -> AppContainer {
        let store = try GRDBStore.inMemory()
        return assemble(store: store, scheduler: InMemoryReminderScheduler(),
                        mediaBaseDir: FileManager.default.temporaryDirectory)
    }

    /// 生产装配 + 显式降级路径：live 失败时返回 degradedReason 非 nil 的
    /// 占位容器（内存库），App 层不渲染主界面、显示可见降级引导——
    /// 绝不静默空库继续写入（审查修复，tech-spec「迁移失败只读降级」）
    @MainActor
    static func liveOrDegraded(databasePath: String) -> AppContainer {
        do {
            return try live(databasePath: databasePath)
        } catch {
            do {
                let store = try GRDBStore.inMemory()
                return assemble(store: store, scheduler: UNReminderScheduler(),
                                degradedReason: "\(error)")
            } catch {
                fatalError("Data layer init failed (live and in-memory degraded both unavailable): \(error)")
            }
        }
    }

    @MainActor
    private static func assemble(store: GRDBStore, scheduler: any ReminderScheduling,
                                 mediaBaseDir: URL? = nil,
                                 degradedReason: String? = nil) -> AppContainer {
        // 引擎注册提前到组装根：资产仓等依赖注入端口的能力在组合根装配时即就位。
        // AppState.init 侧有 isRegistered 幂等守卫，重复调用不覆盖已注入桩。
        EngineRegistry.shared.registerDefaultEngines()
        let meds = MedicationStore(writer: store.writer)
        let apts = AppointmentStore(writer: store.writer, scheduler: scheduler)
        let reconciler = ReminderReconciler(scheduler: scheduler, source: meds)
        let auditWriter = AuditLogWriter(writer: store.writer)
        let composer = MedicationPlanComposer(writer: store.writer, audit: auditWriter)
        let search = GRDBSearchService(writer: store.writer)
        let settings = SettingsStore(writer: store.writer)
        let observations = ObservationStore(writer: store.writer)
        let mediaAssets = SensitiveAssetStore(
            writer: store.writer,
            compressor: EngineRegistry.shared.resolve(ImageCompressingFactory.self),
            baseDir: mediaBaseDir)
        let allergies = AllergyStore(writer: store.writer)
        // StoreKit 2 生产接线为 L2 部署项；M1c 以桩承载全部逻辑路径（可全量单测）
        let guidelines = GuidelineStore(writer: store.writer)
        let emergencyCards = EmergencyCardStore(writer: store.writer)
        let immunizations = ImmunizationStore(writer: store.writer)
        let claims = ClaimStore(writer: store.writer)
        let messages = MessageDeliveryStore(writer: store.writer)
        let encounters = EncounterStore(writer: store.writer)
        let timelineQuery = TimelineQueryStore(writer: store.writer)
        let healthProblems = HealthProblemStore(writer: store.writer)
        let questions = QuestionStore(writer: store.writer)
        let memberDeletion = MemberDeletionService(writer: store.writer, scheduler: scheduler)
        let documents = DocumentStore(writer: store.writer)
        let backup = BackupService(writer: store.writer)
        let aiHistory = AIHistoryStore(writer: store.writer)
        let pdfExport = PDFExportService(writer: store.writer)
        let healthReader = HealthKitReader()
        let entitlements = EntitlementStore(writer: store.writer,
                                            storefront: EntitlementStore.InMemoryStorefront())
        let trends = TrendQueryStore(writer: store.writer)
        let voiceNotes = VoiceNoteStore(writer: store.writer)
        return AppContainer(degradedReason: degradedReason,
                            store: store,
                            audit: auditWriter,
                            persistor: GRDBM1aPersistor(store: store),
                            meds: meds,
                            apts: apts,
                            reconciler: reconciler,
                            composer: composer,
                            search: search,
                            mediaSession: MediaUnlockSession(),
                            // 装饰器链（FR12.9 审计 + 红线纵深防御）：AuditedAIProvider 记
                            // 每次调用读取的资料 ID 范围（entityId 哈希后落库，脱敏）；
                            // SafeAIProvider 对 BR-012/BR-006 对所有 Provider 实现生效
                            // （含 P1 云端），消费方不需要各自设防。审计失败只记日志，
                            // 不得阻断回答（FR22 边界：诊断失败不阻塞主功能）。
                            aiProvider: AuditedAIProvider(
                                inner: SafeAIProvider(inner: LocalRetrievalProvider(search: search)),
                                audit: { [writer = store.writer] ids in
                                    let recorder = AuditLogWriter(writer: writer)
                                    do {
                                        try await recorder.record(action: "ai_scope", entityType: "ai_query",
                                                                  entityId: ids, actorLocal: "owner", meta: nil)
                                    } catch {
                                        // 审计失败不阻断回答（FR22 边界），但必须上报（§7 不静默吞）
                                        logger.error("AI 审计失败: \(error)")
                                    }
                                }),
                            settings: settings,
                            observations: observations,
                            mediaAssets: mediaAssets,
                            allergies: allergies,
                            entitlements: entitlements,
                            trends: trends,
                            voiceNotes: voiceNotes,
                            guidelines: guidelines,
                            emergencyCards: emergencyCards,
                            immunizations: immunizations,
                            claims: claims,
                            messages: messages,
                            encounters: encounters,
                            timelineQuery: timelineQuery,
                            healthProblems: healthProblems,
                            questions: questions,
                            memberDeletion: memberDeletion,
                            documents: documents,
                            backup: backup,
                            aiHistory: aiHistory,
                            pdfExport: pdfExport,
                            healthReader: healthReader)
    }

    /// Application Support 下的数据库路径（生产库位置）
    static func defaultDatabasePath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("VitaLiber", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { /* 目录创建失败由 GRDB 打开时报错，不在此吞掉 */ }
        return dir.appendingPathComponent("vitaliber.sqlite").path
    }
}
