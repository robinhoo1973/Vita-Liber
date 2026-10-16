import SwiftUI
import UniformTypeIdentifiers
import os
import Domain
import Infrastructure
import Perception

/// FR13.11 iCloud Drive 备份（SP-24 备份与恢复）。
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
        case exported(fileName: String, sha256: String)
        /// 真实影响清单确认（V1.7 恢复流程重构：分析前移到确认之前，
        /// 清单来自真实分析结果而非静态文案）
        case confirmRestore(records: Int, conflictCount: Int)
        /// FR13.5 恢复后数据校验报告（导入计数 + 冲突裁决三分项）
        case restored(records: Int, kept: Int, adopted: Int, coexisted: Int)
        /// ADR-019：冲突预览——逐项裁决（保留本机/采用备份/并存）后确认应用
        case conflicts([ExportService.ConflictItem])
        case degraded(String)          // 降级文案（未登录/空间不足/校验失败）
    }

    private(set) var phase: Phase = .idle
    private(set) var pendingDocument: BackupDocument?
    /// 冲突裁决（默认保留本机——绝不静默覆盖）
    private(set) var resolutions: [UUID: ExportService.ConflictResolution] = [:]
    /// 已校验的冲突分析（含 envelope）——裁决后恢复直接复用，不再二次哈希+解码整包
    private var pendingAnalysis: BackupService.ConflictAnalysis?

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

    func prepareBackup() async {
        phase = .working
        do {
            // 全落点默认加密（tech V3.170 分落点口径的收敛实现）：iCloud 落点强制加密，
            // 本地落点同包加密——加密只增安全不减能力，旧明文包恢复侧照读（verifiedEnvelope 自动分流）
            let pkg = try await service.createBackup(encrypted: true)
            pendingDocument = BackupDocument(data: pkg.data)
            phase = .exported(fileName: pkg.fileName, sha256: String(pkg.sha256.prefix(12)))
        } catch {
            logger.error("备份创建失败: \(error)")
            // 审查修复：创建失败未必是空间不足（信封序列化/DB 读取失败同样
            // 落入此分支）——此前恒报「iCloud 空间不足」，用户清理空间后
            // 重试依旧失败。通用失败文案，不把错误原因归罪为空间。
            phase = .degraded(L10n.backupCreateFailed)
        }
    }

    /// 选文件后的后台分析（V1.7 恢复流程重构）：读包 + 校验 + 冲突分析，
    /// 产出真实影响清单进确认态——分析完成前用户看不到静态「覆盖」承诺
    func analyzeRestore(from url: URL) async {
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
            // ADR-019：先分析冲突——校验后的 envelope 随分析返回，
            // 确认/恢复路径复用（整包只哈希+解码一次）
            let analysis = try await service.analyzeConflicts(from: data)
            pendingAnalysis = analysis
            phase = .confirmRestore(records: analysis.envelope.totalRecords,
                                    conflictCount: analysis.conflicts.count)
        } catch BackupService.BackupError.checksumMismatch,
                BackupService.BackupError.unsupportedFormat {
            // 校验失败绝不部分导入——本机数据保持原样
            phase = .degraded(L10n.backupChecksumFailed)
        } catch {
            logger.error("备份分析失败: \(error)")
            // 第八轮修复同族：非校验类失败不归罪文件损坏
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

    /// 恢复执行 + 报告（成功/冲突裁决三分项——V1.7 报告卡）
    private func performRestore(_ analysis: BackupService.ConflictAnalysis,
                                resolutions: [UUID: ExportService.ConflictResolution]) async {
        do {
            let records = try await service.restore(envelope: analysis.envelope, resolutions: resolutions)
            let kept = resolutions.values.filter { $0 == .keep }.count
            let adopted = resolutions.values.filter { $0 == .adopt }.count
            let coexisted = resolutions.values.filter { $0 == .coexist }.count
            pendingAnalysis = nil
            self.resolutions = [:]
            phase = .restored(records: records, kept: kept, adopted: adopted, coexisted: coexisted)
            await onRestored?()   // 恢复末步重建提醒投影（恢复的计划立即进入排程）
        } catch BackupService.BackupError.conflictDetected {
            logger.error("冲突裁决不完整")
            phase = .degraded(L10n.backupConflictDetected)
        } catch {
            logger.error("恢复失败: \(error)")
            phase = .degraded(L10n.backupRestoreFailed)
        }
    }

    /// 分析阶段取消（只丢分析结果，本机零改动）
    func cancelAnalysis() {
        pendingAnalysis = nil
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
        phase = .idle
    }

    func clearDocument() { pendingDocument = nil }
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
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var showExportConfirm = false

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
                            .accessibilityIdentifier("SP-24.backup.authDisabled")
                    }
                    if !state.iCloudSignedIn {
                        // 未登录 iCloud：不隐藏功能，只如实说明落点受限（仍可导出到本机）
                        Label(L10n.backupNotSignedIn, systemImage: "icloud.slash")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("SP-24.backup.notSignedIn")
                    }
                    Button {
                        Task {
                            // 订阅门槛（comercial V1.12）：备份本体订阅——未解锁先弹墙（24h 频控在 evaluateTrigger），
                            // 已解锁走既有导出前身份验证；导出（FR13.2/13.3）恒免费不受此门槛
                            guard entitlements.owned.contains(.proBase) else {
                                _ = entitlements.evaluateTrigger(.backupFirstTap)
                                return
                            }
                            // FR13.4：导出前身份验证（门禁复用）——验证通过才进入隐私确认
                            guard await app.requestUnlock(reason: L10n.backupUnlockReason) else { return }
                            showExportConfirm = true
                        }
                    } label: {
                        Label(L10n.backupCreate, systemImage: "icloud.and.arrow.up").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("SP-24.backup.create")

                    Button {
                        // 订阅门槛（comercial V1.12）：恢复同属订阅本体
                        guard entitlements.owned.contains(.proBase) else {
                            _ = entitlements.evaluateTrigger(.backupFirstTap)
                            return
                        }
                        showImporter = true
                    } label: {
                        Label(L10n.backupRestore, systemImage: "icloud.and.arrow.down").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("SP-24.backup.restore")
                } footer: {
                    Text(L10n.backupScopeNote)
                        .font(.caption2)
                }

                // FR13.10 定期备份提醒间隔可配置（V4.20）：7/30/90/关；
                // 提醒只引导到备份入口，绝不自动创建备份文件
                Section(L10n.backupReminderIntervalTitle) {
                    Picker(L10n.backupReminderIntervalTitle, selection: Binding(
                        get: { Int(settings.values[.backupReminderIntervalDays] ?? "") ?? BackupReminderRules.defaultIntervalDays },
                        set: { newValue in
                            Task { await settings.set("\(newValue)", for: .backupReminderIntervalDays) }
                        }
                    )) {
                        Text(L10n.backupReminderIntervalOff).tag(0)
                        Text(L10n.backupReminderInterval7).tag(7)
                        Text(L10n.backupReminderInterval30).tag(30)
                        Text(L10n.backupReminderInterval90).tag(90)
                    }
                    .accessibilityIdentifier("SP-24.backup.interval")
                } footer: {
                    Text(L10n.backupReminderIntervalNote)
                        .font(.caption2)
                }

                switch state.phase {
                case .conflicts(let items):
                    // ADR-019 冲突预览：逐项裁决（保留本机/采用备份/并存），
                    // 确认后整体应用——绝不静默覆盖或丢弃
                    Section(L10n.backupConflictTitle) {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(conflictKindLabel(item.table))
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
                                Picker(L10n.backupConflictChoice, selection: conflictChoice(item.id)) {
                                    Text(L10n.backupConflictKeep).tag(ExportService.ConflictResolution.keep)
                                    Text(L10n.backupConflictAdopt).tag(ExportService.ConflictResolution.adopt)
                                    Text(L10n.backupConflictCoexist).tag(ExportService.ConflictResolution.coexist)
                                }
                                .pickerStyle(.segmented)
                                .accessibilityIdentifier("SP-24.conflict.choice.\(item.id.uuidString)")
                            }
                            .padding(.vertical, 4)
                        }
                        Button(L10n.backupConflictApply) {
                            Task { await state.applyConflicts() }
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("SP-24.conflict.apply")
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
                            .accessibilityIdentifier("SP-24.backup.exported")
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
                        .accessibilityIdentifier("SP-24.backup.analyzing")
                        Button(L10n.commonCancel, role: .cancel) {
                            state.cancelAnalysis()
                        }
                        .frame(minHeight: 44)
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
                        .accessibilityIdentifier("SP-24.backup.apply")
                        Button(L10n.commonCancel, role: .cancel) {
                            state.cancelAnalysis()
                        }
                        .frame(minHeight: 44)
                    } footer: {
                        Text(L10n.backupRestoreConfirmBody)
                            .font(.caption2)
                    }
                case .restored(let records, let kept, let adopted, let coexisted):
                    // FR13.5 恢复后数据校验报告（V1.7 报告卡）：导入计数 + 冲突裁决三分项
                    Section {
                        Label(L10n.backupRestoredCount(records), systemImage: "checkmark.circle")
                            .accessibilityIdentifier("SP-24.backup.restored")
                        Text(L10n.backupRestoreReport(kept: kept, adopted: adopted, coexisted: coexisted))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                case .degraded(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .accessibilityIdentifier("SP-24.backup.degraded")
                case .working:
                    ProgressView().accessibilityIdentifier("SP-24.backup.working")
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
                    Task {
                        await state.prepareBackup()
                        if case .exported = state.phase {
                            showExporter = true
                            // 审查修复：recordBackup 移入 fileExporter 成功分支——
                            // 原实现用户取消系统导出器也留下「最近备份」时间戳
                            // （FR13.10/F22.4 展示假事实）
                        }
                    }
                }
            } message: {
                Text(L10n.backupExportConfirmBody)
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
                case .failure(let error):
                    // 系统 picker 失败最常见的可归因原因就是空间不足
                    Logger(subsystem: "com.vitaliber", category: "backup")
                        .error("导出落点失败: \(error)")
                }
                state.clearDocument()
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.data, .json]) { result in
                guard case .success(let url) = result else { return }
                // FR13.5/V1.7 恢复流程：选文件 → 门禁 → 后台分析 →
                // 真实影响清单确认 → (冲突裁决) → 恢复报告
                Task {
                    guard await app.requestUnlock(reason: L10n.backupUnlockReason) else { return }
                    await state.analyzeRestore(from: url)
                }
            }
        }
    }

    /// ADR-019：表名 → 可读类别（Infrastructure 不携带展示文案）
    private func conflictKindLabel(_ table: String) -> String {
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
