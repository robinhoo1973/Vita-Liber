import SwiftUI
import UIKit
import PhotosUI
import PDFKit
import UniformTypeIdentifiers
import Perception
import Domain
import Infrastructure

/// 首页 OCR/ASR 入口旁的 AI 聊天入口（2026-10-18 业主指令）。
///
/// 定位：**有据任务型助手**，不是自由医疗问答（D2 边界不变，BR-006）：
/// - 文本先过急救/高风险词表（BR-012/BR-006）；
/// - 意图分类走 FR17.19 期一确定性目录（零模型、零网络）；
/// - 缺必填槽位最多脚本化追问一次（FR17.5/FR17.8）；
/// - 一律经 FR17.13 标准确认卡 D→C 后才分发；
/// - 动作闭集与 `VoiceActionPlanner` 一致，模型/助手无权直接执行。
/// UIImage 跨执行器装箱（方向归一 + JPEG 编码在后台执行器）。
/// UIKit 图像对象不声明 Sendable；装箱后仅在本次后台任务独占使用。
private final class MergeImageBox: @unchecked Sendable {
    let image: UIImage
    init(_ image: UIImage) { self.image = image }
}

struct TaskAssistantChatView: View {
    @Environment(AppState.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(VoiceNoteState.self) private var voiceNotes
    @Environment(QuestionsState.self) private var questions
    @Environment(DocumentsState.self) private var docs
    @Environment(DocumentExportState.self) private var exportState
    @Environment(ChatHistoryState.self) private var chatHistory
    @Environment(AppSettingsStore.self) private var settingsStore
    @Environment(M2HubStore.self) private var hub
    @Environment(\.auditLog) private var auditLog
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [ChatMessage] = []
    /// 逐条敏感态缓存（2026-10-28：气泡菜单敏感开关初值；.task 按 documentId 加载）
    @State private var sensitiveByDocument: [UUID: Bool] = [:]
    /// 已读到真值的文档：开关就绪前禁用，避免「未知=false」被用户误读为
    /// 当前资料不敏感（BR-007/008 对外边界不能靠默认值猜）。
    @State private var sensitiveLoaded: Set<UUID> = []
    @State private var input = ""
    @State private var confirmSet: OcrConfirmationSet?
    @State private var pendingPlan: VoiceActionPlan?
    @State private var pendingClarification: VoiceSlotSpec?
    /// 确认卡判定结果行（FR17.19 消歧兜底：用户可在卡内改类）。
    @State private var judgedTarget: String?
    @State private var judgedConfidence: Double = 1.0
    @State private var isSaving = false
    /// 单 sheet 槽（2026-10-19）：语音与附件采集共用一次 presentation，
    /// 避免同视图多 `.sheet` 在 iOS 16 的相互覆盖。
    @State private var activeSheet: AssistantSheet?
    @State private var voiceMode = false
    /// 聊天内语音输入（2026-10-20）：复用 VoiceDictationModel，轻点开始/再点结束，
    /// 波形悬浮在当前页，不再打开 AssistantVoiceInputSheet。
    @State private var chatDictation: VoiceDictationModel?
    @State private var pendingVoiceURLs: [UUID: URL] = [:]
    /// 已发过语音回执的听写会话（2026-10-29 批三：同批多段转写只回执一次，
    /// 但新一批必须重新回执——按会话键去重，不按上一条助手消息文本）。
    @State private var lastVoiceReceiptSession: UUID?
    @State private var attachmentPanel = false
    @FocusState private var inputFocused: Bool
    @State private var routeMonitor = AudioRouteMonitor()

    // 2026-10-19 聊天内采集（业主指令）：媒体 → 全图 OCR → 助理侧信息卡。
    @State private var chatSessionID: UUID?
    /// 发起导入时的会话代次：OCR 收尾若已切会话，回执/导出不得落到新会话
    /// （2026-10-30 审查席 P1：自动化导出放大了跨会话串写）。
    @State private var importGeneration: UUID?
    @State private var importing = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    /// 多选（2026-10-23 业主）：一次可选多张照片，合并为一份多页文档后统一识别。
    @State private var pickedPhotos: [PhotosPickerItem] = []
    /// 导入前检查（2026-10-30）：确认后才把（已旋转归一的）图片送识别。
    @State private var importPreview: ImportPreviewRequest?
    /// 预览呈现的延迟任务（选择器收起竞态）：页面消失/再次选择时取消，
    /// 避免已关闭的聊天页在下一拍弹出预览。
    @State private var previewTask: Task<Void, Never>?

    // 语音消息重放（2026-10-19；2026-10-20 转写文本常显）：本机音频文件。
    // 播放器已上提 AppState.voicePlayback（2026-10-21），页面只读 playingID。
    /// 已写入历史的视图消息 ID（媒体在 OCR 终态才落库，避免 processing 快照）。
    @State private var persistedMessageIDs: Set<UUID> = []
    /// 历史写入串行链：append 必须先于同消息的 update（2026-10-20）。
    @State private var persistenceTail: Task<Void, Never>?
    @State private var conversationID: UUID?
    /// 当前会话标题真值（2026-10-30：聊天媒体导出目录以会话名命名）。
    /// 自动命名/历史打开/新建三处同步；用户手动改名暂不回流（目录名首次导出即冻结）。
    @State private var conversationTitle: String?
    /// 会话代次：切换会话后，晚到的持久化任务不得写进新会话（2026-10-20）。
    @State private var conversationGeneration = UUID()
    @State private var titleCaptured = false
    @State private var showHistory = false

    private enum AssistantSheet: Identifiable {
        case history
        /// 媒体详情（2026-10-29 批三）：识别文本 / 信息卡片双 tab。
        /// 2026-10-30：携带会话身份，详情内显式导出副本也落「<日期>-<会话名>」目录；
        /// 另带附件数——详情缩略图按附件一张，不按文档页数铺。
        case mediaDetail(documentId: UUID, patientId: UUID, title: String,
                         attachmentCount: Int, attachmentPageOffsets: [Int]?,
                         conversationID: UUID?, conversationTitle: String?)
        /// 语音详情（2026-10-30 业主；mock v4 第 7 帧）。
        case voiceDetail(messageID: UUID, media: MediaInfo)
        case sharedReview(sessionID: UUID)
        case cardReview(cardID: UUID, sessionID: UUID)

        var id: String {
            switch self {
            case .history: return "history"
            case .mediaDetail(let doc, _, _, _, _, _, _): return "media-\(doc.uuidString)"
            case .voiceDetail(let messageID, _): return "voice-\(messageID.uuidString)"
            case .sharedReview(let id): return "shared-\(id.uuidString)"
            case .cardReview(let cardID, _): return "card-\(cardID.uuidString)"
            }
        }
    }

    /// 导入前图片检查请求（2026-10-30 业主）：拍照/相册/文件图片先经预览页
    /// 放大检查与旋转，确认后才进入 OCR 链。PDF 不进预览（方向由原件决定）。
    private struct ImportPreviewRequest: Identifiable {
        let id = UUID()
        var images: [UIImage]
        var pdfs: [PDFDocument]
        var filename: String
        var kind: MediaInfo.Kind
        var origin: String
        var source: MediaSource
    }

    /// 媒体来源（2026-10-29 批三 · mock v4 对照）：聊天卡片头图标=来源类型，
    /// 拍照/相册/文件/语音互不混淆（多张由 itemCount 角标区分）。
    /// `.unknown` = 本批之前的历史快照（无 source 键）——渲染中性相片图标，
    /// 不冒充「文件」来源（UX 席 P2-7）。
    private enum MediaSource: String, Equatable {
        case camera, photoLibrary, fileImport, voice, unknown
    }

    private struct MediaInfo: Equatable {
        enum Kind: Equatable { case image, pdf, file, voice }
        enum Status: Equatable { case processing, ready, failed }
        var kind: Kind
        var filename: String
        var status: Status
        var source: MediaSource = .unknown
        /// 合并识别张数（单张=1；多选照片/多文件合并后的入参个数）。
        var itemCount = 1
        /// 每个附件在合并 PDF 中的起始页（0 基）。nil=旧快照，详情按附件序
        /// 即页序回落（2026-10-30 多页 PDF 页偏移登记项）。
        var attachmentPageOffsets: [Int]? = nil
        var audioFilename: String?
        var transcript: String?
        /// OCR 落库后的文档引用（2026-10-20）：图片/PDF 气泡可回看原件，
        /// 历史恢复后仍可打开（原件受敏感媒体解锁链保护）。
        var documentId: UUID? = nil
        var patientId: UUID? = nil
        /// 非 final 转写（超时/中断）——气泡须明示不完整。
        var incomplete = false
    }

    private struct CardInfo: Equatable, Identifiable {
        enum Kind: Equatable { case shared, entity }
        var id: String
        var kind: Kind
        var entityKind: String?
        var fieldCount: Int
        var sessionID: UUID
        /// 离线恢复时的状态快照（"done"/"deferred"/"pending"/"locked"）。
        var snapshotState: String = "done"
    }

    private struct ChatMessage: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant, receipt }
        let id = UUID()
        var role: Role
        var text: String = ""
        var isRefusal = false
        var isEmergency = false
        var media: MediaInfo?
        var card: CardInfo?
    }

    private var suggestions: [String] {
        [L10n.assistantQuickMetric, L10n.assistantQuickReminder, L10n.assistantQuickQuestion]
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                VStack(spacing: 0) {
                    messageList
                    Divider()
                    inputBar
                }
                .navigationTitle(L10n.assistantChatTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            activeSheet = .history
                        } label: {
                            Label(L10n.assistantHistoryTitle, systemImage: "clock.arrow.circlepath")
                        }
                        .accessibilityIdentifier("assistant.history")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.assistantClose) { dismiss() }
                            .accessibilityIdentifier("assistant.close")
                    }
                }
                // FR17.13-entry: task-assistant（唯一确认映射 VoiceInputTemplate.confirmationSet）
                .voiceConfirmSheet($confirmSet, route: routeMonitor.route,
                                   judgedTarget: judgedTarget,
                                   judgedConfidence: judgedConfidence,
                                   onJudgedTargetChange: { key in
                                       reclassify(to: key)
                                   }) { confirmed in
                    handleConfirmation(confirmed)
                }
                .sheet(item: $activeSheet) { sheet in
                    sheetContent(sheet)
                }
                .photosPicker(isPresented: $showPhotoPicker, selection: $pickedPhotos,
                              maxSelectionCount: 9, matching: .images)
                .onChangeCompat(of: pickedPhotos) { _, items in handlePickedPhotos(items) }
                .fullScreenCover(isPresented: $showCamera) {
                    CameraPicker { image in handleCameraImage(image) }
                }
                .fileImporter(isPresented: $showFileImporter,
                              allowedContentTypes: [.pdf, .image],
                              allowsMultipleSelection: true,
                              onCompletion: handleImportedFiles)
                .onAppear { routeMonitor.start() }
                // 任一录音路径开始（含 DictationInteraction 手势）都停止语音消息重放。
                .onChangeCompat(of: chatDictation?.phase) { _, phase in
                    if phase == .recording { stopVoicePlayback() }
                }
                // 语言/混说设置变化后重建听写模型（与 VoiceDictationButton 同纪律）
                .task(id: "\(settingsStore.values[.voiceInputLanguages] ?? "")|\(settingsStore.values[.voiceMixedInput] ?? "")") {
                    ChatAudioStore.sweepTemporary()
                    ensureChatDictationModel()
                }
                .onChangeCompat(of: docs.activeImport?.sharedFieldsSettled) { _, _ in
                    syncCardSnapshots()
                }
                .onChangeCompat(of: docs.activeImport?.committedCards.count) { _, _ in
                    syncCardSnapshots()
                }
                .onChangeCompat(of: activeSheet == nil) { _, closed in
                    if closed {
                        syncCardSnapshots()
                    }
                }
                .onDisappear {
                    routeMonitor.stop()
                    previewTask?.cancel()
                    previewTask = nil
                    stopVoicePlayback()
                    chatDictation?.stopForDisappear()
                    for url in pendingVoiceURLs.values { ChatAudioStore.removeTemporary(url) }
                    pendingVoiceURLs.removeAll()
                    releaseChatSessionIfNeeded()
                }
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        emptyState
                    }
                    ForEach(messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                }
                .padding(16)
            }
            .onChangeCompat(of: messages.count) { _, _ in
                guard let last = messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            // 挂在消息列表（非根视图）上：根视图已有 `.sheet(activeSheet)` 与
            // 相机 `.fullScreenCover`，同节点多 presentation 在 iOS 16 会互相覆盖。
            .fullScreenCover(item: $importPreview) { request in
                ChatImageImportPreview(images: request.images) { images in
                    handlePreviewConfirmed(images, request: request)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.assistantChatEmptyTitle)
                .font(.headline)
            Text(L10n.assistantChatEmptyBody)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) { input = suggestion }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)   // 触控目标下限（DesignSystem）
                        .accessibilityIdentifier("assistant.suggestion")
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    /// 微信式消息行（2026-10-19）：用户媒体/文本在右（用户头像），
    /// 助手文本/信息卡在左（助手头像）。
    private func messageRow(_ message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user { Spacer(minLength: 24) }
            if message.role != .user { AssistantAvatarView(size: 32) }
            if let media = message.media {
                mediaBubble(media, messageID: message.id)
            } else if let card = message.card {
                cardBubble(card)
            } else {
                textBubble(message)
            }
            if message.role == .user { AvatarView(size: 32) }
            if message.role != .user { Spacer(minLength: 24) }
        }
    }

    private func textBubble(_ message: ChatMessage) -> some View {
        Text(message.text)
            .font(.body)
            .foregroundStyle(message.isRefusal || message.isEmergency
                ? Color("semantic-danger", bundle: .main) : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(background(for: message))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 用户侧媒体记录（2026-10-19 业主：像微信上传文件一样进聊天记录；
    /// 2026-10-20：OCR 落库后整块可点开原件——当前会话与历史恢复同一路径；
    /// 2026-10-30 业主：气泡回到「来源图标 + 状态文字」的整条可点样式
    /// （与语音消息一致），点整条进媒体详情；缩略图墙只在详情页出现。
    @ViewBuilder
    private func mediaBubble(_ media: MediaInfo, messageID: UUID) -> some View {
        if media.kind == .voice {
            voiceBubble(media, messageID: messageID)
        } else if let documentId = media.documentId, let patientId = media.patientId {
            Button {
                openMediaDetail(media, documentId: documentId, patientId: patientId)
            } label: {
                mediaContent(media, showsDisclosure: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint(L10n.assistantMediaDetailHint)
            .accessibilityIdentifier("assistant.media.open")
            // 2026-10-27 存储边界（E1/E2）+ 2026-10-28 逐条敏感开关：
            // 默认不敏感（2026-10-28 业主改判，存量记录不追溯）；开=仅内部保存
            // 并删除用户面副本；关=显式授权对外，立即导出副本。
            // 菜单点击本身即显式选择（BR-007/008）。
            .contextMenu {
                Toggle(L10n.chatRecordSensitiveToggle, isOn: Binding(
                    get: { sensitiveByDocument[documentId] ?? false },
                    set: { newValue in
                        Task {
                            let previous = sensitiveByDocument[documentId]
                            // 乐观切换：开关立即反馈；失败回滚，避免界面与
                            // 真实出口边界不一致（BR-007/008）。
                            sensitiveByDocument[documentId] = newValue
                            let failure = await exportState.setRecordSensitive(
                                documentID: documentId, sensitive: newValue,
                                conversationID: conversationID,
                                conversationTitle: conversationTitle)
                            if failure != nil { sensitiveByDocument[documentId] = previous }
                            sensitiveLoaded.insert(documentId)
                        }
                    }))
                .disabled(!sensitiveLoaded.contains(documentId))
                Button {
                    Task {
                        _ = await exportState.exportCopy(
                            documentID: documentId, conversationID: conversationID,
                            conversationTitle: conversationTitle, allowSensitive: true)
                    }
                } label: { Label(L10n.docExportCopy, systemImage: "folder.badge.plus") }
            }
            .task(id: documentId) {
                // 一次读取同时取敏感真值；读不到则开关保持禁用，
                // 不把「未知」画成「关」。
                if let doc = await docs.documentRow(id: documentId) {
                    sensitiveByDocument[documentId] = doc.isSensitive
                    sensitiveLoaded.insert(documentId)
                }
            }
        } else {
            mediaContent(media)
        }
    }

    private func openMediaDetail(_ media: MediaInfo, documentId: UUID, patientId: UUID) {
        activeSheet = .mediaDetail(documentId: documentId, patientId: patientId,
                                   title: media.filename, attachmentCount: media.itemCount,
                                   attachmentPageOffsets: media.attachmentPageOffsets,
                                   conversationID: conversationID,
                                   conversationTitle: conversationTitle)
    }

    private func mediaContent(_ media: MediaInfo, showsDisclosure: Bool = false) -> some View {
        HStack(spacing: 10) {
            mediaIcon(media)
            VStack(alignment: .leading, spacing: 2) {
                Text(media.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(mediaStatusText(media.status))
                    .font(.caption2)
                    .foregroundStyle(media.status == .failed
                        ? Color("semantic-danger", bundle: .main) : Color.secondary)
            }
            Spacer(minLength: 4)
            // 可点进详情时给前向箭头（与语音气泡同语义）；无文档引用时不给。
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 240, alignment: .leading)
        .background(Color("brand-primary", bundle: .main).opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("assistant.media")
    }

    /// 卡片头图标 = 来源类型（2026-10-29 批三）：拍照相机 / 相册相片 /
    /// 多张叠层 / PDF / 文件。
    private func mediaIcon(_ media: MediaInfo) -> some View {
        Image(systemName: mediaSymbol(media))
            .font(.title3)
            .foregroundStyle(Color("brand-primary", bundle: .main))
            .frame(width: 44, height: 44)
            .background(Color("brand-primary", bundle: .main).opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }

    private func mediaSymbol(_ media: MediaInfo) -> String {
        switch media.source {
        case .camera: return "camera.fill"
        case .photoLibrary: return media.itemCount > 1 ? "photo.stack" : "photo.on.rectangle"
        case .voice: return "waveform"
        case .fileImport:
            if media.kind == .pdf { return media.itemCount > 1 ? "doc.on.doc" : "doc.fill" }
            return media.itemCount > 1 ? "doc.on.doc" : "doc.text.fill"
        case .unknown:
            if media.kind == .pdf { return media.itemCount > 1 ? "doc.on.doc" : "doc.fill" }
            return media.itemCount > 1 ? "doc.on.doc" : "photo"
        }
    }

    /// 语音消息（2026-10-19；2026-10-20 业主指令）：本机音频可重放；
    /// 转写文本不再需要手动触发——识别在后台完成，直接展开显示在语音下方。
    /// 2026-10-30 业主：点标题/转写进入语音详情（播放器 + 转写/摘要双 tab，
    /// mock v4 第 7 帧），播放键仍在气泡上直接可点。
    private func voiceBubble(_ media: MediaInfo, messageID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    playVoice(media, messageID: messageID)
                } label: {
                    Image(systemName: app.voicePlayback.isPlaying(id: messageID)
                        ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(media.audioFilename == nil)
                // 2026-10-30 复审：图标已随播放态双化，标签不得仍说「重放」；
                // 与详情页同一对键（播放/暂停），VoiceOver 动作与图标一致。
                .accessibilityLabel(app.voicePlayback.isPlaying(id: messageID)
                    ? L10n.chatVoicePause : L10n.chatVoicePlay)
                .accessibilityIdentifier("assistant.voice.replay")

                Button {
                    activeSheet = .voiceDetail(messageID: messageID, media: media)
                } label: {
                    HStack(spacing: 4) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.assistantVoiceMessage)
                                .font(.subheadline)
                            Text(mediaStatusText(media.status))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(L10n.chatVoiceOpenHint)
                .accessibilityIdentifier("assistant.voice.open")
            }
            if let transcript = media.transcript,
               !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    activeSheet = .voiceDetail(messageID: messageID, media: media)
                } label: {
                    Text(transcript)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("assistant.voice.transcript")
            }
            if media.incomplete {
                Label(L10n.voiceDictationIncomplete, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(Color("semantic-warning", bundle: .main))
                    .accessibilityIdentifier("assistant.voice.incomplete")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Color("brand-primary", bundle: .main).opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func stopVoicePlayback() {
        app.voicePlayback.stop()
    }

    private func playVoice(_ media: MediaInfo, messageID: UUID) {
        // 播放与录音互斥：正在录音时先停止听写，避免把重放内容录进回答。
        chatDictation?.stop()
        guard let filename = media.audioFilename,
              let url = ChatAudioStore.fileURL(filename) else { return }
        if app.voicePlayback.playingID == messageID {
            // 同一消息：出声=停止；暂停=续播（详情页暂停后回到气泡不能变「重播」）。
            if app.voicePlayback.isPlaying(id: messageID) {
                app.voicePlayback.stop()
            } else {
                app.voicePlayback.togglePause()
            }
            return
        }
        // 双向互斥：开始重放前停掉 TTS，避免朗读与语音消息叠音。
        app.stopSpeaking()
        if !app.voicePlayback.play(url: url, id: messageID) {
            append(.init(role: .assistant, text: L10n.assistantVoiceReplayFailed, isRefusal: true))
        }
    }

    /// 助手侧信息卡（2026-10-19）：开篇行右侧编辑图标进入修正/确认；完成后显示勾。
    private func cardBubble(_ card: CardInfo) -> some View {
        let state = cardState(card)
        let style = cardKindStyle(card)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(style.color)
                .frame(width: 34, height: 34)
                .background(style.color.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(cardTitle(card))
                    .font(.subheadline.weight(.semibold))
                Text(cardSubtitle(card, state: state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            cardStatusControl(card, state: state)
        }
        .padding(12)
        .frame(maxWidth: 300, alignment: .leading)
        .background(cardBackground(state))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.card.\(card.id)")
    }

    @ViewBuilder
    private func cardStatusControl(_ card: CardInfo, state: CardState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Color("semantic-success", bundle: .main))
                .accessibilityLabel(L10n.assistantCardDone)
        case .deferred:
            Image(systemName: "clock.badge.checkmark")
                .font(.title3)
                .foregroundStyle(Color("semantic-warning", bundle: .main))
                .accessibilityLabel(L10n.assistantCardDeferred)
        case .pending, .locked:
            Button {
                openCard(card, state: state)
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(L10n.assistantCardEdit)
            .accessibilityIdentifier("assistant.card.edit.\(card.id)")
        }
    }

    private func cardBackground(_ state: CardState) -> Color {
        switch state {
        case .done: return Color("semantic-success", bundle: .main).opacity(0.10)
        case .deferred: return Color("semantic-warning", bundle: .main).opacity(0.10)
        case .pending, .locked: return Color.secondary.opacity(0.10)
        }
    }

    private enum CardState: Equatable { case pending, done, deferred, locked }

    private func cardState(_ info: CardInfo) -> CardState {
        guard let session = docs.activeImport, session.id == info.sessionID else {
            switch info.snapshotState {
            case "deferred", "pending", "locked": return .deferred
            default: return .done
            }
        }
        switch info.kind {
        case .shared:
            let rows = docs.sharedFieldRows(for: session)
            if rows.isEmpty || session.sharedFieldsSettled { return .done }
            if session.outcome != nil { return .deferred }
            return .pending
        case .entity:
            guard let cardID = UUID(uuidString: info.id) else { return .done }
            if session.committedCards.contains(cardID) { return .done }
            guard session.cards.contains(where: { $0.id == cardID }) else { return .deferred }
            let rows = docs.sharedFieldRows(for: session)
            return rows.isEmpty || session.sharedFieldsSettled ? .pending : .locked
        }
    }

    /// 卡类 → 左端圆角方形图标（不同卡一眼可辨；右端留给编辑/确认）。
    /// 实体卡走 `CardKindIcon` 唯一出口（开发席 P1：此前聊天面自带第二张
    /// 卡类图标表——同一种卡在聊天与时间轴/资料库显示两个字形；2026-10-29
    /// 批三删除新表并入单一出处。颜色=Spec.tint，色按卡类不按严重度）。
    private func cardKindStyle(_ card: CardInfo) -> (symbol: String, color: Color) {
        if card.kind == .shared {
            return ("info.circle.fill", Color("card-kind-shared", bundle: .main))
        }
        let spec = CardKindIcon.spec(cardKind: card.entityKind ?? "")
        return (spec.symbol, spec.tint)
    }

    private func cardTitle(_ card: CardInfo) -> String {
        switch card.kind {
        case .shared: return L10n.sharedFieldsTitle
        case .entity: return L10n.entityCardKindName(card.entityKind ?? "")
        }
    }

    private func cardSubtitle(_ card: CardInfo, state: CardState) -> String {
        switch state {
        case .done: return L10n.assistantCardDone
        case .deferred: return L10n.assistantCardDeferred
        case .locked: return L10n.assistantCardLocked
        case .pending:
            switch card.kind {
            case .shared:
                let pending = docs.activeImport.map { docs.sharedFieldRows(for: $0).filter { !$0.field.isConfirmed }.count } ?? 0
                return L10n.sharedFieldsPending(pending)
            case .entity:
                return L10n.ocrCardFieldCount(card.fieldCount)
            }
        }
    }

    private func mediaStatusText(_ status: MediaInfo.Status) -> String {
        switch status {
        case .processing: return L10n.assistantMediaProcessing
        case .ready: return L10n.assistantMediaReady
        case .failed: return L10n.assistantMediaFailed
        }
    }

    private func openCard(_ card: CardInfo, state: CardState) {
        switch card.kind {
        case .shared:
            activeSheet = .sharedReview(sessionID: card.sessionID)
        case .entity:
            if state == .locked {
                activeSheet = .sharedReview(sessionID: card.sessionID)
                return
            }
            guard let cardID = UUID(uuidString: card.id) else { return }
            activeSheet = .cardReview(cardID: cardID, sessionID: card.sessionID)
        }
    }

    private func background(for message: ChatMessage) -> Color {
        if message.isEmergency { return Color("semantic-danger", bundle: .main).opacity(0.12) }
        if message.isRefusal { return Color("semantic-warning", bundle: .main).opacity(0.12) }
        switch message.role {
        case .user: return Color("brand-primary", bundle: .main).opacity(0.14)
        case .assistant: return Color.secondary.opacity(0.10)
        case .receipt: return Color("semantic-success", bundle: .main).opacity(0.12)
        }
    }

    /// 微信式输入栏（2026-10-19 业主指令）：[语音/键盘] [输入框|点按语音] [＋|发送]。
    /// 文本优先；附件面板在输入栏上方展开（同一栏位，不弹系统菜单）。
    private var inputBar: some View {
        VStack(spacing: 0) {
            if attachmentPanel {
                attachmentPanelView
            }
            if voiceMode, let dictation = chatDictation,
               dictation.phase == .recording || dictation.hasPendingTranscriptions {
                ChatVoiceStatusCard(model: dictation)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 8) {
                modeToggleButton
                if voiceMode {
                    voiceModeButton
                } else {
                    textField
                }
                trailingButton
            }
            .padding(12)
        }
    }

    private var modeToggleButton: some View {
        Button {
            if voiceMode, let dictation = chatDictation,
               dictation.phase == .recording || dictation.hasPendingTranscriptions {
                // 录音/收尾识别中：先正常收尾并留在语音态，等转写交付后再由
                // receiveChatTranscript 切回键盘——立即卸载按钮会触发
                // stopForDisappear 作废在途转写。
                dictation.stop()
                return
            }
            voiceMode.toggle()
            if voiceMode {
                inputFocused = false
                attachmentPanel = false
            }
        } label: {
            Image(systemName: voiceMode ? "keyboard" : "mic.fill")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(voiceMode ? L10n.assistantKeyboardMode : L10n.assistantVoiceMode)
        .accessibilityIdentifier("assistant.modeToggle")
    }

    private var textField: some View {
        TextField(L10n.assistantChatPlaceholder, text: $input, axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .focused($inputFocused)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityIdentifier("assistant.input")
    }

    /// 聊天内语音输入（2026-10-20 业主指令）：不再打开新页面；轻点开始录音，
    /// 再点同一按钮结束。`DictationInteraction` 复用既有授权/前后台/长按纪律。
    @ViewBuilder
    private var voiceModeButton: some View {
        if settingsStore.values[.authVoiceDictation] == "false" {
            Label(L10n.privacyAuthVoiceDisabled, systemImage: "mic.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("assistant.voice.authDisabled")
        } else if let model = chatDictation {
            HStack(spacing: 8) {
                Image(systemName: model.phase == .recording ? "stop.circle.fill" : "mic.fill")
                Text(model.phase == .recording ? L10n.assistantVoiceStop : L10n.assistantVoiceTap)
                    .lineLimit(1)
            }
            .font(.body)
            .foregroundStyle(model.phase == .recording
                             ? Color("semantic-danger", bundle: .main) : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(model.phase == .recording
                        ? Color("semantic-danger", bundle: .main).opacity(0.14)
                        : Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
            .modifier(DictationInteraction(model: model))
            .accessibilityIdentifier("assistant.voiceTap")
        } else {
            Button {
                stopVoicePlayback()
                app.stopSpeaking()
                ensureChatDictationModel()
                chatDictation?.start()
            } label: {
                Text(L10n.assistantVoiceTap)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("assistant.voiceTap")
        }
    }

    /// 装配聊天内听写模型（环境就绪后一次；语言设置变化时重配）。
    private func ensureChatDictationModel() {
        let model = chatDictation ?? VoiceDictationModel(engine: app.transcriptionEngine)
        model.setAuthorization(settingsStore.values[.authVoiceDictation] != "false")
        model.recordingURLProvider = { ChatAudioStore.makeTemporaryURL() }
        model.onRecordingURL = { sessionID, url in
            if let url { pendingVoiceURLs[sessionID] = url }
        }
        model.onTranscript = nil
        model.onTranscriptResult = { sessionID, result in
            receiveChatTranscript(sessionID: sessionID, result.text,
                                  incomplete: result.completion != .final)
        }
        model.onFailure = { sessionID, _ in receiveVoiceFailure(sessionID: sessionID) }
        model.onEmergency = { _ in
            chatDictation?.stopForDisappear()
            dismiss()
            router.navigate(to: .sosHelp)
        }
        model.applyLanguageSettings(settings: settingsStore,
                                    recentDrugNames: hub.inventoryItems.map(\.medicationName))
        if chatDictation == nil { chatDictation = model }
    }

    /// 语音识别完成：语音气泡立即入聊天（音频可选），转写文本回填输入框供编辑发送。
    private func receiveChatTranscript(sessionID: UUID, _ text: String, incomplete: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceURL = takePendingVoiceURL(sessionID)
        guard !trimmed.isEmpty else {
            ChatAudioStore.removeTemporary(voiceURL)
            append(.init(role: .assistant, text: chatDictation?.failureMessage ?? L10n.voicenoteDictationFailed,
                         isRefusal: true))
            finishVoiceBatchIfIdle()
            return
        }
        let filename = voiceURL.flatMap(ChatAudioStore.adopt)
        append(ChatMessage(role: .user, media: MediaInfo(
            kind: .voice, filename: L10n.assistantVoiceMessage, status: .ready,
            source: .voice,
            audioFilename: filename, transcript: trimmed, incomplete: incomplete)))
        // 2026-10-29 批三：语音也回执一句「已转写、点播放键回听」——同批多段
        // 转写只发一次（会话键去重），新一批重新回执。
        if lastVoiceReceiptSession != sessionID {
            append(.init(role: .assistant, text: L10n.assistantVoiceReply))
            lastVoiceReceiptSession = sessionID
        }
        // 保留用户切到语音前已输入的草稿（2026-10-20）。
        input = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? trimmed : input + " " + trimmed
        finishVoiceBatchIfIdle()
    }

    /// 识别失败（权限/引擎/空语音）：必须可见，不得让状态卡静默消失。
    private func receiveVoiceFailure(sessionID: UUID) {
        ChatAudioStore.removeTemporary(takePendingVoiceURL(sessionID))
        append(.init(role: .assistant,
                     text: chatDictation?.failureMessage ?? L10n.voicenoteDictationFailed,
                     isRefusal: true))
        finishVoiceBatchIfIdle()
    }

    private func takePendingVoiceURL(_ sessionID: UUID) -> URL? {
        pendingVoiceURLs.removeValue(forKey: sessionID)
    }

    /// 仍有录音/识别在途时保持语音态（卸载按钮会触发 stopForDisappear
    /// 作废后续交付）；全部结束才切回键盘。
    private func finishVoiceBatchIfIdle() {
        guard chatDictation?.hasPendingTranscriptions != true,
              chatDictation?.phase != .recording else { return }
        voiceMode = false
    }

    /// 空输入（或语音模式）显示 ＋；有文本时换成发送——右端永远只有一个主行动。
    @ViewBuilder
    private var trailingButton: some View {
        if voiceMode || trimmedInput.isEmpty {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { attachmentPanel.toggle() }
                if attachmentPanel { inputFocused = false }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(L10n.assistantAttach)
            .accessibilityIdentifier("assistant.attach")
        } else {
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(isSaving)
            .accessibilityLabel(L10n.assistantSend)
            .accessibilityIdentifier("assistant.send")
        }
    }

    /// 三瓦片横排（2026-10-29 批三 · mock v4 对照）：相机 / 相册 / 文件
    /// 图标各异；标识符沿用（XCUITest 既有用例不破）。相机不可用时不占位。
    private var attachmentPanelView: some View {
        HStack(spacing: 10) {
            if QuickCaptureView.cameraAvailable {
                attachmentTile(L10n.assistantAttachCamera, systemImage: "camera.fill",
                               identifier: "assistant.attach.camera") {
                    startCapture(.camera)
                }
            }
            attachmentTile(L10n.assistantAttachPhotos, systemImage: "photo.on.rectangle",
                           identifier: "assistant.attach.photos") {
                startCapture(.photos)
            }
            attachmentTile(L10n.assistantAttachPDF, systemImage: "doc.fill",
                           identifier: "assistant.attach.pdf") {
                startCapture(.file)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func attachmentTile(_ title: String, systemImage: String,
                                identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(height: 24)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 68)
            .background(Color.secondary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    /// 附件选项直接开系统选择器（2026-10-19 业主：不显示 OCR 前的选择页）。
    private func startCapture(_ source: QuickCaptureView.InitialSource) {
        withAnimation(.easeOut(duration: 0.2)) { attachmentPanel = false }
        inputFocused = false
        switch source {
        case .photos: showPhotoPicker = true
        case .camera: showCamera = true
        case .file: showFileImporter = true
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: AssistantSheet) -> some View {
        switch sheet {
        case .mediaDetail(let documentId, let patientId, let title, let attachmentCount,
                          let attachmentPageOffsets, let conversationID, let conversationTitle):
            // 2026-10-29 批三：媒体气泡 → 速记详情（识别文本 / 信息卡片）；
            // 原图入口在详情页内（DocumentSourcePageView 全屏）。
            ChatMediaDetailView(documentId: documentId, patientId: patientId, title: title,
                                attachmentCount: attachmentCount,
                                attachmentPageOffsets: attachmentPageOffsets,
                                conversationID: conversationID,
                                conversationTitle: conversationTitle)
        case .voiceDetail(let messageID, let media):
            ChatVoiceDetailView(messageID: messageID, audioFilename: media.audioFilename,
                                transcript: media.transcript, incomplete: media.incomplete)
        case .history:
            ChatHistoryView(
                patientId: app.currentPatientId,
                onOpen: { summary in openConversation(summary) },
                onNew: { startNewConversation() },
                onClose: { activeSheet = nil },
                onDelete: { id in
                    if id == conversationID { startNewConversation() }
                },
                onRename: { id, title in
                    // 当前会话改名 → 后续导出目录跟随新会话名；
                    // 已冻结的旧目录不追改（D5）。
                    if id == conversationID { conversationTitle = title }
                })
        case .sharedReview(let sessionID):
            if let session = docs.activeImport, session.id == sessionID {
                SharedFieldsReviewView(session: session, patientId: session.patientId)
                    .onChangeCompat(of: session.sharedFieldsSettled) { _, settled in
                        if settled { activeSheet = nil }
                    }
                    .onChangeCompat(of: session.outcome != nil) { _, finished in
                        if finished { activeSheet = nil }
                    }
            } else {
                reviewUnavailable
            }
        case .cardReview(let cardID, let sessionID):
            ChatCardReviewSheet(cardID: cardID, sessionID: sessionID)
        }
    }

    private var reviewUnavailable: some View {
        NavigationStack {
            VLUnavailableView(L10n.assistantCardUnavailable, systemImage: "checkmark.circle")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.assistantClose) { activeSheet = nil }
                    }
                }
        }
    }

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 历史持久化（2026-10-19 业主指令）

    private struct PersistedMessage: Codable {
        /// 视图层消息 ID：媒体状态/转写更新按它定位历史行（旧快照无此键，容忍）。
        var clientId: String?
        var role: String
        var text: String
        var isRefusal: Bool
        var isEmergency: Bool
        var media: PersistedMedia?
        var card: PersistedCard?
    }
    private struct PersistedMedia: Codable {
        var kind: String
        var filename: String
        var status: String
        var audioFilename: String?
        var transcript: String?
        var documentId: String?
        var patientId: String?
        var incomplete: Bool?
        /// 2026-10-29 批三新增（可选：旧快照缺键→默认 fileImport/1）。
        var source: String?
        var itemCount: Int?
        /// 附件起始页（可选：旧快照缺键→按附件序回落）。
        var attachmentPageOffsets: [Int]?
    }
    private struct PersistedCard: Codable {
        var id: String
        var kind: String
        var entityKind: String?
        var fieldCount: Int
        var sessionID: String
        var snapshotState: String
        var title: String?
    }

    private func persist(_ message: ChatMessage) {
        // 同一视图消息只写一次历史（媒体先渲染、OCR 终态才落库；后续变化走
        // persistUpdate 重写快照）。
        guard persistedMessageIDs.insert(message.id).inserted else { return }
        let role: String
        switch message.role {
        case .user: role = "user"
        case .assistant: role = "assistant"
        case .receipt: role = "receipt"
        }
        let kind = message.media != nil ? "media" : message.card != nil ? "card" : "text"
        let payload = encode(message)
        let title = !titleCaptured ? titleCandidate(message) : nil
        if let title {
            titleCaptured = true
            conversationTitle = title
        }
        let capturedConversation = conversationID
        let generation = conversationGeneration
        enqueuePersistence {
            let id: UUID
            if let capturedConversation {
                id = capturedConversation
            } else {
                guard generation == conversationGeneration else { return }
                guard let created = await ensureConversationID() else { return }
                guard generation == conversationGeneration else { return }
                id = created
            }
            await chatHistory.append(conversationId: id, role: role,
                                     kind: kind, text: message.text, payloadJSON: payload)
            if let title { await chatHistory.rename(id, title: title) }
        }
    }

    /// 串行执行历史写操作：append 与 update 都经此链，避免 update 先到
    /// 命中 0 行（媒体 processing→ready 丢失）。
    private func enqueuePersistence(_ operation: @escaping @MainActor () async -> Void) {
        let previous = persistenceTail
        persistenceTail = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    /// 媒体/语音消息状态与转写变化后重写历史快照（2026-10-20）。
    /// 只更新已落库的消息；未落库（历史写入失败/旧会话）时静默跳过。
    private func persistUpdate(_ messageID: UUID) {
        // 2026-10-23 修复（历史图片打不开的根因）：首条消息的 append 异步创建
        // 会话；若 OCR 很快完成，旧的 `guard let conversationID` 会在会话 id
        // 回填前静默放弃终态快照——历史里只剩 processing 且无 documentId 的
        // 媒体行，气泡不可点。终态更新改走持久化串行链，在执行时再取/建会话。
        guard let message = messages.first(where: { $0.id == messageID }),
              let payload = encode(message) else { return }
        let capturedConversation = conversationID
        let generation = conversationGeneration
        enqueuePersistence {
            let id: UUID
            if let capturedConversation {
                id = capturedConversation
            } else {
                guard generation == conversationGeneration,
                      let created = await ensureConversationID(expectedGeneration: generation) else { return }
                id = created
            }
            await chatHistory.updateMessagePayload(conversationId: id,
                                                   clientId: messageID,
                                                   payloadJSON: payload)
        }
    }

    /// 懒创建会话：首条消息落库前不产生空会话；并发首条消息只保留一个会话。
    private func ensureConversationID(expectedGeneration: UUID? = nil) async -> UUID? {
        if let conversationID { return conversationID }
        guard let created = await chatHistory.createConversation(
            patientId: app.currentPatientId, title: L10n.assistantNewConversation) else { return nil }
        // 创建期间用户已切会话：删掉刚建的空会话，不得把旧任务写进新会话。
        if let expectedGeneration, expectedGeneration != conversationGeneration {
            Task { await chatHistory.delete(created) }
            return nil
        }
        if let existing = conversationID {
            Task { await chatHistory.delete(created) }
            return existing
        }
        conversationID = created
        return created
    }

    private func titleCandidate(_ message: ChatMessage) -> String? {
        guard message.role == .user else { return nil }
        if let media = message.media {
            // ASR：语音转写文本直接作为会话名（内容相关）。
            // 图片/PDF：文件名通常是「照片」这类泛称，等 OCR 结果再命名
            // （autoTitleFromImport），此处返回 nil。
            guard media.kind == .voice,
                  let transcript = media.transcript,
                  !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return String(transcript.prefix(24))
        }
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(24))
    }

    /// OCR 会话自动命名（2026-10-20 业主指令）：首个实体卡类型 + 首个识别值
    /// （如「检验报告 · 血红蛋白」「处方 · 阿莫西林」）；无实体卡时用共同信息，
    /// 叙事型资料回落文档类型名；用户已命名/已捕获则不再覆盖。
    /// 2026-10-30：改成 async 并返回最终标题——导出的会话目录要等命名完成，
    /// 才拿到与聊天历史一致的目录名。
    @discardableResult
    private func autoTitleFromImport(_ session: DocumentsState.ImportSession) async -> String? {
        let generation = conversationGeneration
        guard !titleCaptured else { return conversationTitle }
        let title: String?
        if let card = session.cards.first {
            let kind = L10n.entityCardKindName(card.kind)
            if let value = card.rows.flatMap(\.fields)
                .map(\.value)
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                title = "\(kind) · \(value)"
            } else {
                title = kind
            }
        } else if !docs.sharedFieldRows(for: session).isEmpty {
            title = L10n.sharedFieldsTitle
        } else if let docType = session.draft?.docType.trimmingCharacters(in: .whitespacesAndNewlines),
                  !docType.isEmpty {
            // 出院记录/病历等 0 字段叙事资料也有会话名，不再落回「新对话」。
            title = docType
        } else {
            title = nil
        }
        guard let title else { return conversationTitle }
        // 会话已切换时不得把旧导入的标题写到新会话，也不得给导出提供错名。
        guard generation == conversationGeneration else { return nil }
        titleCaptured = true
        let trimmed = String(title.prefix(40))
        conversationTitle = trimmed
        guard let id = await ensureConversationID(expectedGeneration: generation) else { return nil }
        guard generation == conversationGeneration else { return nil }
        await chatHistory.rename(id, title: trimmed)
        return trimmed
    }

    private func encode(_ message: ChatMessage) -> String? {
        let role: String
        switch message.role {
        case .user: role = "user"
        case .assistant: role = "assistant"
        case .receipt: role = "receipt"
        }
        let media = message.media.map {
            PersistedMedia(kind: mediaKind($0.kind), filename: $0.filename,
                           status: mediaStatus($0.status),
                           audioFilename: $0.audioFilename, transcript: $0.transcript,
                           documentId: $0.documentId?.uuidString,
                           patientId: $0.patientId?.uuidString,
                           incomplete: $0.incomplete,
                           source: $0.source.rawValue, itemCount: $0.itemCount,
                           attachmentPageOffsets: $0.attachmentPageOffsets)
        }
        let card = message.card.map {
            PersistedCard(id: $0.id, kind: $0.kind == .shared ? "shared" : "entity",
                          entityKind: $0.entityKind, fieldCount: $0.fieldCount,
                          sessionID: $0.sessionID.uuidString,
                          snapshotState: snapshotState($0),
                          title: cardTitle($0))
        }
        let payload = PersistedMessage(clientId: message.id.uuidString,
                                       role: role, text: message.text,
                                       isRefusal: message.isRefusal, isEmergency: message.isEmergency,
                                       media: media, card: card)
        guard let data = try? JSONEncoder().encode(payload) else { return nil }   // try?-ok: 编码失败则本消息不落历史
        return String(decoding: data, as: UTF8.self)
    }

    private func decode(_ stored: ChatHistoryStore.StoredMessage) -> ChatMessage? {
        guard let json = stored.payloadJSON, let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PersistedMessage.self, from: data) else {   // try?-ok: 旧/损坏快照回落纯文本
            let role: ChatMessage.Role = stored.role == "user" ? .user
                : stored.role == "receipt" ? .receipt : .assistant
            return ChatMessage(role: role, text: stored.text)
        }
        let role: ChatMessage.Role = payload.role == "user" ? .user
            : payload.role == "receipt" ? .receipt : .assistant
        let media = payload.media.map {
            MediaInfo(kind: mediaKind(from: $0.kind), filename: $0.filename,
                      status: mediaStatus(from: $0.status),
                      source: MediaSource(rawValue: $0.source ?? "") ?? .unknown,
                      itemCount: $0.itemCount ?? 1,
                      attachmentPageOffsets: $0.attachmentPageOffsets,
                      audioFilename: $0.audioFilename, transcript: $0.transcript,
                      documentId: $0.documentId.flatMap(UUID.init(uuidString:)),
                      patientId: $0.patientId.flatMap(UUID.init(uuidString:)),
                      incomplete: $0.incomplete ?? false)
        }
        let card = payload.card.map {
            CardInfo(id: $0.id, kind: $0.kind == "shared" ? .shared : .entity,
                     entityKind: $0.entityKind, fieldCount: $0.fieldCount,
                     sessionID: UUID(uuidString: $0.sessionID) ?? UUID(),
                     snapshotState: $0.snapshotState)
        }
        return ChatMessage(role: role, text: payload.text, isRefusal: payload.isRefusal,
                           isEmergency: payload.isEmergency, media: media, card: card)
    }

    private func mediaKind(_ kind: MediaInfo.Kind) -> String {
        switch kind { case .image: return "image"; case .pdf: return "pdf"
        case .file: return "file"; case .voice: return "voice" }
    }
    private func mediaKind(from raw: String) -> MediaInfo.Kind {
        switch raw { case "image": return .image; case "pdf": return .pdf
        case "voice": return .voice; default: return .file }
    }
    private func mediaStatus(_ status: MediaInfo.Status) -> String {
        switch status { case .processing: return "processing"; case .ready: return "ready"; case .failed: return "failed" }
    }
    private func mediaStatus(from raw: String) -> MediaInfo.Status {
        switch raw { case "ready": return .ready; case "failed": return .failed; default: return .processing }
    }
    private func snapshotState(_ card: CardInfo) -> String {
        switch cardState(card) {
        case .done: return "done"; case .deferred: return "deferred"
        case .pending: return "pending"; case .locked: return "locked"
        }
    }

    private func syncCardSnapshots() {
        guard let conversationID else { return }
        for message in messages {
            guard let card = message.card else { continue }
            let state = snapshotState(card)
            Task { await chatHistory.updateCardSnapshot(conversationId: conversationID,
                                                        cardId: card.id, state: state) }
        }
    }

    private func openConversation(_ summary: ChatHistoryStore.ConversationSummary) {
        let generation = UUID()
        conversationGeneration = generation
        Task {
            // 审查席 P2：nil=读取失败，不得把失败当空会话打开（三值纪律）。
            guard let stored = await chatHistory.loadMessages(conversationId: summary.id) else {
                await MainActor.run {
                    append(.init(role: .assistant, text: L10n.assistantHistoryLoadFailed, isRefusal: true))
                }
                return
            }
            await MainActor.run {
                // 用户快速点开另一会话时，旧请求不得把首个会话内容写回来。
                guard generation == conversationGeneration else { return }
                stopVoicePlayback()
                interruptInFlightImports()
                conversationID = summary.id
                conversationTitle = summary.title
                titleCaptured = true
                // 旧版本落库的卡片消息不再渲染（业主 2026-10-29：卡片只在
                // 媒体详情）；过滤在解码后，历史数据保留可回溯。
                messages = stored.compactMap(decode).filter { $0.card == nil }
                resetTransient()
                activeSheet = nil
            }
        }
    }

    /// 切会话时把仍在 OCR 的图片/PDF 消息落成失败快照。迟到的
    /// `finishImport` 会被世代守卫丢弃，若不先收尾，旧会话会永久停在
    /// 「识别中」（2026-10-30 审查席 P1）。语音转写不在此列。
    private func interruptInFlightImports() {
        for message in messages
        where message.media?.status == .processing && message.media?.kind != .voice {
            updateMedia(message.id, status: .failed)
        }
    }

    private func startNewConversation() {
        // 懒创建：清空界面即可；首条消息落库时创建会话，避免空行。
        stopVoicePlayback()
        interruptInFlightImports()
        conversationGeneration = UUID()
        conversationID = nil
        conversationTitle = nil
        titleCaptured = false
        messages = []
        resetTransient()
        activeSheet = nil
    }

    private func resetTransient() {
        confirmSet = nil
        pendingPlan = nil
        pendingClarification = nil
        isSaving = false
        input = ""
        persistedMessageIDs = []
    }

    // MARK: - 媒体采集 → 全图 OCR → 信息卡（2026-10-19 业主指令）

    /// 多选照片（2026-10-23 业主）：单张保持原图路径；多张按选择顺序
    /// 合并为一份多页 PDF，只起一个 OCR 会话，跨页内容统一归并。
    /// 2026-10-30：解码后先进入导入前检查（放大/旋转），确认再识别。
    private func handlePickedPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        pickedPhotos = []
        Task {
            var images: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),   // try?-ok: 逐张跳过读取失败
                   let image = UIImage(data: data) {
                    images.append(image)
                }
            }
            guard !images.isEmpty else {
                append(.init(role: .assistant, text: L10n.assistantMediaFailed, isRefusal: true))
                return
            }
            presentImportPreview(ImportPreviewRequest(
                images: images, pdfs: [],
                filename: images.count > 1 ? L10n.assistantMergedPhotosFilename
                                           : L10n.assistantAttachPhotos,
                kind: .image, origin: "photoLibrary", source: .photoLibrary))
        }
    }

    /// 系统选择器/相机正在收起时，同一 presentation 事务里再弹全屏页会被
    /// iOS 16 丢弃；统一延后一拍（2026-10-30 审查席 P1）。
    private func presentImportPreview(_ request: ImportPreviewRequest,
                                      delayNanoseconds: UInt64 = 350_000_000) {
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            importPreview = request
        }
    }

    private func handleCameraImage(_ image: UIImage) {
        showCamera = false
        presentImportPreview(ImportPreviewRequest(
            images: [image], pdfs: [], filename: L10n.assistantAttachCamera,
            kind: .image, origin: "camera", source: .camera),
            delayNanoseconds: 450_000_000)
    }

    private func handleImportedFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        if urls.count == 1, let url = urls.first, url.pathExtension.lowercased() == "pdf" {
            // PDF 页方向由原件决定，不走图片预览；直接进导入链。
            // 文件选择器 URL 是安全作用域：读取期间必须持有访问权，否则
            // 关闭选择器后再读原件会被系统拒绝（2026-10-30 复审）。
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                await importURL(url, filename: url.lastPathComponent, kind: .pdf)
            }
            return
        }
        Task { await prepareFileImport(urls) }
    }

    /// 文件导入：图片先预览（放大/旋转），PDF 随请求一起合并。
    /// 保持文件顺序（图片在前、PDF 在后，与合并器入参顺序一致）。
    private func prepareFileImport(_ urls: [URL]) async {
        var scopes: [URL] = []
        for url in urls where url.startAccessingSecurityScopedResource() {
            scopes.append(url)
        }
        defer { for url in scopes { url.stopAccessingSecurityScopedResource() } }

        var images: [UIImage] = []
        var pdfs: [PDFDocument] = []
        for url in urls {
            if url.pathExtension.lowercased() == "pdf" {
                // 先读进内存再建 PDFDocument：安全作用域关闭后按需读页会失败。
                if let data = try? Data(contentsOf: url),   // try?-ok: 逐份跳过不可读文件
                   let document = PDFDocument(data: data) {
                    pdfs.append(document)
                }
            } else if let data = try? Data(contentsOf: url),   // try?-ok: 逐份跳过不可读文件
                      let image = UIImage(data: data) {
                images.append(image)
            }
        }
        guard !images.isEmpty || !pdfs.isEmpty else {
            append(.init(role: .assistant, text: L10n.assistantMediaFailed, isRefusal: true))
            return
        }
        if images.isEmpty {
            await importMerged(images: [], pdfs: pdfs,
                               filename: L10n.assistantMergedFilesFilename,
                               kind: .pdf, origin: "import",
                               source: .fileImport)
            return
        }
        // 单份图片文件保留真实文件名（气泡/资料库/导出副本可对照原件；
        // 2026-10-30 复审：重构丢掉 lastPathComponent 后一律显示「文件速记」）。
        let singleImageName: String? = {
            guard urls.count == 1, pdfs.isEmpty, images.count == 1,
                  urls[0].pathExtension.lowercased() != "pdf" else { return nil }
            return urls[0].lastPathComponent
        }()
        presentImportPreview(ImportPreviewRequest(
            images: images, pdfs: pdfs,
            filename: singleImageName
                ?? (pdfs.isEmpty ? L10n.assistantMergedFilesFilename
                                 : L10n.assistantMergedMixedFilename),
            kind: pdfs.isEmpty ? .image : .pdf,
            origin: "import", source: .fileImport))
    }

    /// 检查页确认后：单图走原图路径，其余按序合并为一份多页 PDF。
    private func handlePreviewConfirmed(_ images: [UIImage], request: ImportPreviewRequest) {
        Task {
            if request.pdfs.isEmpty, images.count == 1, let image = images.first {
                guard let data = await Self.normalizedJPEGData(image) else {
                    append(.init(role: .assistant, text: L10n.assistantMediaFailed, isRefusal: true))
                    return
                }
                await importImage(data, filename: request.filename,
                                  origin: request.origin, source: request.source)
                return
            }
            await importMerged(images: images, pdfs: request.pdfs,
                               filename: request.filename, kind: request.kind,
                               origin: request.origin, source: request.source)
        }
    }

    /// 方向归一 + JPEG 编码（EXIF 方向合入像素，OCR 不再读到侧躺/倒置画面）。
    /// 归一实现与合并 PDF 共用 `MediaImport.normalizedImage`（单一出口）。
    /// 全幅重绘 + quality=1 编码移出主线程（2026-10-30 效率批：12MP 单图
    /// 主线程编码可达数百毫秒，导入确认按钮后整页卡顿）。
    private static func normalizedJPEGData(_ image: UIImage) async -> Data? {
        let box = MergeImageBox(image)
        return await Task.detached(priority: .userInitiated) {
            MediaImport.normalizedImage(box.image).jpegData(compressionQuality: 1)
        }.value
    }

    private func importMerged(images: [UIImage], pdfs: [PDFDocument],
                              filename: String, kind: MediaInfo.Kind, origin: String,
                              source: MediaSource) async {
        var payloads: [ChatAttachmentMerger.Payload] = []
        payloads.append(contentsOf: images.map { ChatAttachmentMerger.Payload.image($0) })
        payloads.append(contentsOf: pdfs.map { ChatAttachmentMerger.Payload.pdf($0) })
        // 合并（多图全幅重绘 + 多页 PDF 写入）移出主线程：15–30 张导入时
        // 主线程连续数百毫秒的重绘/编码是确认后整页卡顿的主因（2026-10-30 效率批）。
        // let 快照：并发闭包不得捕获 var（Swift 6 发送性检查）。
        let mergeInput = payloads
        guard let merged = await Task.detached(priority: .userInitiated, operation: {
            ChatAttachmentMerger.merge(mergeInput)
        }).value else {
            append(.init(role: .assistant, text: L10n.assistantMediaFailed, isRefusal: true))
            return
        }
        // 附件数取合并器实测落页数（页数上限截断/坏页跳过后不虚报；
        // 每个附件的起始页随快照持久化，详情缩略图点第 N 张跳真实页）。
        let offsets = merged.attachmentOffsets
        guard let messageID = appendMedia(filename: filename, kind: kind,
                                          source: source, itemCount: max(1, offsets.count),
                                          pageOffsets: offsets.isEmpty ? nil : offsets) else { return }
        importing = true
        defer { importing = false }
        guard let session = startChatSession() else {
            failMedia(messageID, text: L10n.assistantImportBusy)
            return
        }
        let draft = await docs.importPDFData(patientId: session.patientId, data: merged.data,
                                             title: filename, isSensitive: false, origin: origin)
        await finishImport(draft, session: session, messageID: messageID)
        if merged.truncated {
            append(.init(role: .assistant, text: L10n.assistantAttachmentTruncated,
                         isRefusal: true))
        }
    }

    /// 全图识别：originalData == processedData，跳过区域/遮挡选择（业主 2026-10-19）。
    private func importImage(_ data: Data, filename: String, origin: String,
                             source: MediaSource) async {
        guard let messageID = appendMedia(filename: filename, kind: .image,
                                          source: source) else { return }
        importing = true
        defer { importing = false }
        guard let session = startChatSession() else {
            failMedia(messageID, text: L10n.assistantImportBusy)
            return
        }
        let draft = await docs.prepareImageDraft(
            patientId: session.patientId,
            originalData: data, processedData: data,
            mimeType: ImageInputRules.sniffMimeType(of: data),
            docType: nil, title: nil, isSensitive: false, origin: origin)
        await finishImport(draft, session: session, messageID: messageID)
    }

    private func importURL(_ url: URL, filename: String, kind: MediaInfo.Kind) async {
        guard let messageID = appendMedia(filename: filename, kind: kind,
                                          source: .fileImport) else { return }
        importing = true
        defer { importing = false }
        guard let session = startChatSession() else {
            failMedia(messageID, text: L10n.assistantImportBusy)
            return
        }
        let draft = await docs.importDocument(patientId: session.patientId, url: url,
                                              docType: nil, isSensitive: false)
        await finishImport(draft, session: session, messageID: messageID)
    }

    @discardableResult
    private func appendMedia(filename: String, kind: MediaInfo.Kind,
                             source: MediaSource, itemCount: Int = 1,
                             pageOffsets: [Int]? = nil) -> UUID? {
        guard docs.activeImport == nil else {
            append(.init(role: .assistant, text: L10n.assistantImportBusy, isRefusal: true))
            return nil
        }
        let message = ChatMessage(role: .user,
                                  media: MediaInfo(kind: kind, filename: filename,
                                                   status: .processing,
                                                   source: source, itemCount: itemCount,
                                                   attachmentPageOffsets: pageOffsets))
        // 立即落库（processing 快照）：OCR 中被强退/切会话也不丢上传记录；
        // 终态经串行链 update 覆盖（2026-10-20）。
        append(message)
        return message.id
    }

    private func startChatSession() -> DocumentsState.ImportSession? {
        guard docs.activeImport == nil,
              let session = docs.beginImport(patientId: app.currentPatientId) else { return nil }
        session.captureSensitive = true
        // 聊天导入的用户面副本统一由 finishImport 在会话命名后导出到
        // 「<日期时间>-<会话名>-<短ID>」目录；设置里的自动镜像（月桶）跳过，
        // 避免同件双份（2026-10-30 业主）。
        session.suppressAutoMirrorHook = true
        chatSessionID = session.id
        importGeneration = conversationGeneration
        return session
    }

    /// 导入是否仍属于当前会话（含同代次、同一导入槽）。OCR 耗时较长，
    /// 用户此时可切历史/新建会话；旧导入不得把回执、标题或用户面副本
    /// 写进新会话（2026-10-30 审查席 P1）。
    private func importIsCurrent(_ session: DocumentsState.ImportSession) -> Bool {
        chatSessionID == session.id && importGeneration == conversationGeneration
    }

    /// 被切会话甩下的导入：保留已落库原件，未完成卡片整批转待办，释放导入槽。
    private func discardSupersededImport(_ session: DocumentsState.ImportSession) async {
        if session.source == nil {
            docs.cancelImport(sessionID: session.id)
        } else {
            _ = await docs.deferRemainingEntityCards()
            // 卡已全部转待办后补结算（deferRemaining 自身不改 outcome），
            // 否则 finishImportPresentation 不放槽，后续导入一直提示忙碌。
            docs.finishEntityQueueIfNeeded()
        }
        _ = docs.finishImportPresentation(sessionID: session.id)
        if chatSessionID == session.id {
            chatSessionID = nil
            importGeneration = nil
        }
    }

    private func finishImport(_ draft: DocumentsState.ImportDraft?,
                              session: DocumentsState.ImportSession,
                              messageID: UUID?) async {
        // 切会话后迟到的 OCR 收尾：不写回执、不命名、不导出到新会话。
        guard importIsCurrent(session) else {
            await discardSupersededImport(session)
            return
        }
        // 重复资料：聊天内不静默覆盖（ADR-019），保留原件并提示去资料库处理。
        if session.duplicate != nil {
            updateMedia(messageID, status: .failed)
            append(.init(role: .assistant, text: L10n.assistantMediaDuplicate, isRefusal: true))
            _ = await docs.resolveDuplicate(.keep)
            _ = docs.finishImportPresentation(sessionID: session.id)
            chatSessionID = nil
            importGeneration = nil
            return
        }
        guard let draft else {
            await failImport(session: session, messageID: messageID, text: L10n.assistantMediaFailed)
            return
        }
        guard draft.docTypeResolved else {
            await failImport(session: session, messageID: messageID,
                             text: L10n.assistantDocTypeUnresolved)
            return
        }
        guard await docs.commitDraft(draft) else {
            await failImport(session: session, messageID: messageID, text: L10n.assistantMediaFailed)
            return
        }
        // 落库期间切换会话：原件已保留，但回执/标题/导出不得进新会话。
        guard importIsCurrent(session) else {
            await discardSupersededImport(session)
            return
        }
        updateMedia(messageID, status: .ready,
                    document: session.source.map { (id: $0.documentId, patient: $0.patientId) })
        // 2026-10-29 批三：识别完成先回执一句（字段数取真值），再列待确认卡片。
        // 只陈述识别事实与处置边界，不解读内容（BR-006 措辞负清单）。
        let replyFields = docs.sharedFieldRows(for: session).count
            + session.cards.reduce(0) { total, card in
                total + card.shared.count + card.rows.reduce(0) { $0 + $1.fields.count }
            }
        // 叙事型资料（出院记录等）0 字段也须回执（UX 席 P2-11）：两种模板二选一。
        append(.init(role: .assistant, text: replyFields > 0
            ? L10n.assistantOcrReply(replyFields)
            : L10n.assistantOcrReplyPlain))
        // 业主 2026-10-29：信息卡片不再进聊天流——只保留一句识别回执，
        // 卡片的「需要修改/已确认」两区统一在媒体详情页呈现。
        // OCR 内容命名放在回执之后：会话已创建/已有首条消息，改名命中同一会话。
        // 2026-10-30：命名完成后立即把（非敏感）原件导出到会话目录，
        // 「文件」App 才看得到与聊天会话同名、带日期时间前缀的目录。
        let title = await autoTitleFromImport(session)
        guard importIsCurrent(session) else {
            await discardSupersededImport(session)
            return
        }
        // 先释放导入槽再写用户面副本（2026-10-30 效率批）：导出只依赖已
        // 落库文档与会话代次，不再占住「导入进行中」——否则 10–30MB 文件
        // 复制期间用户无法开始下一份；代次守卫仍防切换会话后写错目录。
        let exportGeneration = conversationGeneration
        await releaseChatImportSession(session)
        guard exportGeneration == conversationGeneration else { return }
        await exportChatMedia(session: session, title: title,
                              generation: exportGeneration)
    }

    /// 导入收尾：未处理卡整批落待办、结算并释放导入槽（详情页仍可续办）。
    private func releaseChatImportSession(_ session: DocumentsState.ImportSession) async {
        guard docs.activeImport?.id == session.id else { return }
        _ = await docs.deferRemainingEntityCards()
        docs.finishEntityQueueIfNeeded()
        _ = docs.finishImportPresentation(sessionID: session.id)
        if chatSessionID == session.id {
            chatSessionID = nil
            importGeneration = nil
        }
    }

    /// 聊天媒体用户面副本（2026-10-30 业主：「文件」App 里按会话名建目录）。
    /// 只导出非敏感件（BR-007/008：敏感媒体不自动出界）；目录名带
    /// `yyyyMMdd-HHmm` 前缀，首次导出即冻结（D5），同会话后续资料复用同目录。
    private func exportChatMedia(session: DocumentsState.ImportSession, title: String?,
                                 generation: UUID) async {
        guard let source = session.source else { return }
        guard generation == conversationGeneration else { return }
        guard let conversationID = await ensureConversationID(expectedGeneration: generation),
              generation == conversationGeneration else { return }
        _ = await exportState.exportCopy(
            documentID: source.documentId,
            conversationID: conversationID,
            conversationTitle: title ?? conversationTitle,
            allowSensitive: false)
    }

    private func updateMedia(_ messageID: UUID?, status: MediaInfo.Status,
                             document: (id: UUID, patient: UUID)? = nil) {
        guard let messageID, let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].media?.status = status
        if let document {
            messages[index].media?.documentId = document.id
            messages[index].media?.patientId = document.patient
        }
        // 终态才落历史：processing 快照没有保留价值，也避免与 OCR 收尾竞态。
        guard status != .processing else { return }
        if persistedMessageIDs.contains(messageID) {
            persistUpdate(messageID)
        } else {
            persist(messages[index])
        }
    }

    private func failMedia(_ messageID: UUID?, text: String) {
        updateMedia(messageID, status: .failed)
        append(.init(role: .assistant, text: text, isRefusal: true))
    }

    private func failImport(session: DocumentsState.ImportSession, messageID: UUID?,
                            text: String) async {
        updateMedia(messageID, status: .failed)
        append(.init(role: .assistant, text: text, isRefusal: true))
        if session.source == nil {
            docs.cancelImport(sessionID: session.id)
        } else {
            _ = await docs.deferRemainingEntityCards()
            // deferRemaining 只出队不结算；不补结算则 finishImportPresentation
            // 不放槽，聊天页后续导入永久卡在「导入进行中」。
            docs.finishEntityQueueIfNeeded()
        }
        _ = docs.finishImportPresentation(sessionID: session.id)
        chatSessionID = nil
        importGeneration = nil
    }

    /// 关闭聊天时收尾：未完成卡整批落待办（用户的识别成果不丢），释放导入槽。
    private func releaseChatSessionIfNeeded() {
        guard let sessionID = chatSessionID,
              let session = docs.activeImport, session.id == sessionID else { return }
        Task {
            if session.outcome == nil {
                if session.source == nil {
                    docs.cancelImport(sessionID: sessionID)
                } else {
                    _ = await docs.deferRemainingEntityCards()
                    docs.finishEntityQueueIfNeeded()
                }
            }
            _ = docs.finishImportPresentation(sessionID: sessionID)
            if chatSessionID == sessionID {
                chatSessionID = nil
                importGeneration = nil
            }
        }
    }

    // MARK: - 确定性流程

    private func send() {
        let text = trimmedInput
        guard !text.isEmpty, !isSaving else { return }
        input = ""
        append(.init(role: .user, text: text))

        // B1 定标门：未通过脚本金样定标时不得执行结构化路径（FR17.4 不变量）。
        guard FeatureFlags.voiceDeterministicEnabled else {
            append(.init(role: .assistant, text: L10n.assistantDisabled, isRefusal: true))
            return
        }

        // BR-012：急救词前置，终止解析，不生成任何动作，并进急救卡/SOS。
        if EmergencyKeywordRules.match(text) {
            handleEmergency()
            return
        }
        // BR-006：停药/调量/换药类 → 安全拒识。
        if HighRiskTopicRules.match(text) {
            append(.init(role: .assistant, text: L10n.ai_refusedHighRisk, isRefusal: true))
            return
        }

        // 脚本化补槽：只补上一个追问的槽位，不构成自由对话。
        if let spec = pendingClarification, let plan = pendingPlan {
            let filled = VoiceActionPlanner.filling(plan, key: spec.key, value: text)
            pendingClarification = nil
            presentConfirmation(for: filled)
            return
        }

        let result = VoiceIntentCatalog.classify(text, confidence: 1.0)
        let plan = VoiceActionPlanner.plan(
            intentKey: result.suggestedTarget ?? VoiceIntentKey.unknown.rawValue,
            transcript: text, drafts: result.fields,
            patientId: app.currentPatientId, source: .text)
        if plan.riskFlags.contains(.emergency) {
            handleEmergency()
            return
        }
        if plan.riskFlags.contains(.highRiskTopic) {
            append(.init(role: .assistant, text: L10n.ai_refusedHighRisk, isRefusal: true))
            return
        }
        if let spec = VoiceActionPlanner.nextClarification(for: plan) {
            pendingPlan = plan
            pendingClarification = spec
            append(.init(role: .assistant,
                         text: L10n.assistantClarify(slotLabel(spec))))
            return
        }
        presentConfirmation(for: plan, confidence: result.targetConfidence)
    }

    /// BR-012 终止路径：清空所有未完成状态，关闭会话并进 SOS（免门禁，FR1.8）。
    private func handleEmergency() {
        pendingPlan = nil
        pendingClarification = nil
        confirmSet = nil
        isSaving = false
        append(.init(role: .assistant, text: L10n.assistantEmergencyHandoff,
                     isRefusal: true, isEmergency: true))
        dismiss()
        router.navigate(to: .sosHelp)
    }

    private func presentConfirmation(for plan: VoiceActionPlan, confidence: Double = 1.0) {
        pendingPlan = plan
        judgedTarget = plan.intent.rawValue
        judgedConfidence = confidence
        confirmSet = VoiceInputTemplate.confirmationSet(drafts: plan.fieldDrafts)
    }

    /// 确认卡内改类（FR17.19「判定结果行 Menu 一键改类」）：
    /// 用同一原文重跑该意图的期一抽取，重建计划；缺槽以空字段进确认卡。
    private func reclassify(to key: String) {
        guard let plan = pendingPlan, let intent = VoiceIntentKey(rawValue: key) else { return }
        let drafts = VoiceIntentCatalog.extract(for: intent, text: plan.transcript, confidence: 1.0)
        let rebuilt = VoiceActionPlanner.plan(intentKey: key, transcript: plan.transcript,
                                              drafts: drafts, patientId: plan.patientId,
                                              source: plan.source)
        pendingClarification = nil
        // 先关旧 sheet，下一拍再呈现新 confirmSet——同一渲染帧内替换 item
        // 会让 sheet 内容与 onConfirm 捕获的旧 set 错配（改类竞态）。
        confirmSet = nil
        Task { @MainActor in
            await Task.yield()
            presentConfirmation(for: rebuilt)
        }
    }

    private func handleConfirmation(_ set: OcrConfirmationSet) {
        guard let plan = pendingPlan, !isSaving else { return }
        confirmSet = nil   // 标准确认卡一次性关闭（与 VoiceQuickLaunch 同语义）
        isSaving = true
        // 确认值重建计划：用户编辑即核对，编辑后的值以 C 级进入动作。
        let drafts = set.confirmedFields.map {
            FieldDraft(key: $0.key, value: $0.value, confidence: 1.0,
                       rawText: $0.rawText, grade: .userConfirmed)
        }
        let rebuilt = VoiceActionPlanner.plan(
            intentKey: plan.intent.rawValue, transcript: plan.transcript,
            drafts: drafts, patientId: plan.patientId, source: plan.source,
            clarificationCount: plan.clarificationCount)
        // 确认不重置 TTL：沿用原计划的时间窗，防止确认卡久留后执行旧计划。
        var ttlPreserved = rebuilt
        ttlPreserved.createdAt = plan.createdAt
        ttlPreserved.expiresAt = plan.expiresAt
        guard !ttlPreserved.riskFlags.contains(.emergency),
              !ttlPreserved.riskFlags.contains(.highRiskTopic) else {
            isSaving = false
            pendingPlan = nil
            append(.init(role: .assistant, text: L10n.ai_refusedHighRisk, isRefusal: true))
            return
        }
        // 必填仍缺：不要清计划后报通用失败，重新呈现确认卡让用户补全。
        guard ttlPreserved.missingRequiredKeys.isEmpty else {
            isSaving = false
            pendingPlan = ttlPreserved
            confirmSet = VoiceInputTemplate.confirmationSet(drafts: ttlPreserved.fieldDrafts)
            append(.init(role: .assistant, text: L10n.assistantMissingFields, isRefusal: true))
            return
        }
        let confirmationId = UUID()
        let confirmed = VoiceActionPlanner.confirming(ttlPreserved, confirmationId: confirmationId)
        let actions = VoiceActionPlanner.verifiedActions(for: confirmed,
                                                         confirmationId: confirmationId)
        guard let action = actions.first, action.patientId == app.currentPatientId else {
            isSaving = false
            pendingPlan = nil
            append(.init(role: .assistant, text: L10n.assistantSaveFailed, isRefusal: true))
            return
        }
        let audit = VoiceExecutionAudit(plan: confirmed, action: action, actor: "owner")
        recordConfirmationAudit(audit)
        pendingPlan = nil
        execute(action, plan: confirmed, audit: audit, confirmationSet: set)
    }

    private func execute(_ action: VerifiedAction, plan: VoiceActionPlan,
                         audit: VoiceExecutionAudit, confirmationSet set: OcrConfirmationSet) {
        switch action.kind {
        case .recordMetric:
            route(.metricQuickEntry, plan: plan, action: action, set: set)
        case .createReminder:
            route(.voiceReminderDraft, plan: plan, action: action, set: set)
        case .appendProfile:
            // 语音引导档案已退役（2026-10-22）：只跳转成员档案，由用户手动完善。
            router.navigate(to: .memberList)
        case .recordObservation:
            route(.observationCreate, plan: plan, action: action, set: set)
        case .createAppointment:
            route(.appointmentForm(nil), plan: plan, action: action, set: set)
        case .createQuestion:
            let body = action.slotValues["question"] ?? action.rawTranscript
            Task {
                let ok = await questions.add(patientId: action.patientId, body: body, audit: audit)
                await MainActor.run { finishDirectSave(ok: ok, text: L10n.assistantSavedQuestion) }
            }
        case .appendNote:
            let body = action.slotValues["note"] ?? action.rawTranscript
            Task {
                let ok = await voiceNotes.create(patientId: action.patientId, body: body,
                                                 tags: nil, audit: audit)
                await MainActor.run { finishDirectSave(ok: ok, text: L10n.assistantSavedNote) }
            }
        case .appendMedDraft:
            // 期二接线：只允许 raw-text 草稿，不写计划/库存/提醒。
            isSaving = false
            append(.init(role: .assistant, text: L10n.assistantMedDraftDeferred, isRefusal: true))
        }
    }

    private func route(_ target: AppRoute, plan: VoiceActionPlan,
                       action: VerifiedAction, set: OcrConfirmationSet) {
        // 一次性投递：已有未消费草稿时拒绝覆盖（防止上一个动作被静默顶掉）。
        guard router.pendingVoiceIntent == nil else {
            isSaving = false
            append(.init(role: .assistant, text: L10n.assistantSaveFailed, isRefusal: true))
            return
        }
        router.pendingVoiceIntent = set.pendingIntent(
            plan.intent.rawValue, patientId: plan.patientId,
            sourcePlanId: plan.planId, confirmationId: action.confirmationId,
            idempotencyKey: action.idempotencyKey, actionKind: action.kind.rawValue)
        isSaving = false
        router.navigate(to: target)
        dismiss()
    }

    /// 确认事件审计（与业务写分事务，只记录交接；直存动作另有同事务 `voice.execute`）。
    /// 审计失败不阻断用户保存（best-effort；错误留待 L2 观测）。
    private func recordConfirmationAudit(_ audit: VoiceExecutionAudit) {
        guard let auditLog else { return }
        let meta = audit.metaJSON
        let planId = audit.planId
        let actor = audit.actorLocal
        Task {
            do {
                try await auditLog.record(action: AuditLogWriter.Action.voiceConfirm,
                                          entityType: "voice_plan",
                                          entityId: planId.uuidString,
                                          actorLocal: actor, meta: meta)
            } catch {
                // 审计失败不阻断确认/保存；动作自身的 voice.execute 仍按同事务写。
            }
        }
    }

    private func finishDirectSave(ok: Bool, text: String) {
        isSaving = false
        append(.init(role: .receipt, text: ok ? text : L10n.assistantSaveFailed,
                     isRefusal: !ok))
    }

    private func slotLabel(_ spec: VoiceSlotSpec) -> String {
        L10n.voiceSlotLabel(spec.displayLabelKey)
    }

    private func append(_ message: ChatMessage) {
        messages.append(message)
        persist(message)
    }

}

/// 聊天内单卡确认（2026-10-19）：只承载 `EntityCardConfirmView`；
/// 保存/稍后处理导致卡出队或会话收尾时关闭，回到聊天看勾选态。
private struct ChatCardReviewSheet: View {
    let cardID: UUID
    let sessionID: UUID
    @Environment(DocumentsState.self) private var docs
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WithPerceptionTracking {
            Group {
                if let session = docs.activeImport, session.id == sessionID,
                   let source = session.source,
                   let card = session.cards.first(where: { $0.id == cardID }) {
                    NavigationStack {
                        EntityCardConfirmView(
                            card: Binding(
                                get: { docs.activeImport?.cards.first(where: { $0.id == cardID }) ?? card },
                                set: { _ = docs.updateEntityCard($0) }),
                            mode: .queue(session),
                            patientId: source.patientId,
                            documentId: source.documentId,
                            pageCount: source.pages.count,
                            position: nil)
                    }
                    .onChangeCompat(of: session.committedCards.contains(cardID)) { _, done in
                        if done { dismiss() }
                    }
                    .onChangeCompat(of: session.outcome != nil) { _, done in
                        if done { dismiss() }
                    }
                } else {
                    NavigationStack {
                        VLUnavailableView(L10n.assistantCardUnavailable, systemImage: "checkmark.circle")
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button(L10n.assistantClose) { dismiss() }
                                }
                            }
                    }
                }
            }
        }
    }
}

/// 悬浮录音状态卡（2026-10-20）：自身观察 VoiceDictationModel，避免电平/部分
/// 转写的高频更新驱动整个聊天页重算。
private struct ChatVoiceStatusCard: View {
    let model: VoiceDictationModel

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    if model.phase == .recording {
                        RecordingWaveform(level: model.audioLevel, isActive: true,
                                          accessibilityID: "assistant.voiceWaveform")
                        Text(model.isPreparing ? L10n.asrPreparing : L10n.assistantVoiceRecording)
                    } else {
                        VLPulsingActivityIcon(symbol: "waveform", isActive: true, font: .caption)
                        Text(L10n.assistantVoiceRecognizing)
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption)
                if model.phase == .recording, !model.partial.isEmpty {
                    Text(model.partial)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.black.opacity(0.10), radius: 10, y: 3)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .accessibilityIdentifier("assistant.voiceOverlay")
        }
    }
}


