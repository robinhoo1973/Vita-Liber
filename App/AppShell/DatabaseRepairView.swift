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
        // 版式对齐 refactor/mock/startup-selfcheck-flow.html 修复 sheet：
        // 自绘标题栏 + 灰底 + 白色分组卡（非系统 List），行高 ≥64、危险行红色标题。
        VStack(spacing: 0) {
            repairHeader
            ScrollView {
                VStack(spacing: 14) {
                    Text(L10n.recoveryIntro)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if busyNow { busyRow }
                    exportCard
                    Text(L10n.recoveryExportPrivacy)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    importCard
                    backupCard
                    if !model.allowsDestructiveRebuild { migrationHintCard }
                    deleteCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
            .disabled(busyNow)
        }
        .background(Color(.systemGroupedBackground))
        .presentationDetents([.large])
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
        .interactiveDismissDisabled(busyNow)
        .onDisappear {
            // 忙时不丢弃：install/restore 任务可能仍在读暂存文件。
            if !busyNow { model.discardStagedRecovery() }
        }
    }

    // MARK: - 版式（对齐 mock 修复 sheet）

    private var repairHeader: some View {
        HStack(spacing: 12) {
            Text(L10n.recoveryTitle)
                .font(.headline)
            Spacer(minLength: 0)
            Button {
                model.discardStagedRecovery()
                dismiss()
            } label: {
                Text(L10n.recoveryClose)
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .disabled(busyNow)
            .accessibilityIdentifier("STARTUP.repair.close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }

    private var busyRow: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(L10n.recoveryBusy)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func repairCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 15)
            .background(Color(.systemBackground),
                        in: RoundedRectangle(cornerRadius: VLCornerRadius.card))
    }

    private var cardDivider: some View {
        Divider().padding(.leading, 38).opacity(0.6)
    }

    private func successRow(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.seal")
            .font(.footnote)
            .foregroundStyle(Color("semantic-success-text", bundle: .main))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.leading, 38)
    }

    private var exportCard: some View {
        repairCard {
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
                cardDivider
                successRow(L10n.recoveryExportDone(exportedArchiveName))
            }
        }
    }

    private var importCard: some View {
        repairCard {
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
                cardDivider
                successRow(L10n.recoveryImportReport(Int64(version)))
            }
        }
    }

    private var backupCard: some View {
        repairCard {
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
                cardDivider
                successRow(L10n.recoveryBackupSummary(
                    inspection.exportedAt.formatted(date: .abbreviated, time: .shortened),
                    Int64(inspection.totalRecords)))
            }
        }
    }

    private var migrationHintCard: some View {
        repairCard {
            Text(L10n.recoveryMigrationKeepHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private var deleteCard: some View {
        if model.allowsDestructiveRebuild {
            repairCard {
                Button(role: .destructive) {
                    showEraseConfirm = true
                } label: {
                    actionRow(icon: "trash",
                              title: L10n.recoveryDeleteTitle,
                              subtitle: L10n.recoveryDeleteSubtitle,
                              tint: Color("semantic-danger", bundle: .main),
                              titleTint: Color("semantic-danger", bundle: .main))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("STARTUP.repair.erase")
            }
        }
    }

    // MARK: - 行 / 工具栏 / 选择器

    private func actionRow(icon: String, title: String, subtitle: String,
                           tint: Color = Color("brand-primary", bundle: .main),
                           titleTint: Color? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(titleTint ?? .primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 64)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var exportPickerSheet: some View {
        if let exportURL {
            DatabaseExportPicker(url: exportURL) { name in
                if let name { exportedArchiveName = name }
                showExportPicker = false
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
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 // try?-ok: 大小读不到按 0 放行，真实读取失败由后续校验兜底
                guard Int64(size) <= BackupService.maxPackageBytes else {
                    throw BackupService.BackupError.tooLarge
                }
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
                // 成功或被启动门拒绝都不再静默停在本页：关闭后失败卡可见。
                dismiss()
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
                dismiss()
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
                dismiss()
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
            case .tooLarge: return L10n.recoveryBackupTooLarge
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
        case .archiveMultiple:
            return L10n.recoveryValidationArchiveMultiple
        case .archiveHasSidecars:
            return L10n.recoveryValidationArchiveSidecars
        }
    }
}

/// 导出压缩包用的系统文件选择器（不把整包读进内存；系统负责落到 Files/iCloud Drive）。
private struct DatabaseExportPicker: UIViewControllerRepresentable {
    let url: URL
    let onDone: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController,
                                context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onDone: (String?) -> Void
        init(onDone: @escaping (String?) -> Void) { self.onDone = onDone }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            // 导出完成：系统回传落点 URL；给界面一行「已导出：<文件名>」反馈。
            onDone(urls.first?.lastPathComponent)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // 取消也必须回置 sheet 状态，否则 SwiftUI sheet 可能滞留。
            onDone(nil)
        }
    }
}
