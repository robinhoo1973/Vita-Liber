import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Domain
import Infrastructure

/// 损坏数据库修复页（业主 2026-10-30 单独接口四动作）：
/// ① 删除损坏库并重新生成（先做数据丢失确认）
/// ② 导出损坏库（.zip，供用户自行修复/留档）
/// ③ 导入用户修复后的数据库（.sqlite/.zip，校验通过才替换）
/// ④ 从备份恢复（.vlbu / 旧 JSON，经 iCloud Drive 选择）
///
/// 安全纪律：所有破坏性动作都必须经过确认弹窗；校验失败绝不改动本机库；
/// 导出/导入均属显式用户动作（BR-007/008 egress：只提示，不默认外发）。
struct DatabaseRepairView: View {
    @ObservedObject var model: DatabaseBootModel
    @Environment(\.dismiss) private var dismiss

    @State private var showEraseConfirm = false
    @State private var showRepairImporter = false
    @State private var showBackupImporter = false
    @State private var showExportPicker = false
    @State private var exportURL: URL?
    @State private var exportedArchiveName: String?
    @State private var stagedRepairVersion: Int?
    @State private var showRepairConfirm = false
    @State private var stagedBackup: DatabaseBootModel.BackupInspection?
    @State private var showBackupConfirm = false
    @State private var errorText: String?
    @State private var busy = false

    private var busyNow: Bool { busy || model.recoveryBusy }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L10n.recoveryIntro)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } footer: {
                    if busyNow {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L10n.recoveryBusy).font(.footnote)
                        }
                    }
                }
                exportSection
                importSection
                backupSection
                deleteSection
            }
            .navigationTitle(L10n.recoveryTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { closeToolbar }
            .fileImporter(isPresented: $showRepairImporter,
                          allowedContentTypes: repairContentTypes) { result in
                guard case .success(let url) = result else { return }
                inspectRepair(url)
            }
            .fileImporter(isPresented: $showBackupImporter,
                          allowedContentTypes: backupContentTypes) { result in
                guard case .success(let url) = result else { return }
                inspectBackup(url)
            }
            .sheet(isPresented: $showExportPicker) { exportPickerSheet }
            .alert(L10n.recoveryImportConfirmTitle, isPresented: $showRepairConfirm) {
                repairConfirmActions
            } message: {
                repairConfirmMessage
            }
            .alert(L10n.recoveryBackupConfirmTitle, isPresented: $showBackupConfirm) {
                backupConfirmActions
            } message: {
                backupConfirmMessage
            }
            .alert(L10n.recoveryDeleteConfirmTitle, isPresented: $showEraseConfirm) {
                eraseConfirmActions
            } message: {
                Text(L10n.recoveryDeleteConfirmBody)
            }
            .alert(L10n.recoveryTitle, isPresented: errorAlertBinding) {
                Button(L10n.onboard_gotIt, role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
            .disabled(busyNow)
            .onDisappear { model.discardStagedRecovery() }
        }
    }

    // MARK: - 四段

    private var exportSection: some View {
        Section {
            Button {
                exportArchive()
            } label: {
                actionRow(icon: "archivebox",
                          title: L10n.recoveryExportTitle,
                          subtitle: L10n.recoveryExportSubtitle)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("STARTUP.repair.export")
            if let exportedArchiveName {
                Label(L10n.recoveryExportDone(exportedArchiveName), systemImage: "checkmark.seal")
                    .font(.footnote)
                    .foregroundStyle(Color("semantic-success", bundle: .main))
            }
        } footer: {
            Text(L10n.recoveryExportPrivacy)
        }
    }

    private var importSection: some View {
        Section {
            Button {
                showRepairImporter = true
            } label: {
                actionRow(icon: "square.and.arrow.down.on.square",
                          title: L10n.recoveryImportTitle,
                          subtitle: L10n.recoveryImportSubtitle)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("STARTUP.repair.import")
            if let version = stagedRepairVersion {
                Label(L10n.recoveryImportReport(Int64(version)), systemImage: "checkmark.seal")
                    .font(.footnote)
                    .foregroundStyle(Color("semantic-success", bundle: .main))
            }
        }
    }

    private var backupSection: some View {
        Section {
            Button {
                showBackupImporter = true
            } label: {
                actionRow(icon: "icloud.and.arrow.down",
                          title: L10n.recoveryBackupTitle,
                          subtitle: L10n.recoveryBackupSubtitle)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("STARTUP.repair.backup")
            if let inspection = stagedBackup {
                Label(L10n.recoveryBackupSummary(
                    inspection.exportedAt.formatted(date: .abbreviated, time: .shortened),
                    Int64(inspection.totalRecords)),
                      systemImage: "checkmark.seal")
                    .font(.footnote)
                    .foregroundStyle(Color("semantic-success", bundle: .main))
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showEraseConfirm = true
            } label: {
                actionRow(icon: "trash",
                          title: L10n.recoveryDeleteTitle,
                          subtitle: L10n.recoveryDeleteSubtitle,
                          tint: Color("semantic-danger", bundle: .main))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("STARTUP.repair.erase")
        }
    }

    // MARK: - 行 / 工具栏 / 选择器

    private func actionRow(icon: String, title: String, subtitle: String,
                           tint: Color = Color("brand-primary", bundle: .main)) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    @ToolbarContentBuilder
    private var closeToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L10n.recoveryClose) {
                model.discardStagedRecovery()
                dismiss()
            }
            .disabled(busyNow)
            .accessibilityIdentifier("STARTUP.repair.close")
        }
    }

    @ViewBuilder
    private var exportPickerSheet: some View {
        if let exportURL {
            DatabaseExportPicker(url: exportURL) { name in
                exportedArchiveName = name
            }
            .ignoresSafeArea()
            .onDisappear {
                try? FileManager.default.removeItem(at: exportURL) // try?-ok: 临时压缩包清理
            }
        }
    }

    private var repairContentTypes: [UTType] {
        var types: [UTType] = [.data, .zip]
        if let sqlite = UTType(filenameExtension: "sqlite") { types.append(sqlite) }
        if let db = UTType(filenameExtension: "db") { types.append(db) }
        return types
    }

    private var backupContentTypes: [UTType] { [.data, .json] }

    // MARK: - 弹窗内容

    @ViewBuilder
    private var repairConfirmActions: some View {
        Button(L10n.recoveryImportAction, role: .destructive) { applyRepair() }
        Button(L10n.recoveryCancel, role: .cancel) { }
    }

    private var repairConfirmMessage: Text {
        if let version = stagedRepairVersion {
            return Text(L10n.recoveryImportConfirmBody + "\n\n" + L10n.recoveryImportReport(Int64(version)))
        }
        return Text(L10n.recoveryImportConfirmBody)
    }

    @ViewBuilder
    private var backupConfirmActions: some View {
        Button(L10n.recoveryBackupAction, role: .destructive) { applyBackupRestore() }
        Button(L10n.recoveryCancel, role: .cancel) { }
    }

    private var backupConfirmMessage: Text {
        guard let inspection = stagedBackup else { return Text(L10n.recoveryBackupConfirmBody) }
        let summary = L10n.recoveryBackupSummary(
            inspection.exportedAt.formatted(date: .abbreviated, time: .shortened),
            Int64(inspection.totalRecords))
        return Text(L10n.recoveryBackupConfirmBody + "\n\n" + summary)
    }

    @ViewBuilder
    private var eraseConfirmActions: some View {
        Button(L10n.recoveryDeleteAction, role: .destructive) { eraseAndRebuild() }
        Button(L10n.recoveryCancel, role: .cancel) { }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(get: { errorText != nil },
                set: { if !$0 { errorText = nil } })
    }

    // MARK: - 动作

    private func exportArchive() {
        Task { @MainActor in
            busy = true
            defer { busy = false }
            do {
                let url = try await model.makeCorruptDatabaseArchive()
                exportURL = url
                showExportPicker = true
            } catch {
                errorText = message(for: error)
            }
        }
    }

    private func inspectRepair(_ url: URL) {
        Task { @MainActor in
            busy = true
            defer { busy = false }
            // security-scoped：picker URL 只在本次作用域内可读；模型内部会复制/解包。
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let report = try await model.inspectRepairedDatabase(at: url)
                stagedRepairVersion = report.userVersion
                showRepairConfirm = true
            } catch {
                errorText = message(for: error)
            }
        }
    }

    private func inspectBackup(_ url: URL) {
        Task { @MainActor in
            busy = true
            defer { busy = false }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
                let inspection = try await model.inspectBackupPackage(data)
                stagedBackup = inspection
                showBackupConfirm = true
            } catch {
                errorText = message(for: error)
            }
        }
    }

    private func applyRepair() {
        Task { @MainActor in
            busy = true
            defer { busy = false }
            do {
                try await model.applyStagedRepairAndRebuild()
                if model.failure == nil { dismiss() }
            } catch {
                errorText = message(for: error)
            }
        }
    }

    private func applyBackupRestore() {
        Task { @MainActor in
            busy = true
            defer { busy = false }
            do {
                try await model.restoreStagedBackupAndRebuild()
                if model.failure == nil { dismiss() }
            } catch {
                errorText = message(for: error)
            }
        }
    }

    private func eraseAndRebuild() {
        Task { @MainActor in
            busy = true
            defer { busy = false }
            do {
                try await model.eraseCorruptDatabaseAndRebuild()
                if model.failure == nil { dismiss() }
            } catch {
                errorText = message(for: error)
            }
        }
    }

    // MARK: - 错误文案

    private func message(for error: Error) -> String {
        if let repair = error as? DatabaseRepairError {
            return repairMessage(repair)
        }
        if let backup = error as? BackupService.BackupError {
            switch backup {
            case .checksumMismatch: return L10n.recoveryBackupChecksum
            case .unsupportedFormat: return L10n.recoveryBackupFormat
            case .conflictDetected: return L10n.recoveryBackupConflict
            }
        }
        return L10n.recoveryError(String(describing: error))
    }

    private func repairMessage(_ error: DatabaseRepairError) -> String {
        switch error {
        case .missingFile, .ioFailed:
            return L10n.recoveryValidationIO
        case .notSQLite:
            return L10n.recoveryValidationNotSQLite
        case .unreadable:
            return L10n.recoveryValidationUnreadable
        case .integrityFailed:
            return L10n.recoveryValidationIntegrity
        case .tooNew(let found, let supported):
            return L10n.recoveryValidationTooNew(Int64(found), Int64(supported))
        case .unsupportedVersion(let version):
            return L10n.recoveryValidationVersion(Int64(version))
        case .missingTables(let names):
            return L10n.recoveryValidationMissingTables(names.joined(separator: ", "))
        case .archiveInvalid:
            return L10n.recoveryValidationArchive
        }
    }
}

/// 导出压缩包用的系统文件选择器（不把整包读进内存；系统负责落到 Files/iCloud Drive）。
private struct DatabaseExportPicker: UIViewControllerRepresentable {
    let url: URL
    let onExported: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onExported: onExported) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController,
                                context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onExported: (String) -> Void
        init(onExported: @escaping (String) -> Void) { self.onExported = onExported }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            // 导出完成：系统回传落点 URL；给界面一行「已导出：<文件名>」反馈。
            guard let saved = urls.first else { return }
            onExported(saved.lastPathComponent)
        }
    }
}
