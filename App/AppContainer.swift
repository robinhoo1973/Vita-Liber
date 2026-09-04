import Foundation
import Domain
import Infrastructure
import Protocols

/// tech-spec §3 组装根：唯一共享 DatabasePool(WAL) + StoresBundle。
/// 评审修正（架构 A2）：M1a 起组装根被真实消费——VitaLiberApp 在此装配
/// 生产依赖（GRDB 库 + M1aPersisting + 审计写入口），AppState 只面向协议。
struct AppContainer {
    let store: GRDBStore
    let audit: AuditLogWriter
    let persistor: GRDBM1aPersistor
    let meds: MedicationStore
    let apts: AppointmentStore
    let reconciler: ReminderReconciler
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

    /// 生产装配：文件库 + WAL（§4.4）+ UNUserNotificationCenter 适配。
    static func live(databasePath: String) throws -> AppContainer {
        let store = try GRDBStore.pool(at: databasePath)
        return assemble(store: store, scheduler: UNReminderScheduler())
    }

    /// Preview/测试装配：内存库 + 内存调度器 + 临时目录敏感资产仓
    /// （预览不得污染生产 Documents/MedicalNotes/sensitive）。
    static func preview() throws -> AppContainer {
        let store = try GRDBStore.inMemory()
        return assemble(store: store, scheduler: InMemoryReminderScheduler(),
                        mediaBaseDir: FileManager.default.temporaryDirectory)
    }

    private static func assemble(store: GRDBStore, scheduler: any ReminderScheduling,
                                 mediaBaseDir: URL? = nil) -> AppContainer {
        // 引擎注册提前到组装根：资产仓等依赖注入端口的能力在组合根装配时即就位。
        // AppState.init 侧有 isRegistered 幂等守卫，重复调用不覆盖已注入桩。
        EngineRegistry.shared.registerDefaultEngines()
        let meds = MedicationStore(writer: store.writer)
        let apts = AppointmentStore(writer: store.writer, scheduler: scheduler)
        let reconciler = ReminderReconciler(scheduler: scheduler, source: meds)
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
        let entitlements = EntitlementStore(writer: store.writer,
                                            storefront: EntitlementStore.InMemoryStorefront())
        let trends = TrendQueryStore(writer: store.writer)
        let voiceNotes = VoiceNoteStore(writer: store.writer)
        return AppContainer(store: store,
                            audit: AuditLogWriter(writer: store.writer),
                            persistor: GRDBM1aPersistor(store: store),
                            meds: meds,
                            apts: apts,
                            reconciler: reconciler,
                            search: search,
                            mediaSession: MediaUnlockSession(),
                            // 红线纵深防御在装配处统一包一层：BR-012/BR-006 对所有
                            // Provider 实现生效（含 P1 云端），消费方不需要各自设防
                            aiProvider: SafeAIProvider(inner: LocalRetrievalProvider(search: search)),
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
                            messages: messages)
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
