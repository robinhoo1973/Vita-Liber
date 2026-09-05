import SwiftUI
import UniformTypeIdentifiers
import os
import Domain
import Infrastructure

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
@Observable
final class BackupState {
    enum Phase: Equatable {
        case idle
        case working
        case exported(fileName: String, sha256: String)
        case restored(records: Int)    // FR13.5 恢复后数据校验报告（导入记录计数）
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

    init(service: BackupService) { self.service = service }

    /// iCloud 可用性判定：`ubiquityIdentityToken == nil` 即未登录 iCloud 账号。
    /// 这是 Apple 官方的登录态判定方式，且**不需要任何权限**。
    var iCloudSignedIn: Bool { FileManager.default.ubiquityIdentityToken != nil }

    func prepareBackup() async {
        phase = .working
        do {
            let pkg = try await service.createBackup()
            pendingDocument = BackupDocument(data: pkg.data)
            phase = .exported(fileName: pkg.fileName, sha256: String(pkg.sha256.prefix(12)))
        } catch {
            logger.error("备份创建失败: \(error)")
            phase = .degraded(L10n.backupNoSpace)
        }
    }

    func restore(from url: URL) async {
        phase = .working
        // security-scoped：picker 返回的 URL 需显式取用权限，否则读取静默失败
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            // ADR-019：先分析冲突——无冲突直接恢复；有冲突进入逐项裁决预览。
            // 校验后的 envelope 随分析返回，恢复路径复用（整包只哈希+解码一次）
            let analysis = try await service.analyzeConflicts(from: data)
            guard !analysis.conflicts.isEmpty else {
                let records = try await service.restore(envelope: analysis.envelope)
                phase = .restored(records: records)
                return
            }
            pendingAnalysis = analysis
            resolutions = Dictionary(uniqueKeysWithValues: analysis.conflicts.map { ($0.id, .keep) })
            phase = .conflicts(analysis.conflicts)
        } catch BackupService.BackupError.checksumMismatch,
                BackupService.BackupError.unsupportedFormat {
            // 校验失败绝不部分导入——本机数据保持原样
            phase = .degraded(L10n.backupChecksumFailed)
        } catch {
            logger.error("备份恢复失败: \(error)")
            phase = .degraded(L10n.backupChecksumFailed)
        }
    }

    func setResolution(_ id: UUID, _ choice: ExportService.ConflictResolution) {
        resolutions[id] = choice
    }

    /// 应用裁决并恢复（ADR-019：确认后才执行；任何一项未裁决均已在服务层拒绝）
    func applyConflicts() async {
        guard case .conflicts = phase, let analysis = pendingAnalysis else { return }
        phase = .working
        do {
            let records = try await service.restore(envelope: analysis.envelope, resolutions: resolutions)
            pendingAnalysis = nil
            resolutions = [:]
            phase = .restored(records: records)
        } catch BackupService.BackupError.conflictDetected {
            logger.error("冲突裁决不完整")
            phase = .degraded(L10n.backupConflictDetected)
        } catch {
            logger.error("恢复失败: \(error)")
            phase = .degraded(L10n.backupChecksumFailed)
        }
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
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var showExportConfirm = false
    @State private var pendingRestoreURL: URL?
    @State private var showRestoreConfirm = false

    var body: some View {
        List {
            Section {
                if !state.iCloudSignedIn {
                    // 未登录 iCloud：不隐藏功能，只如实说明落点受限（仍可导出到本机）
                    Label(L10n.backupNotSignedIn, systemImage: "icloud.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("SP-24.backup.notSignedIn")
                }
                Button {
                    Task {
                        // FR13.4：导出前身份验证（门禁复用）——验证通过才进入隐私确认
                        guard await app.requestUnlock(reason: L10n.backupUnlockReason) else { return }
                        showExportConfirm = true
                    }
                } label: {
                    Label(L10n.backupCreate, systemImage: "icloud.and.arrow.up").frame(minHeight: 44)
                }
                .accessibilityIdentifier("SP-24.backup.create")

                Button {
                    showImporter = true
                } label: {
                    Label(L10n.backupRestore, systemImage: "icloud.and.arrow.down").frame(minHeight: 44)
                }
                .accessibilityIdentifier("SP-24.backup.restore")
            } footer: {
                Text(L10n.backupScopeNote)
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
                            Text(item.backupTitle ?? L10n.docLibraryUntitled)
                                .font(.subheadline)
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
            case .restored(let records):
                // FR13.5 恢复后数据校验报告：哈希比对通过 + 导入记录计数
                Section {
                    Label(L10n.backupRestoredCount(records), systemImage: "checkmark.circle")
                        .accessibilityIdentifier("SP-24.backup.restored")
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
        // FR13.5 恢复前确认：门禁验证 + 影响清单（覆盖现有数据）+ 校验承诺
        .alert(L10n.backupRestoreConfirmTitle, isPresented: $showRestoreConfirm) {
            Button(L10n.commonCancel, role: .cancel) { pendingRestoreURL = nil }
            Button(L10n.onboard_confirm) {
                if let url = pendingRestoreURL {
                    Task { await state.restore(from: url) }
                }
                pendingRestoreURL = nil
            }
        } message: {
            Text(L10n.backupRestoreConfirmBody)
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
            // FR13.5：选文件后不立即恢复——先门禁验证 + 影响清单确认
            Task {
                guard await app.requestUnlock(reason: L10n.backupUnlockReason) else { return }
                pendingRestoreURL = url
                showRestoreConfirm = true
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
