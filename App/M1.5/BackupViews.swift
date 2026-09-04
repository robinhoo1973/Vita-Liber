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
        case restored
        case degraded(String)          // 降级文案（未登录/空间不足/校验失败）
    }

    private(set) var phase: Phase = .idle
    private(set) var pendingDocument: BackupDocument?

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
            try await service.restore(from: data)
            phase = .restored
        } catch BackupService.BackupError.checksumMismatch,
                BackupService.BackupError.unsupportedFormat {
            // 校验失败绝不部分导入——本机数据保持原样
            phase = .degraded(L10n.backupChecksumFailed)
        } catch {
            logger.error("备份恢复失败: \(error)")
            phase = .degraded(L10n.backupChecksumFailed)
        }
    }

    func clearDocument() { pendingDocument = nil }
}

/// `fileExporter` 需要的 FileDocument 包装（纯字节搬运，无业务逻辑）
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
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
    @State private var showExporter = false
    @State private var showImporter = false

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
                        await state.prepareBackup()
                        if case .exported = state.phase { showExporter = true }
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
            case .exported(let name, let digest):
                Section {
                    Label(L10n.backupExportedName(name), systemImage: "checkmark.circle")
                        .accessibilityIdentifier("SP-24.backup.exported")
                    Text(L10n.backupChecksum(digest)).font(.caption2).monospaced()
                        .foregroundStyle(.secondary)
                }
            case .restored:
                Label(L10n.backupRestored, systemImage: "checkmark.circle")
                    .accessibilityIdentifier("SP-24.backup.restored")
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
        .fileExporter(isPresented: $showExporter,
                      document: state.pendingDocument,
                      contentType: .json,
                      defaultFilename: "vitaliber-backup") { result in
            if case .failure(let error) = result {
                // 系统 picker 失败最常见的可归因原因就是空间不足
                Logger(subsystem: "com.vitaliber", category: "backup")
                    .error("导出落点失败: \(error)")
            }
            state.clearDocument()
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            Task { await state.restore(from: url) }
        }
    }
}
