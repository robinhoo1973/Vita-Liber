import SwiftUI
import Domain
import Infrastructure
import Perception

/// 速记「更多操作」（2026-10-30 业主；mock v4 第 8 帧）。
///
/// 文件卡展示存储位置（本机 / 已导出的「文件」App 相对路径），动作四项：
/// 查看原图、重新识别、文档信息、导出副本。
/// 导出仍是显式选择（BR-007/008）：点击即授权本次导出，敏感件也不自动对外。
struct ChatMediaActionsSheet: View {
    let documentId: UUID
    let patientId: UUID
    let title: String
    let pageCount: Int
    /// 会话身份（2026-10-30）：显式导出副本也落聊天会话目录；
    /// nil=历史/无会话语境，回落「直接导入-YYYY-MM」月桶。
    var conversationID: UUID?
    var conversationTitle: String?

    @Environment(DocumentExportState.self) private var exportState
    @Environment(\.dismiss) private var dismiss

    @State private var showOriginal = false
    @State private var storagePath: String?
    @State private var storageLoaded = false
    @State private var exporting = false
    @State private var exportNote: String?

    private var storageText: String {
        chatMediaStorageText(loaded: storageLoaded, path: storagePath)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text.fill")
                            .font(.title3)
                            .foregroundStyle(Color("brand-primary", bundle: .main))
                            .frame(width: 44, height: 44)
                            .background(Color("brand-primary", bundle: .main).opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            Text(storageText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .accessibilityIdentifier("chat.mediaActions.storage")
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Button {
                        showOriginal = true
                    } label: {
                        Label(L10n.docViewOriginal, systemImage: "photo")
                    }
                    NavigationLink {
                        DocumentReviewRouteView(documentId: documentId, patientId: patientId,
                                                reprocess: true, suppressAutoMirror: true)
                    } label: {
                        Label(L10n.chatMediaReRecognize, systemImage: "arrow.triangle.2.circlepath")
                    }
                    NavigationLink {
                        ChatMediaInfoView(documentId: documentId, patientId: patientId,
                                          title: title, pageCount: pageCount)
                    } label: {
                        Label(L10n.docTitleSection, systemImage: "info.circle")
                    }
                    Button {
                        Task { await exportCopy() }
                    } label: {
                        HStack {
                            Label(L10n.docExportCopy, systemImage: "folder.badge.plus")
                            Spacer(minLength: 8)
                            if exporting { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(exporting)
                    if let exportNote {
                        Text(exportNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.chatMediaMoreActions)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.assistantClose) { dismiss() }
                }
            }
            .task { await loadStorage() }
            .fullScreenCover(isPresented: $showOriginal) {
                DocumentSourcePageView(documentId: documentId, patientId: patientId,
                                       pageIndex: 0)
            }
        }
    }

    private func loadStorage() async {
        storagePath = await exportState.exportedRelativePath(documentID: documentId)
        storageLoaded = true
    }

    private func exportCopy() async {
        exporting = true
        defer { exporting = false }
        let failure = await exportState.exportCopy(
            documentID: documentId, conversationID: conversationID,
            conversationTitle: conversationTitle, allowSensitive: true)
        exportNote = failure == nil ? L10n.chatMediaExportDone : L10n.exportFailed
        await loadStorage()
    }
}

/// 文档信息（更多操作 → 文档信息）：只读元数据 + 存储位置。
struct ChatMediaInfoView: View {
    let documentId: UUID
    let patientId: UUID
    let title: String
    let pageCount: Int

    @Environment(DocumentsState.self) private var docs
    @Environment(DocumentExportState.self) private var exportState

    @State private var createdAt: Date?
    @State private var storagePath: String?
    @State private var loaded = false
    /// 文档行读取失败/成员不符单列失败态：不得把失败画成「—」空值
    /// （与详情页 .failed 三值纪律一致；2026-10-30 复审）。
    @State private var loadFailed = false

    var body: some View {
        List {
            Section {
                LabeledContent(L10n.docTitleSection, value: title)
                LabeledContent(L10n.docDate, value: dateText)
                LabeledContent(L10n.chatMediaPageCount,
                               value: L10n.chatMediaPageCountText(pageCount))
                LabeledContent(L10n.chatMediaStorageLocation, value: storageText)
            }
            if loadFailed {
                Section {
                    Button(L10n.retry) { Task { await load() } }
                        .accessibilityIdentifier("chat.mediaInfo.retry")
                }
            }
        }
        .navigationTitle(L10n.docTitleSection)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        loaded = false
        loadFailed = false
        if let doc = await docs.documentRow(id: documentId), doc.patientId == patientId {
            createdAt = doc.createdAt
        } else {
            createdAt = nil
            loadFailed = true
        }
        storagePath = await exportState.exportedRelativePath(documentID: documentId)
        loaded = true
    }

    private var dateText: String {
        if loadFailed { return L10n.assistantMediaLoadFailed }
        guard let createdAt else { return loaded ? "—" : L10n.chatMediaStorageLoading }
        return createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var storageText: String {
        chatMediaStorageText(loaded: loaded, path: storagePath)
    }
}

/// 存储位置三态文案单一出口（更多操作 / 文档信息共用；2026-10-30 审查批）。
private func chatMediaStorageText(loaded: Bool, path: String?) -> String {
    if !loaded { return L10n.chatMediaStorageLoading }
    guard let path, !path.isEmpty else { return L10n.chatMediaStorageOnDevice }
    return String(format: L10n.chatMediaStorageExportedFmt, path)
}
