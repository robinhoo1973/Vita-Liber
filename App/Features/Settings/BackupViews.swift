import SwiftUI
import UniformTypeIdentifiers
import os
import Domain
import Infrastructure
import Perception

/// FR13.11 iCloud Drive 备份（SP-23 备份与恢复）。
///
/// **本 App 不直接读写 iCloud 容器**：备份文件经系统 `fileExporter` / `fileImporter`
/// （UIDocumentPicker）交由用户选择落点，用户选 iCloud Drive 即落 iCloud。
/// 这么做的三个理由：① 零额外权限与零 CloudKit 依赖（D1 未决，§Platform/RemotePlaceholder）；
/// ② 落点由用户显式选择，符合隐私红线「不静默上传」；③ 系统 picker 自带
/// 「未登录 iCloud / 空间不足」的原生处理，我们只需覆盖**我方可判定**的降级态。
///
/// 降级文案覆盖三态（dev-pm §3.3 退出准则）：未登录 iCloud / 空间不足 / 校验失败。
@MainActor
@Perceptible
final class BackupState {
    /// 恢复末步回调（data-flow §9.2「事务导入 → 重建 FTS/提醒/时间轴投影」）：
    /// 此前恢复后不重建提醒投影——恢复的计划在下次回前台/重启前零排程，
    /// 恢复后首剂提醒静默漏发。var：App init 内捕获 self 会触发「backupState
    /// 未初始化」编译错（L1 34288551094），改为 self 完全初始化后装配。
    var onRestored: (() async -> Void)?
    enum Phase: Equatable {
        case idle
        case working
        /// 分析中（读包+校验+冲突分析，detached；可取消——取消只丢分析结果，本机零改动）
        case analyzing
        /// 恢复码一次性展示（V1.7 切片 11：码原文零存储，展示即最后机会）
        case recoveryCodeCreated(String)
        /// 设备子密钥不可达 → 恢复码输入逃生舱（换机/钥匙串重置）
        case recoveryCodePrompt
        case exported(fileName: String, sha256: String)
        /// 真实影响清单确认（V1.7 恢复流程重构：分析前移到确认之前，
        /// 清单来自真实分析结果而非静态文案）
        case confirmRestore(records: Int, conflictCount: Int)
        /// FR13.5 恢复后数据校验报告（导入计数 + 冲突裁决三分项 + 媒体三分项）
        case restored(records: Int, kept: Int, adopted: Int, coexisted: Int,
                      mediaRestored: Int, mediaMissing: Int)
        /// ADR-019：冲突预览——逐项裁决（保留本机/采用备份/并存）后确认应用
        case conflicts([ExportService.ConflictItem])
        case degraded(String)          // 降级文案（未登录/空间不足/校验失败）
    }

    private(set) var phase: Phase = .idle
    private(set) var pendingDocument: BackupDocument?
    /// 媒体载具（.vlbm）：信封导出成功后接力导出（local-storage-layout-council 切片 11）；
    /// nil = 本库无媒体/明文模式/读取失败（信封仍有效，恢复侧按 missing 如实报告）
    private(set) var pendingCarrierDocument: BackupDocument?
    /// 恢复码输入逃生舱的暂存（来源 URL，供带码重试）
    private var pendingRestoreURL: URL?
    /// 媒体载具来源（.vlbm，与信封同次选择；nil = 无载具——恢复照常，媒体全 missing 如实报告）
    private var pendingCarrierURL: URL?
    /// 载具 security-scope 句柄（评审修复）：fileImporter 返回的 URL 仅在 scope 存续期可读——
    /// 此前载具只在分类循环里开关一拍，performRestore 读取时 scope 已释放（读取失败被
    /// try? 吞成媒体全 missing——恢复「成功」但媒体静默丢失）。scope 从分析持有到恢复完成/取消。
    private var carrierScopedURL: URL?
    private var carrierScopeActive = false
    /// 分析世代号（评审修复）：分析与恢复执行均在 Task 中挂起——取消/新一轮开始后旧任务
    /// 完成时不得再写 phase（此前 cancelAnalysis 只清状态，挂起任务回来照样跳进
    /// confirmRestore——「可取消」名存实亡；双重提交窗口同源）。
    private var analysisGeneration = 0
    /// 冲突裁决（默认保留本机——绝不静默覆盖）
    private(set) var resolutions: [UUID: ExportService.ConflictResolution] = [:]
    /// 已校验的冲突分析（含 envelope）——裁决后恢复直接复用，不再二次哈希+解码整包
    private var pendingAnalysis: BackupService.ConflictAnalysis?
    /// 待导出的加密备份包（恢复码展示确认后继续导出）
    private var pendingPackage: BackupService.BackupPackage?

    private let service: BackupService
    private let logger = Logger(subsystem: "com.vitaliber", category: "backup")

    /// iCloud 可用性判定：`ubiquityIdentityToken == nil` 即未登录 iCloud 账号。
    /// 这是 Apple 官方的登录态判定方式，且**不需要任何权限**。
    /// 审查修复：令牌查询是同步 KVS/ubiquity 协调调用，此前作为 computed
    /// property 在每次 body 求值时都查一遍——快照缓存 + 登录态变更通知刷新。
    private(set) var iCloudSignedIn: Bool
    private var ubiquityObserver: NSObjectProtocol?

    init(service: BackupService, onRestored: (() async -> Void)? = nil) {
        self.service = service
        self.onRestored = onRestored
        self.iCloudSignedIn = FileManager.default.ubiquityIdentityToken != nil
        ubiquityObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.iCloudSignedIn = FileManager.default.ubiquityIdentityToken != nil
            }
        }
    }

    /// 单流程入口门（评审修复）：.working 防重入——并发 createBackup 会在 actor 挂起点
    /// 交错（主密钥双重注册、暂存 GC 互删在飞 blob）；.recoveryCodeCreated 未确认前
    /// 不得开启新一轮——一次性码「展示即最后机会」（零存储），重跑会就地冲掉卡片；
    /// .recoveryCodePrompt 输入恢复码期间同样不得开新流程（会冲掉输入态与待恢复包）。
    /// 创建与恢复两个入口共用此门（评审修复：此前恢复只挡 .recoveryCodeCreated，
    /// .working 中可开分析——分析完成会覆写 .recoveryCodeCreated，把已排空的码卡片冲掉）。
    var canCreateBackup: Bool {
        switch phase {
        case .working, .recoveryCodeCreated, .recoveryCodePrompt,
             .analyzing, .confirmRestore, .conflicts: return false
        default: return true
        }
    }

    func prepareBackup() async {
        guard canCreateBackup else { return }
        phase = .working
        analysisGeneration += 1   // 评审修复（跨流程世代）：作废在飞分析——否则挂起分析完成时把 .working 改写回 .confirmRestore，与创建流程互相覆盖
        do {
            // 全落点默认加密（tech V3.170 分落点口径的收敛实现）：iCloud 落点强制加密，
            // 本地落点同包加密——加密只增安全不减能力，旧明文包恢复侧照读（verifiedEnvelope 自动分流）
            let pkg = try await service.createBackup(encrypted: true)
            pendingDocument = BackupDocument(data: pkg.data)
            pendingPackage = pkg
            // 媒体载具接力：读取移出主线程（数百 MB 级载具，看门狗纪律同恢复分析）
            if let carrier = pkg.mediaCarrier {
                let carrierData = try? await Task.detached(priority: .userInitiated) {   // try?-ok: 读取失败=载具不随包（信封仍有效，恢复报告 missing 如实呈现）
                    try Data(contentsOf: carrier)
                }.value
                if let carrierData {
                    pendingCarrierDocument = BackupDocument(data: carrierData)
                }
            }
            // 恢复码零知识：原文不入任何存储——展示即最后机会，确认后继续导出。
            // 成功路径先排空服务侧暂存（同码/上轮残留）：package 码优先展示，nil 时
            // 回落残留（上轮半程失败从未面世的码，评审修复）。
            let unseen = await service.takeUnseenRecoveryCode()
            if let code = pkg.recoveryCode ?? unseen {
                phase = .recoveryCodeCreated(code)
            } else {
                phase = .exported(fileName: pkg.fileName, sha256: String(pkg.sha256.prefix(12)))
            }
        } catch {
            logger.error("备份创建失败: \(error)")
            // 评审修复（跨轮残留）：本轮未产出任何包——清除上一轮未完成导出的
            // pendingDocument/pendingPackage/pendingCarrierDocument。否则失败路径的
            // 恢复码卡片确认会把陈旧包当作「本次成功包」导出（导出错件 + 假 recordBackup）。
            clearDocument()
            // 评审修复（恢复码链断点）：createBackup 可能在注册主密钥并持久化包裹段后
            // 才失败（媒体载具/密封/钥匙串后半程错误）——重试恒 nil 码，码原文零存储，
            // 此处不展示即永久丢失。有未面世码 → 走恢复码卡片（确认后回降级态）。
            if let code = await service.takeUnseenRecoveryCode() {
                phase = .recoveryCodeCreated(code)
            } else {
                // 审查修复：创建失败未必是空间不足（信封序列化/DB 读取失败同样
                // 落入此分支）——此前恒报「iCloud 空间不足」，用户清理空间后
                // 重试依旧失败。通用失败文案，不把错误原因归罪为空间。
                phase = .degraded(L10n.backupCreateFailed)
            }
        }
    }

    /// 恢复码已保存确认 → 继续导出（无待导出包 = 失败路径的一次性展示，回到失败态）。
    /// 包裹段落钥随确认穿透（评审修复：确认前不落钥，未确认进程死亡会静默吞码）。
    func confirmRecoveryCodeSaved() {
        guard case .recoveryCodeCreated = phase else { return }
        Task { await service.persistPendingRecoveryWrapped() }
        if let pkg = pendingPackage {
            phase = .exported(fileName: pkg.fileName, sha256: String(pkg.sha256.prefix(12)))
        } else {
            phase = .degraded(L10n.backupCreateFailed)
        }
    }

    /// 恢复码输入重试（设备子密钥不可达的逃生舱）
    func retryAnalysisWithRecoveryCode(_ code: String) async {
        guard case .recoveryCodePrompt = phase, let url = pendingRestoreURL else { return }
        let round = beginAnalysisRound()
        phase = .analyzing
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url)
            }.value
            guard round == analysisGeneration else { return }   // 已取消——旧轮结果作废
            let analysis = try await service.analyzeConflicts(from: data, recoveryCode: code)
            guard round == analysisGeneration else { return }
            pendingAnalysis = analysis
            pendingRestoreURL = nil
            phase = .confirmRestore(records: analysis.envelope.totalRecords,
                                    conflictCount: analysis.conflicts.count)
        } catch BackupService.BackupError.checksumMismatch {
            guard round == analysisGeneration else { return }
            // 码错/包坏——保持输入态让用户重试或取消（零部分导入）
            phase = .recoveryCodePrompt
        } catch {
            guard round == analysisGeneration else { return }
            logger.error("恢复码重试分析失败: \(error)")
            // 评审修复（载具 scope 泄漏）：终止态不保留 security-scope 句柄
            discardCarrierScope()
            phase = .degraded(L10n.backupRestoreFailed)
        }
    }

    /// 选文件后的后台分析（V1.7 恢复流程重构）：读包 + 校验 + 冲突分析，
    /// 产出真实影响清单进确认态——分析完成前用户看不到静态「覆盖」承诺
    func analyzeRestore(from url: URL, carrierURL: URL? = nil) async {
        guard canCreateBackup else { return }   // 评审修复：任何进行中流程/码展示中禁启分析（覆写 phase 冲掉一次性码或半程流程）
        let round = beginAnalysisRound()
        // 载具 security-scope 自分析起持有（评审修复）：读取窗口必须覆盖 performRestore
        // 的 importMediaCarrier 调用；此前分类循环一拍即释，恢复侧读取静默失败。
        beginCarrierScope(carrierURL)
        pendingCarrierURL = carrierURL
        phase = .analyzing
        // security-scoped：picker 返回的 URL 需显式取用权限，否则读取静默失败
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            // 第八轮全仓审查修复（主线程大文件读）：整包 Data(contentsOf:)
            // 是同步读——数百 MB 备份此前在 MainActor 上执行，冻结 UI 且有
            // 看门狗杀进程风险。detached 移出主线程（security-scoped 句柄
            // 在调用方线程已取用，读取无需主线程）。
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url)
            }.value
            guard round == analysisGeneration else { return }
            // ADR-019：先分析冲突——校验后的 envelope 随分析返回，
            // 确认/恢复路径复用（整包只哈希+解码一次）
            let analysis = try await service.analyzeConflicts(from: data)
            guard round == analysisGeneration else { return }
            pendingAnalysis = analysis
            phase = .confirmRestore(records: analysis.envelope.totalRecords,
                                    conflictCount: analysis.conflicts.count)
        } catch BackupService.BackupError.checksumMismatch {
            guard round == analysisGeneration else { return }
            // v2 加密包 + 设备子密钥不可达（换机/钥匙串重置）→ 恢复码逃生舱；
            // 明文包校验失败 = 真损坏，如实报错。
            // 版本判定只读帧头（评审修复）：此前 try? Data(contentsOf:) 把整包
            //（可达数百 MB）在 MainActor 上同步重读一遍——校验失败路径再冻 UI 一次。
            // 帧头判定归 EnvelopeFrame.binaryFormatVersion（评审修复：此外此前内联
            // 一份魔数/版本逐字节判定，两处漂移即逃生舱静默失效）。
            let headVersion: UInt8? = {
                guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }   // try?-ok: 头读失败=走损坏文案
                defer { try? handle.close() }                                                // try?-ok: 关闭失败无补救面
                guard let head = try? handle.read(upToCount: EnvelopeFrame.binaryMagic.count + 1) else { return nil }   // try?-ok: 读取失败=走损坏文案
                return EnvelopeFrame.binaryFormatVersion(head)
            }()
            if headVersion == 2 {
                pendingRestoreURL = url
                phase = .recoveryCodePrompt
            } else {
                // 评审修复（载具 scope 泄漏）：降级终态不保留 security-scope 句柄
                discardCarrierScope()
                phase = .degraded(L10n.backupChecksumFailed)
            }
        } catch BackupService.BackupError.unsupportedFormat {
            guard round == analysisGeneration else { return }
            // 校验失败绝不部分导入——本机数据保持原样；载具 scope 同款收尾（评审修复）
            discardCarrierScope()
            phase = .degraded(L10n.backupChecksumFailed)
        } catch {
            guard round == analysisGeneration else { return }
            logger.error("备份分析失败: \(error)")
            // 第八轮修复同族：非校验类失败不归罪文件损坏；载具 scope 同款收尾（评审修复）
            discardCarrierScope()
            phase = .degraded(L10n.backupRestoreFailed)
        }
    }

    /// 影响清单确认后应用：无冲突直接恢复；有冲突进入逐项裁决预览（默认 keep）
    func applyRestore() async {
        guard case .confirmRestore = phase, let analysis = pendingAnalysis else { return }
        guard !analysis.conflicts.isEmpty else {
            phase = .working
            await performRestore(analysis, resolutions: [:])
            return
        }
        resolutions = Dictionary(uniqueKeysWithValues: analysis.conflicts.map { ($0.id, .keep) })
        phase = .conflicts(analysis.conflicts)
    }

    /// 恢复执行 + 报告（成功/冲突裁决三分项 + 媒体三分项——V1.7 报告卡）
    private func performRestore(_ analysis: BackupService.ConflictAnalysis,
                                resolutions: [UUID: ExportService.ConflictResolution]) async {
        defer { endCarrierScope() }   // 载具读取窗口收尾（成功/冲突/失败全路径）
        do {
            // 媒体先行（local-storage-layout-council §8 切片 12）：文件先落（幂等可重入）→
            // DB 单事务；两路独立成败——载具缺失/密钥不可解=媒体全 missing，DB 恢复照常
            let claimed = analysis.envelope.media?.map(\.sha256) ?? []
            var mediaReport = MediaImportReport(missing: claimed)
            if let carrierURL = pendingCarrierURL, let masterKey = analysis.masterKey {
                mediaReport = (try? await service.importMediaCarrier(from: carrierURL, masterKey: masterKey))   // try?-ok: 载具导入失败=全 missing（DB 恢复照常，绝不因载具阻断恢复）
                    ?? MediaImportReport(missing: claimed)
            }
            let records = try await service.restore(envelope: analysis.envelope, resolutions: resolutions)
            let kept = resolutions.values.filter { $0 == .keep }.count
            let adopted = resolutions.values.filter { $0 == .adopt }.count
            let coexisted = resolutions.values.filter { $0 == .coexist }.count
            pendingAnalysis = nil
            self.resolutions = [:]
            pendingCarrierURL = nil
            phase = .restored(records: records, kept: kept, adopted: adopted, coexisted: coexisted,
                              mediaRestored: mediaReport.imported + mediaReport.alreadyPresent,
                              mediaMissing: mediaReport.missing.count)
            await onRestored?()   // 恢复末步重建提醒投影（恢复的计划立即进入排程）
        } catch BackupService.BackupError.conflictDetected {
            logger.error("冲突裁决不完整")
            phase = .degraded(L10n.backupConflictDetected)
        } catch {
            logger.error("恢复失败: \(error)")
            phase = .degraded(L10n.backupRestoreFailed)
        }
    }

    /// 同步候选导入（批次 2 切片 D）：与文件恢复同一条管线——
    /// 分析 → 真实影响清单 → (冲突三选一) → 恢复报告；整包只哈希+解码一次。
    /// 评审修复：同步候选无载具——先清残留载具态（此前若上一轮文件恢复被放弃，
    /// pendingCarrierURL/scope 会跨到同步恢复，载具错配）。
    func analyzeSyncCandidate(_ data: Data) async -> Bool {
        guard canCreateBackup else { return false }   // 评审修复：进行中流程/码展示中禁启分析（覆写 phase 冲掉一次性码或半程流程）
        let round = beginAnalysisRound()
        discardCarrierScope()
        phase = .analyzing
        do {
            let analysis = try await service.analyzeConflicts(from: data)
            guard round == analysisGeneration else { return true }
            pendingAnalysis = analysis
            phase = .confirmRestore(records: analysis.envelope.totalRecords,
                                    conflictCount: analysis.conflicts.count)
        } catch BackupService.BackupError.checksumMismatch {
            guard round == analysisGeneration else { return true }
            phase = .degraded(L10n.backupChecksumFailed)
        } catch {
            guard round == analysisGeneration else { return true }
            logger.error("同步候选分析失败: \(error)")
            phase = .degraded(L10n.backupRestoreFailed)
        }
        return true   // 已进入本页流程（成功/降级文案均在 BackupView 呈现）
    }

    /// 多选里没有可识别信封 → 降级文案（评审修复：此前 guard 静默 return，
    /// 用户点「恢复」后毫无反馈）
    func reportMissingEnvelope() {
        guard canCreateBackup else { return }   // 评审修复：进行中流程/码展示中禁覆写 phase
        phase = .degraded(L10n.backupRestoreFailed)
    }

    /// 分析阶段取消（只丢分析结果，本机零改动）
    func cancelAnalysis() {
        analysisGeneration += 1   // 作废在飞分析：挂起任务完成时按世代丢弃，不再写 phase
        pendingAnalysis = nil
        pendingRestoreURL = nil
        discardCarrierScope()
        phase = .idle
    }

    func setResolution(_ id: UUID, _ choice: ExportService.ConflictResolution) {
        resolutions[id] = choice
    }

    /// 应用裁决并恢复（ADR-019：确认后才执行；任何一项未裁决均已在服务层拒绝）
    func applyConflicts() async {
        guard case .conflicts = phase, let analysis = pendingAnalysis else { return }
        phase = .working
        await performRestore(analysis, resolutions: resolutions)
    }

    func cancelConflicts() {
        pendingAnalysis = nil
        resolutions = [:]
        // 评审修复（载具 scope 泄漏）：与 cancelAnalysis 同款收尾——此前取消裁决
        // 不释放 security-scope 也不清 pendingCarrierURL（句柄跨会话滞留、下一轮
        // 文件选择的载具错配基准残留）。
        discardCarrierScope()
        phase = .idle
    }

    func clearDocument() {
        pendingDocument = nil
        pendingPackage = nil
        pendingCarrierDocument = nil
    }

    // MARK: - 分析世代 / 载具 scope（评审修复：取消语义 + 读取窗口）

    /// 开启新一轮分析（世代号自增；旧轮完成时按世代不匹配丢弃）
    private func beginAnalysisRound() -> Int {
        analysisGeneration += 1
        return analysisGeneration
    }

    /// 取用媒体载具的 security-scoped 访问（读取窗口 = 分析 → 恢复完成/取消）
    private func beginCarrierScope(_ url: URL?) {
        endCarrierScope()
        guard let url else { return }
        carrierScopedURL = url
        carrierScopeActive = url.startAccessingSecurityScopedResource()
    }

    private func endCarrierScope() {
        if carrierScopeActive, let url = carrierScopedURL {
            url.stopAccessingSecurityScopedResource()
        }
        carrierScopedURL = nil
        carrierScopeActive = false
    }

    /// 载具读取窗口收尾（评审修复）：降级/取消终态不保留 security-scope 句柄与
    /// pendingCarrierURL 残留——各终态分支统一入口（此前 7 处复制两行，新增分支易漏清一半）。
    private func discardCarrierScope() {
        pendingCarrierURL = nil
        endCarrierScope()
    }
}

/// `fileExporter` 需要的 FileDocument 包装（纯字节搬运，无业务逻辑）。
/// 审查修复：备份信封已改为二进制（.vlbu）——content type 用 .data，
/// 遗留 .json 备份继续可导入（restore 双格式兼容）
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct BackupView: View {
    @Environment(BackupState.self) private var state
    @Environment(AppState.self) private var app
    @Environment(AppSettingsStore.self) private var settings
    @Environment(AppEntitlementStore.self) private var entitlements
    @Environment(ReminderStore.self) private var reminderStore
    @State private var showExporter = false
    @State private var showCarrierExporter = false
    @State private var showImporter = false
    @State private var showExportConfirm = false
    @State private var recoveryCodeInput = ""

    var body: some View {
        WithPerceptionTracking {
            List {
                Section {
                    // FR14.1 authCloudBackup 消费点：关闭 → iCloud 项呈降级说明
                    // （本地「保存到文件」导出不受影响），撤回即时生效
                    if settings.values[.authCloudBackup] == "false" {
                        Label(L10n.privacyAuthBackupDisabled, systemImage: "icloud.slash")
                            .font(.footnote)
                            .foregroundStyle(Color("semantic-warning", bundle: .main))
                            .accessibilityIdentifier("SP-23.backup.authDisabled")
                    }
                    if !state.iCloudSignedIn {
                        // 未登录 iCloud：不隐藏功能，只如实说明落点受限（仍可导出到本机）
                        Label(L10n.backupNotSignedIn, systemImage: "icloud.slash")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("SP-23.backup.notSignedIn")
                    }
                    Button {
                        Task {
                            // 订阅门槛（comercial V1.12）：备份本体订阅——未解锁先弹墙（24h 频控在
                            // gateProBase→evaluateTrigger），已解锁走既有导出前身份验证；
                            // 导出（FR13.2/13.3）恒免费不受此门槛
                            guard entitlements.gateProBase(.backupFirstTap) else { return }
                            // FR13.4：导出前身份验证（门禁复用）——验证通过才进入隐私确认
                            guard await app.requestUnlock(reason: L10n.backupUnlockReason) else { return }
                            showExportConfirm = true
                        }
                    } label: {
                        Label(L10n.backupCreate, systemImage: "icloud.and.arrow.up").frame(minHeight: 44)
                    }
                    // 评审修复：进行中/恢复码未确认时不可重入（与 prepareBackup 入口门同源）
                    .disabled(!state.canCreateBackup)
                    .accessibilityIdentifier("SP-23.backup.create")

                    Button {
                        // 订阅门槛（comercial V1.12）：恢复同属订阅本体
                        guard entitlements.gateProBase(.backupFirstTap) else { return }
                        showImporter = true
                    } label: {
                        Label(L10n.backupRestore, systemImage: "icloud.and.arrow.down").frame(minHeight: 44)
                    }
                    // 评审修复（单流程门）：与创建同门——进行中流程/恢复码展示中禁启恢复，
                    // 分析会覆写 phase 冲掉码卡片或半程流程（码零存储，冲掉即永久丢失）
                    .disabled(!state.canCreateBackup)
                    .accessibilityIdentifier("SP-23.backup.restore")
                } footer: {
                    Text(L10n.backupScopeNote)
                        .font(.caption2)
                }

                // FR13.10 定期备份提醒间隔可配置（V4.20）：7/30/90/关；
                // 提醒只引导到备份入口，绝不自动创建备份文件。
                // 型检超时拆分（CI #38926490206 报点 503=间隔 Picker 首 tag）：
                // Section 迁出为显式 @Binding 子视图（见 BackupIntervalSection）。
                BackupIntervalSection(interval: Binding(
                    get: { Int(settings.values[.backupReminderIntervalDays] ?? "") ?? BackupReminderRules.defaultIntervalDays },
                    set: { newValue in
                        Task {
                            await settings.set("\(newValue)", for: .backupReminderIntervalDays)
                            // 评审修复（关档即时生效）：0=关闭须立即撤销已武装/在途提醒——
                            // 排程评估只在冷启动跑，仅改设置则本次会话内先前武装的提醒照常
                            // 触发（「关档遗留提醒」只被延后到下次冷启动）。
                            if newValue == 0 { await reminderStore.clearBackupReminderDelivered() }
                        }
                    }
                ))

                switch state.phase {
                case .conflicts(let items):
                    // ADR-019 冲突预览：逐项裁决（保留本机/采用备份/并存），
                    // 确认后整体应用——绝不静默覆盖或丢弃
                    Section(L10n.backupConflictTitle) {
                        ForEach(items) { item in
                            // 型检超时拆分（CI #38926490206）：行内容迁出到显式类型子视图
                            BackupConflictRow(item: item, choice: conflictChoice(item.id))
                        }
                        Button(L10n.backupConflictApply) {
                            Task { await state.applyConflicts() }
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("SP-23.conflict.apply")
                        Button(L10n.commonCancel, role: .cancel) {
                            state.cancelConflicts()
                        }
                        .frame(minHeight: 44)
                        // SwiftUI 无「字符串标题 + footer」的 Section 初始化器，
                        // hint 落内容区脚注（与 footer 视觉等价）
                        Text(L10n.backupConflictHint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                case .exported(let name, let digest):
                    Section {
                        Label(L10n.backupExportedName(name), systemImage: "checkmark.circle")
                            .accessibilityIdentifier("SP-23.backup.exported")
                        Text(L10n.backupChecksum(digest)).font(.caption2).monospaced()
                            .foregroundStyle(.secondary)
                    }
                case .analyzing:
                    Section {
                        HStack {
                            ProgressView()
                            Text(L10n.backupAnalyzing)
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("SP-23.backup.analyzing")
                        Button(L10n.commonCancel, role: .cancel) {
                            state.cancelAnalysis()
                        }
                        .frame(minHeight: 44)
                    }
                case .recoveryCodeCreated(let code):
                    // 恢复码一次性展示（零知识：原文不入存储——展示即最后机会）
                    Section {
                        Label(L10n.backupRecoveryCodeTitle, systemImage: "key.fill")
                        Text(code)
                            .font(VLFont.recoveryCode)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("SP-23.backup.recoveryCode")
                        Text(L10n.backupRecoveryCodeBody)
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(L10n.backupRecoveryCodeSaved) {
                            state.confirmRecoveryCodeSaved()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("SP-23.backup.recoveryCode.saved")
                    }
                case .recoveryCodePrompt:
                    // 设备子密钥不可达 → 恢复码输入逃生舱（码错保持输入态，零部分导入）
                    Section {
                        Label(L10n.backupRecoveryCodePromptTitle, systemImage: "key")
                        TextField(L10n.backupRecoveryCodePromptTitle, text: $recoveryCodeInput)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("SP-23.backup.recoveryCode.input")
                        Button(L10n.onboard_confirm) {
                            let code = recoveryCodeInput
                            recoveryCodeInput = ""
                            Task { await state.retryAnalysisWithRecoveryCode(code) }
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        Button(L10n.commonCancel, role: .cancel) {
                            state.cancelAnalysis()
                        }
                        .frame(minHeight: 44)
                    } footer: {
                        Text(L10n.backupRecoveryCodePromptBody)
                            .font(.caption2)
                    }
                case .confirmRestore(let records, let conflicts):
                    // V1.7 真实影响清单：清单来自分析结果而非静态文案
                    Section {
                        Label(L10n.backupConfirmImpactTitle, systemImage: "checkmark.shield")
                        Text(L10n.backupConfirmImpact(records, conflicts))
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(L10n.onboard_confirm) {
                            Task { await state.applyRestore() }
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("SP-23.backup.apply")
                        Button(L10n.commonCancel, role: .cancel) {
                            state.cancelAnalysis()
                        }
                        .frame(minHeight: 44)
                    } footer: {
                        Text(L10n.backupRestoreConfirmBody)
                            .font(.caption2)
                    }
                case .restored(let records, let kept, let adopted, let coexisted,
                               let mediaRestored, let mediaMissing):
                    // FR13.5 恢复后数据校验报告（V1.7 报告卡）：导入计数 + 冲突裁决三分项 + 媒体三分项
                    Section {
                        Label(L10n.backupRestoredCount(records), systemImage: "checkmark.circle")
                            .accessibilityIdentifier("SP-23.backup.restored")
                        Text(L10n.backupRestoreReport(kept: kept, adopted: adopted, coexisted: coexisted))
                            .font(.caption2).foregroundStyle(.secondary)
                        if mediaRestored > 0 || mediaMissing > 0 {
                            Text(L10n.backupMediaReport(restored: mediaRestored, missing: mediaMissing))
                                .font(.caption2).foregroundStyle(.secondary)
                                .accessibilityIdentifier("SP-23.backup.mediaReport")
                        }
                    }
                case .degraded(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .accessibilityIdentifier("SP-23.backup.degraded")
                case .working:
                    ProgressView().accessibilityIdentifier("SP-23.backup.working")
                case .idle:
                    EmptyView()
                }
            }
            .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出
            .tintedCanvas()   // 渐变直挂本容器（根级背景会被 TabView/导航栈系统底色覆盖，V4.06 修正）
            .navigationTitle(L10n.backupTitle)
            // FR13.4 L4 操作前确认：导出隐私提醒（明示导出内容敏感级别）
            .alert(L10n.backupExportConfirmTitle, isPresented: $showExportConfirm) {
                Button(L10n.commonCancel, role: .cancel) { }
                Button(L10n.onboard_confirm) {
                    Task { await state.prepareBackup() }
                }
            } message: {
                Text(L10n.backupExportConfirmBody)
            }
            // 导出器呈现改由阶段观察驱动：恢复码一次性展示确认后 phase 才进 exported
            // （审查修复：原实现在 prepareBackup 内联判断 exported 即弹——恢复码展示态会漏弹导出器）
            .onChangeCompat(of: state.phase) { _, newPhase in
                if case .exported = newPhase {
                    showExporter = true
                    // 审查修复：recordBackup 移入 fileExporter 成功分支——
                    // 原实现用户取消系统导出器也留下「最近备份」时间戳
                    // （FR13.10/F22.4 展示假事实）
                }
            }
            .fileExporter(isPresented: $showExporter,
                          document: state.pendingDocument,
                          contentType: .data,
                          defaultFilename: "vitaliber-backup") { result in
                switch result {
                case .success:
                    // FR13.10/F22.4：备份**实际落盘成功**才记时（审查修复：
                    // 取消导出不得留下假时间戳）
                    app.recordBackup()
                    // 媒体载具接力导出（local-storage-layout-council 切片 11）：
                    // 信封落盘成功后接续导出 .vlbm——取消只缺媒体不丢信封
                    if state.pendingCarrierDocument != nil {
                        showCarrierExporter = true
                        return
                    }
                case .failure(let error):
                    // 系统 picker 失败最常见的可归因原因就是空间不足
                    Logger(subsystem: "com.vitaliber", category: "backup")
                        .error("导出落点失败: \(error)")
                }
                state.clearDocument()
            }
            .fileExporter(isPresented: $showCarrierExporter,
                          document: state.pendingCarrierDocument,
                          contentType: .data,
                          defaultFilename: "vitaliber-media") { _ in
                // 载具导出成败均收尾（信封已落盘；载具缺失由恢复报告如实呈现）
                state.clearDocument()
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.data, .json],
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                // 多选（local-storage-layout-council 切片 12）：信封 .vlbu 与媒体载具 .vlbm
                // 同次选择；按文件头分类（VLBU1 魔数/JSON 首字节 = 信封，其余 = 载具）。
                // 只选信封也合法——载具缺失由恢复报告如实呈现（绝不伪造）。
                var envelopeURL: URL?
                var carrierURL: URL?
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    // 评审修复：FileHandle 此前不关闭（句柄泄漏）；分类魔数复用单点常量
                    let head: Data = {
                        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }   // try?-ok: 头部读取失败=无法分类，该文件跳过
                        defer { try? handle.close() }                                                    // try?-ok: 关闭失败无补救面
                        return (try? handle.read(upToCount: 8)) ?? Data()                                // try?-ok: 同上
                    }()
                    if head.starts(with: EnvelopeFrame.binaryMagic) || head.first == 0x7B {   // "{" = 遗留 JSON 信封
                        envelopeURL = url
                    } else if carrierURL == nil {
                        carrierURL = url
                    }
                }
                guard let envelopeURL else {
                    // 评审修复：此前静默 return——多选里没有信封时点「恢复」毫无反馈
                    state.reportMissingEnvelope()
                    return
                }
                // FR13.5/V1.7 恢复流程：选文件 → 门禁 → 后台分析 →
                // 真实影响清单确认 → (冲突裁决) → 恢复报告
                Task {
                    guard await app.requestUnlock(reason: L10n.backupUnlockReason) else { return }
                    await state.analyzeRestore(from: envelopeURL, carrierURL: carrierURL)
                }
            }
        }
    }

    /// ADR-019：表名 → 可读类别（Infrastructure 不携带展示文案）
    fileprivate static func conflictKindLabel(_ table: String) -> String {
        switch table {
        case "patient_profile", "local_owner": return L10n.backupConflictKindProfile
        case "consent_record": return L10n.backupConflictKindConsent
        case "document_file": return L10n.backupConflictKindDocument
        default: return L10n.backupConflictKindRecord
        }
    }

    private func conflictChoice(_ id: UUID) -> Binding<ExportService.ConflictResolution> {
        Binding(
            get: { state.resolutions[id] ?? .keep },
            set: { state.setResolution(id, $0) })
    }
}

/// 备份提醒间隔 Section（型检超时拆分，CI #38926490206 报点 503=间隔 Picker 首 tag）：
/// 内联 Binding(get:set:) 含 Task 闭包 + Picker 四 tag 的推断组合是超时主源，
/// 迁出为显式 @Binding 类型子视图后推断成本归零。
private struct BackupIntervalSection: View {
    @Binding var interval: Int

    var body: some View {
        // 注：Section(String){…} footer: 形态在本 SDK 无匹配 init（L10n 键是 String——
        // 原巨表达式内的同形调用即有此潜伏错误,被型检超时掩盖）;带标题+footer 一律
        // header:/footer: 形态（本文件 480/585/605 与 PreferencesViews 同款先例）。
        Section {
            Picker(L10n.backupReminderIntervalTitle, selection: $interval) {
                Text(L10n.backupReminderIntervalOff).tag(0)
                Text(L10n.backupReminderInterval7).tag(7)
                Text(L10n.backupReminderInterval30).tag(30)
                Text(L10n.backupReminderInterval90).tag(90)
            }
            .accessibilityIdentifier("SP-23.backup.interval")
        } header: {
            Text(L10n.backupReminderIntervalTitle)
        } footer: {
            Text(L10n.backupReminderIntervalNote)
                .font(.caption2)
        }
    }
}

/// 冲突行子视图（型检超时拆分，CI #38926490206）：自 BackupView 巨表达式迁出，
/// 显式 item/choice 类型——ForEach 闭包 + Picker 三 tag 的推断成本是超时主源。
/// ADR-019 逐项裁决语义不变（保留本机/采用备份/并存，确认后整体应用）。
private struct BackupConflictRow: View {
    let item: ExportService.ConflictItem
    @Binding var choice: ExportService.ConflictResolution

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(BackupView.conflictKindLabel(item.table))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.docTitle(item.backupTitle ?? item.existingTitle))
                .font(.subheadline)
            // V1.7 双值对比：本机摘要 vs 备份摘要（字段级三列对比登记债：
            // 跨库实体身份与逐字段 diff 属批次 2/D1 议题，design V1.7 §5.4）
            if let existing = item.existingTitle {
                Text("\(L10n.backupConflictExisting) \(L10n.docTitle(existing))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let backup = item.backupTitle {
                Text("\(L10n.backupConflictBackup) \(L10n.docTitle(backup))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker(L10n.backupConflictChoice, selection: $choice) {
                Text(L10n.backupConflictKeep).tag(ExportService.ConflictResolution.keep)
                Text(L10n.backupConflictAdopt).tag(ExportService.ConflictResolution.adopt)
                Text(L10n.backupConflictCoexist).tag(ExportService.ConflictResolution.coexist)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("SP-23.conflict.choice.\(item.id.uuidString)")
        }
        .padding(.vertical, 4)
    }
}
