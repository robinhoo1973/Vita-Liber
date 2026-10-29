import Foundation
import os
import HealthKit
import Domain
import Infrastructure
import Protocols
import Perception

/// tech-spec §3 组装根：唯一共享 DatabasePool(WAL) + StoresBundle。
/// 评审修正（架构 A2）：M1a 起组装根被真实消费——VitaLiberApp 在此装配
/// 生产依赖（GRDB 库 + PatientPersisting + 审计写入口），AppState 只面向协议。
struct AppContainer {
    private static let logger = Logger(subsystem: "com.vitaliber", category: "container")
    /// 生产库打开失败的降级标记（非 nil = 只读安全模式，App 层据此显示
    /// 降级页而不是继续跑内存库——审查修复：原静默降级 preview 内存库，
    /// 用户看到空档案（以为数据丢失），期间写入随内存丢弃形成数据分裂）
    let degradedReason: String?
    let store: GRDBStore
    let audit: AuditLogWriter
    let persistor: GRDBPatientPersistor
    let meds: MedicationStore
    /// v42 用药计划模板（计划 = 时段；药品绑定由用药提醒创建）
    let scheduleTemplates: MedicationScheduleStore
    let apts: AppointmentStore
    let reconciler: ReminderReconciler
    /// 第八轮全仓审查修复（通道假宣告遗留面）：组装根唯一经 FR9.18 投递门
    /// 的调度器（ChannelGatedScheduler）——VitaLiberApp 装配的 ReminderStore
    /// 与 F16DeviceState 此前绕过本门直连裸 UNReminderScheduler。所有生产
    /// 通知生产者必须经本实例投递。
    /// 门的作用域（与 ui-ux §5.58 降级链一致）：只有**有应用内横幅承接
    /// 且横幅总开关开启**的 dose-/slot- 在「静音仅横幅」时被抑制——横幅
    /// 开关关闭时承接不存在，按降级链照常系统投递（第十一轮审查）；预约/
    /// 随访/临期/预警/备份五族无应用内承接，照常系统投递（宁响铃不静默），
    /// 其「静音仅横幅」偏好随 W4 横幅通道扩展后逐类别收紧。
    let reminderScheduler: any ReminderScheduling
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
    /// F25 码表索引（ADR-028/§5.52）：六表读取 + 内置种子装载（装配层注入消费侧 Store 前
    /// 先 seedCodeSetsIfNeeded()；引擎未接入消费侧的六点由 §11 逐点跟踪）
    let codeIndex: GRDBCodeIndex
    /// FR14.8 通知处理状态持久化（notification_state 表，V3.72 死 DDL 接线）
    let notificationState: NotificationStateStore
    /// FR6.9 待办卡仓（pending_card，BR-003 表级排除——D 级草稿绝不进事实链）
    let pendingCards: PendingCardStore
    /// 通知中心可观察门面（@Environment 注入要求 @Observable）
    let notificationCenterState: NotificationCenterState
    let voiceNotes: VoiceNoteStore
    /// AI 聊天历史（2026-10-19）：本机会话/消息
    let chatHistory: ChatHistoryStore
    let guidelines: GuidelineStore
    let emergencyCards: EmergencyCardStore
    let immunizations: ImmunizationStore
    let messages: MessageDeliveryStore
    /// F4 就诊事件（SP-08）
    let encounters: EncounterStore
    /// v27 体检主卡只读读面（子项目 J · healthExamDetail 路由）
    let healthExams: HealthExamStore
    /// F11 时间轴联合查询 + FR11.4 健康问题 + FR10.5 问诊问题
    let timelineQuery: TimelineQueryStore
    let healthProblems: HealthProblemStore
    let questions: QuestionStore
    /// FR3.4 删除成员影响清单与单事务删除（§5.51 UnitOfWork 语义）
    let memberDeletion: MemberDeletionService
    /// F5 资料库（SP-09）
    let documents: DocumentStore
    /// 导出副本账本（2026-10-27 存储边界委员会 v49）：Documents 用户面树映射
    let documentExports: DocumentExportStore
    /// F9 拍处方 OCR 确认后落库（SP-11 处方入口，见 DocumentsState.commitDraft）
    let prescriptions: PrescriptionStore
    /// FR13.11 备份与恢复（SP-24）——BackupState 的服务端
    let backup: BackupService
    /// 三切片读面（2026-10-28 切片-only）：每片独立只读池 + 锁式 facade；
    /// nil = 装配未走切片路径（降级/预览缺省）。
    let catalogSlices: CatalogSliceReadFacade?
    /// 切片检查器（pinned root provisioning 前 nil——检查 fail-closed「暂不可用」）。
    let catalogSliceChecker: (any CatalogSliceReleaseResolving)?
    /// 切片安装器（每片独立 journal/staging/last-good；nil = 安装入口 fail-closed）。
    let catalogSliceUpdater: (any CatalogSliceInstalling)?
    /// 四域参考端口（2026-10-28 切片-only）：由三目录切片 facade 派生——drug/facility/
    /// exam 任一片可用即注入；缺片时对应查询在 facade 内返回空集（患者流零提示）。
    /// P6（P-批）：profile 片不提供检索能力，不得据此把端口判为非 nil——用显式谓词。
    var medicalReferenceCatalog: (any MedicalReferenceCatalogReading)? {
        guard let catalogSlices, catalogSlices.hasReferenceSlices else { return nil }
        return catalogSlices
    }
    /// SP-64 通告面（README VL-INDEX 二维码；委员会 P3，2026-10-07）：固定匿名通道
    /// + floor 落盘（与医疗支持目录同址）；读取纯显式动作、零隐式联网。
    /// 缺省 nil → 全域「不可用」（fail-closed，同 checker 缺省语义）。
    let updateAdvice: (any UpdateAdviceProviding)?
    // 业主裁决 D2（2026-09-18）：F12 AI 助手永久退役——AIHistoryStore /
    // AIHistoryState / AssistantHistoryView 已删除，装配根不再持有会话历史仓。
    /// FR13.1/13.2 PDF 导出（SP-22）
    let pdfExport: PDFExportService
    /// F16 只读 Apple 健康接入（FR16.1）
    let healthReader: HealthKitReader
    /// FR16.1 V3.86 自动化同步服务（观察者+BGTask+锚点+评估入库双流）
    let healthSync: HealthKitSyncService

    /// 启动门（2026-10-25）复用同一装配体：数据库文件已在后台完成探测/迁移，
    /// 本方法只做主线程侧的 store 装配，不再打开/迁移数据库。
    @MainActor
    static func live(store: GRDBStore) throws -> AppContainer {
        // 2026-10-28 切片-only（B2）：v4 目录链（ReadAccess/updater/journal/
        // checker/opener）已整体移除；Support 目录仍供通告面 floor
        // （UpdateAdviceService）使用。
        let catalogSupport = URL(fileURLWithPath: defaultMedicalCatalogPath()).deletingLastPathComponent()
        let updateAdviceProvider: (any UpdateAdviceProviding)?
        let catalogSlices: CatalogSliceReadFacade?
        let catalogSliceChecker: (any CatalogSliceReleaseResolving)?
        let catalogSliceUpdater: (any CatalogSliceInstalling)?
        #if os(iOS) || os(macOS)
        // XCUITest 离线用例：pinned root 随包后 checker 恒非 nil，任何点按都会真实
        // 联网。仅 DEBUG 的 -uitest-catalog-checker-off 走 checker==nil：初始仍显示
        // 「检查更新」（零隐式判定），用户点按检查后聚合才落 .unavailable（「重新检查」）。
        #if DEBUG
        let uiTestCheckerOff = ProcessInfo.processInfo.arguments.contains("-uitest-catalog-checker-off")
        #else
        let uiTestCheckerOff = false
        #endif
        let catalogRoot = uiTestCheckerOff ? nil : bundledData("MedicalCatalogRoot", "json")
        // P3（2026-10-07）：通告面通道已上线（固定 /git/raw 二维码），装配即 live；
        // floor 与医疗信任状态同支持目录、独立文件。
        updateAdviceProvider = UpdateAdviceService(
            floorStore: UpdateAdviceFloorStore.production(supportDirectory: catalogSupport))
        // 三切片（2026-10-28 切片-only）：支持目录 AppSupport/VitaLiber/catalog/v5。
        // 顺序：每片 journal 恢复（打开前）→ 自洽探测通过才挂读面（缺片=域级不可用）；
        // 检查器/安装器共用 bundled pinned root（uiTest 关闭时 checker=nil，失败闭合）。
        let sliceDirectory = URL(fileURLWithPath: Self.defaultCatalogSliceDirectory(), isDirectory: true)
        let sliceFacade = CatalogSliceReadFacade()
        let sliceTrust = CatalogSliceTrust(directory: sliceDirectory)
        let sliceBuild: @Sendable () -> Int64 = {
            Int64(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        }
        for kind in CatalogSliceKind.allCases {
            let active = CatalogSliceUpdateService.activeURL(kind, directory: sliceDirectory)
            let journal = CatalogSliceActivationJournal(
                journalURL: sliceDirectory.appendingPathComponent(kind.stem + "-active-journal.json"),
                supportDirectory: sliceDirectory,
                sha256: { try CatalogFileHashing.sha256(of: $0) },
                verifyInstalled: { url in
                    guard case .ready = CatalogSliceProbe.inspectSelfConsistent(path: url.path, kind: kind) else {
                        throw MedicalCatalogUpdateError.catalogIntegrityFailed
                    }
                })
            do {
                _ = try journal.recoverBeforeOpen(catalogURL: active)
            } catch {
                // 恢复失败（不可收敛）：该片 fail-closed 不挂读面，其余片不受影响。
                logger.error("切片恢复失败(\(kind.rawValue))，该片暂不启用: \(String(describing: error))")
                continue
            }
            switch kind {
            case .drug:
                if let store = try? CatalogSliceDrugStore(path: active) { sliceFacade.commitDrug(store) }   // try?-ok: 未装/损坏=该域不可用
            case .facility:
                if let store = try? CatalogSliceFacilityStore(path: active) { sliceFacade.commitFacility(store) }   // try?-ok: 同上
            case .reference:
                if let store = try? CatalogSliceExamStore(path: active) { sliceFacade.commitExam(store) }   // try?-ok: 同上
            case .profile:
                if let store = try? CatalogSliceProfileStore(path: active) { sliceFacade.commitProfile(store) }   // try?-ok: 同上
            }
        }
        catalogSlices = sliceFacade
        catalogSliceChecker = catalogRoot.map { root in
            CatalogSliceReleaseResolver(
                pinnedRootJSON: root,
                makeVerifier: { CryptoKitMedicalCatalogTrustVerifier(pinnedRootJSON: $0) },
                trust: sliceTrust,
                localReceipt: { kind in
                    CatalogSliceReceipt.read(kind: kind, directory: sliceDirectory)
                },
                currentBuild: sliceBuild)
        }
        catalogSliceUpdater = CatalogSliceUpdateService(
            directory: sliceDirectory,
            // fetcher 缺省由 Infrastructure 自建（切片名门文法；L0 家族 Q：
            // App 层不得引用传输实现符号）。
            opener: EnvelopeMedicalCatalogPackageOpening(),
            journalFor: { kind in
                CatalogSliceActivationJournal(
                    journalURL: sliceDirectory.appendingPathComponent(kind.stem + "-active-journal.json"),
                    supportDirectory: sliceDirectory,
                    sha256: { try CatalogFileHashing.sha256(of: $0) },
                    verifyInstalled: { url in
                        guard case .ready = CatalogSliceProbe.inspectSelfConsistent(path: url.path, kind: kind) else {
                            throw MedicalCatalogUpdateError.catalogIntegrityFailed
                        }
                    })
            },
            currentBuild: sliceBuild,
            verifySQLite: { url, candidate in
                switch CatalogSliceProbe.inspect(path: url.path, kind: candidate.kind,
                                                 expectedTables: Set(candidate.tables),
                                                 expectedCounts: candidate.counts,
                                                 verifyCounts: true) {
                case .ready: return
                default: throw MedicalCatalogUpdateError.catalogIntegrityFailed
                }
            })
        #else
        updateAdviceProvider = nil
        catalogSlices = nil
        catalogSliceChecker = nil
        catalogSliceUpdater = nil
        #endif
        // 2026-10-27 存储边界：敏感媒体/原件 canonical 根迁出 Documents（ADR-036）。
        return assemble(store: store, scheduler: productionScheduler(),
                        mediaBaseDir: MediaRootPaths.mediaBase(),
                        catalogSlices: catalogSlices,
                        catalogSliceChecker: catalogSliceChecker,
                        catalogSliceUpdater: catalogSliceUpdater,
                        updateAdvice: updateAdviceProvider)
    }

    /// 生产投递门统一装配（live 与降级路径共用）——装饰器链只此一处定义：
    /// 两处分别构造时，任一侧新增装饰器（如静默时段门）即与另一侧漂移，
    /// 降级路径重新打开本修复所堵的绕门通道。
    private static func productionScheduler() -> any ReminderScheduling {
        ChannelGatedScheduler(inner: UNReminderScheduler())
    }

    /// Preview/测试装配：内存库 + 内存调度器 + 临时目录敏感资产仓
    /// （预览不得污染生产 Documents/MedicalNotes/sensitive）。
    /// 第十一轮审查：内存调度器同样外包 ChannelGatedScheduler 投递门——
    /// 此前预览直连裸 InMemoryReminderScheduler，接线回归探针（RootAdaptiveView
    /// PreviewRoot「预览与生产同构」注释所依赖的探测能力）看不到任何通道
    /// 抑制行为，门作用域回归在预览/XCTest 上不可见。
    @MainActor
    static func preview() throws -> AppContainer {
        let store = try GRDBStore.inMemory()
        return assemble(store: store,
                        scheduler: ChannelGatedScheduler(inner: InMemoryReminderScheduler()),
                        mediaBaseDir: FileManager.default.temporaryDirectory)
    }

    /// 只读降级容器（2026-10-28 只读降级 B2）：全 store 读面 + no-op 调度器，
    /// 不挂切片 facade/checker/updater/通告面（只读壳零联网零写）；绝不经过
    /// publish/会话链（后台作业因 holder 未装天然不排）。
    @MainActor
    static func readOnly(store: GRDBStore) -> AppContainer {
        assemble(store: store, scheduler: NoopReminderScheduling())
    }

    @MainActor
    private static func assemble(store: GRDBStore, scheduler: any ReminderScheduling,
                                 mediaBaseDir: URL? = nil,
                                 degradedReason: String? = nil,
                                 catalogSlices: CatalogSliceReadFacade? = nil,
                                 catalogSliceChecker: (any CatalogSliceReleaseResolving)? = nil,
                                 catalogSliceUpdater: (any CatalogSliceInstalling)? = nil,
                                 updateAdvice: (any UpdateAdviceProviding)? = nil) -> AppContainer {
        // 引擎注册提前到组装根：资产仓等依赖注入端口的能力在组合根装配时即就位。
        // AppState.init 侧有 isRegistered 幂等守卫，重复调用不覆盖已注入桩。
        EngineRegistry.shared.registerDefaultEngines()
        let meds = MedicationStore(writer: store.writer)
        let scheduleTemplates = MedicationScheduleStore(writer: store.writer)
        let apts = AppointmentStore(writer: store.writer, scheduler: scheduler)
        let reconciler = ReminderReconciler(scheduler: scheduler, source: meds)
        let auditWriter = AuditLogWriter(writer: store.writer)
        let composer = MedicationPlanComposer(writer: store.writer)
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
        let messages = MessageDeliveryStore(writer: store.writer)
        let encounters = EncounterStore(writer: store.writer)
        let healthExams = HealthExamStore(writer: store.writer)
        let timelineQuery = TimelineQueryStore(writer: store.writer)
        let healthProblems = HealthProblemStore(writer: store.writer)
        let questions = QuestionStore(writer: store.writer)
        let memberDeletion = MemberDeletionService(writer: store.writer, scheduler: scheduler)
        let documents = DocumentStore(writer: store.writer)
        let documentExports = DocumentExportStore(writer: store.writer)
        let prescriptions = PrescriptionStore(writer: store.writer)
        let backup = BackupService(writer: store.writer)
        let pdfExport = PDFExportService(writer: store.writer)
        // FR16.1 V3.86：HKHealthStore 单实例共享（Apple 文档纪律：一进程一实例，
        // reader 与 sync service 同源注入）
        let healthKitStore = HKHealthStore()
        let healthReader = HealthKitReader(store: healthKitStore)
        let entitlements = EntitlementStore(writer: store.writer,
                                            storefront: EntitlementStore.InMemoryStorefront())
        let trends = TrendQueryStore(writer: store.writer)
        let healthSync = HealthKitSyncService(provider: healthReader, writer: healthReader,
                                              imports: HealthImportStore(writer: store.writer),
                                              guidelines: guidelines, scheduler: scheduler)
        let codeIndex = GRDBCodeIndex(writer: store.writer)
        let notificationState = NotificationStateStore(writer: store.writer)
        let notificationCenterState = NotificationCenterState(store: notificationState)
        let pendingCards = PendingCardStore(writer: store.writer)
        let voiceNotes = VoiceNoteStore(writer: store.writer)
        let chatHistory = ChatHistoryStore(writer: store.writer)
        return AppContainer(degradedReason: degradedReason,
                            store: store,
                            audit: auditWriter,
                            persistor: GRDBPatientPersistor(store: store),
                            meds: meds,
                            scheduleTemplates: scheduleTemplates,
                            apts: apts,
                            reconciler: reconciler,
                            reminderScheduler: scheduler,
                            composer: composer,
                            search: search,
                            mediaSession: MediaUnlockSession(),
                            // 装饰器链（FR12.9 审计 + 红线纵深防御）：AuditedAIProvider 记
                            // 每次调用读取的资料 ID 范围（entityId 明文传审计闭包，
                            // 由闭包内 recorder 落库；UUID 非 PHI，此处不再声称哈希）；
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
                            codeIndex: codeIndex,
                            notificationState: notificationState,
                            pendingCards: pendingCards,
                            notificationCenterState: notificationCenterState,
                            voiceNotes: voiceNotes,
                            chatHistory: chatHistory,
                            guidelines: guidelines,
                            emergencyCards: emergencyCards,
                            immunizations: immunizations,
                            messages: messages,
                            encounters: encounters,
                            healthExams: healthExams,
                            timelineQuery: timelineQuery,
                            healthProblems: healthProblems,
                            questions: questions,
                            memberDeletion: memberDeletion,
                            documents: documents,
                            documentExports: documentExports,
                             prescriptions: prescriptions,
                             backup: backup,
                             catalogSlices: catalogSlices,
                             catalogSliceChecker: catalogSliceChecker,
                             catalogSliceUpdater: catalogSliceUpdater,
                             updateAdvice: updateAdvice,
                             pdfExport: pdfExport,
                            healthReader: healthReader,
                            healthSync: healthSync)
    }

    /// 患者主库路径解析失败（B0 名字全集批，2026-10-29）：≥2 个注册名候选
    /// 并存时绝不猜哪份是用户最新档案（不按 mtime/大小挑，BR-002 同理），
    /// 启动门转为可解释失败态而非静默建空库。
    enum DatabasePathError: Error, Equatable {
        case ambiguousCandidates([String])
    }

    /// Canonical local database name (three-segment naming rule).
    static let databaseFileName = "app-local-user_data.sqlite"
    /// 非权威 schema 历史库（版本目录投影；排除备份）。
    static let schemaHistoryFileName = "app-local-schema-history.sqlite"

    /// 启动门路径解析结果（B3）：活动路径 + 目录检出的注册名候选（收据取证用）。
    struct ResolvedDatabasePath: Sendable, Equatable {
        let path: String
        let candidates: [String]
    }

    /// 启动门专用路径解析（B0）：名字全集扫描 → 单候选（含历史名）原子改名 →
    /// 返回活动库路径；≥2 候选抛 `ambiguousCandidates`（fail-closed，绝不猜测）。
    ///
    /// 旧装机只有 `vitaliber.sqlite`：单命中时先封 WAL、移动到规范名，
    /// 任何失败都回退旧路径，绝不让改名失败变成空库（语义同 v49 前实现）。
    static func resolveDatabasePath(fileManager: FileManager = .default) throws -> ResolvedDatabasePath {
        let dir = databaseDirectory(fileManager: fileManager)
        let candidates = PatientDatabaseLocator.presentNames(in: dir, fileManager: fileManager)
        switch DatabaseNameResolution.decide(presentNames: candidates) {
        case .missing:
            return ResolvedDatabasePath(
                path: dir.appendingPathComponent(databaseFileName).path,
                candidates: candidates)
        case .ambiguous(let names):
            logger.error("multiple registered database candidates found; refusing to guess: \(names.joined(separator: ", "), privacy: .public)")
            throw DatabasePathError.ambiguousCandidates(names)
        case .single(let name):
            let active = dir.appendingPathComponent(name)
            guard name.lowercased() != databaseFileName.lowercased() else {
                return ResolvedDatabasePath(path: active.path, candidates: candidates)
            }
            let target = dir.appendingPathComponent(databaseFileName)
            do {
                try DatabaseFileMigration.migrate(from: active, to: target,
                                                  fileManager: fileManager)
                return ResolvedDatabasePath(path: target.path, candidates: candidates)
            } catch {
                logger.error("数据库改名失败，继续使用旧库: \(String(describing: error), privacy: .public)")
                // 失败可能发生在移动之后（回滚也失败）：旧文件已不在时目标才是唯一副本，
                // 否则返回一个已不存在的旧路径，真实库会被当成缺失或静默新建空库。
                return ResolvedDatabasePath(
                    path: fileManager.fileExists(atPath: active.path) ? active.path : target.path,
                    candidates: candidates)
            }
        }
    }

    #if DEBUG
    /// 两段式 UI 测试钩子（2026-10-29）：在 `boot.start()` 之前同步删除患者库
    /// 全部注册名与伴生文件——用于「首启建库 → 终止 → 二启稳态」用例的
    /// 第一阶段。仅 DEBUG；生产不可达。
    static func debugErasePatientDatabaseForUITest(fileManager: FileManager = .default) {
        let dir = databaseDirectory(fileManager: fileManager)
        for name in PatientDatabaseNames.all {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let path = dir.appendingPathComponent(name + suffix).path
                if fileManager.fileExists(atPath: path) {
                    try? fileManager.removeItem(atPath: path) // try?-ok: DEBUG 钩子尽力删除
                }
            }
        }
    }
    #endif

    private static func databaseDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("VitaLiber", isDirectory: true)
        do { try fileManager.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { /* 目录创建失败由 GRDB 打开时报错，不在此吞掉 */ }
        return dir
    }

    /// 非权威便利包装（DEBUG 钩子/历史库同目录推导用）：解析失败回落规范名；
    /// 生产启动必须走 `resolveDatabasePath`（fail-closed 语义只在启动门生效）。
    static func defaultDatabasePath(fileManager: FileManager = .default) -> String {
        (try? resolveDatabasePath(fileManager: fileManager))?.path // try?-ok: 包装仅服务非决策场景，启动门走 throwing 版本
            ?? databaseDirectory(fileManager: fileManager)
                .appendingPathComponent(databaseFileName).path
    }

    /// 与患者库同目录；历史库永远不是迁移事实源，路径独立便于整体删除/重建。
    static func defaultSchemaHistoryPath(fileManager: FileManager = .default) -> String {
        URL(fileURLWithPath: defaultDatabasePath(fileManager: fileManager))
            .deletingLastPathComponent()
            .appendingPathComponent(schemaHistoryFileName)
            .path
    }

    // B0（2026-10-29）：旧「双名并存只告警」（removeLegacyDatabaseIfNeeded，且挂在
    // 生产不可达的 live(databasePath:) 死路径上）已由 resolveDatabasePath 的
    // `.ambiguousCandidates` fail-closed 取代——并存=启动失败卡，不再静默放行。

    /// bundle 发布配置资源（SP-64 信任锚/age identity）；缺省/不可读 = 未配置，
    /// 检查 fail-closed 不阻断启动（未配置≠网络错误，UI 呈「暂不可用」）。
    private static func bundledData(_ resource: String, _ ext: String) -> Data? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext) else { return nil }
        return try? Data(contentsOf: url) // try?-ok: 资源读取失败=按「未配置」fail-closed，不阻断启动
    }

    /// 独立药品目录文件：可原子替换/回滚，不触碰患者主库。
    static func defaultMedicalCatalogPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("VitaLiber/MedicalCatalog", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { /* 更新服务/只读打开路径失败时如实显示不可用 */ }
        return dir.appendingPathComponent("medical-catalog.sqlite").path
    }

    /// 三切片支持目录（2026-10-28 切片-only）：`AppSupport/VitaLiber/catalog/v5`——
    /// 与 `DatabaseBootService.v5CatalogPath` 同源（journal/floor/回执/active 均在
    /// 此目录按片命名）。
    static func defaultCatalogSliceDirectory() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("VitaLiber/catalog/v5", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { /* 打开/安装报文时如实失败 */ }
        return dir.path
    }

    /// 原件专用目录（BR-002）：`<Documents>/MedicalNotes/originals/`——
    /// 与敏感目录 `<Documents>/MedicalNotes/sensitive/` 同根（§6 文件保护分区）。
    /// 拍摄/导入原图只写一次、永不修改；预览/测试注入临时目录。
    static func defaultOriginalsDir() -> URL {
        MediaRootPaths.canonicalMedicalNotesRoot()
    }
}
