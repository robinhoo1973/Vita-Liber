import SwiftUI
import UIKit
import PhotosUI
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
struct TaskAssistantChatView: View {
    @Environment(AppState.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(VoiceNoteState.self) private var voiceNotes
    @Environment(QuestionsState.self) private var questions
    @Environment(DocumentsState.self) private var docs
    @Environment(ChatHistoryState.self) private var chatHistory
    @Environment(AppSettingsStore.self) private var settingsStore
    @Environment(M2HubStore.self) private var hub
    @Environment(\.auditLog) private var auditLog
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [ChatMessage] = []
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
    @State private var attachmentPanel = false
    @FocusState private var inputFocused: Bool
    @State private var routeMonitor = AudioRouteMonitor()

    // 2026-10-19 聊天内采集（业主指令）：媒体 → 全图 OCR → 助理侧信息卡。
    @State private var chatSessionID: UUID?
    @State private var importing = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var pickedPhoto: PhotosPickerItem?

    // 语音消息重放（2026-10-19；2026-10-20 转写文本常显）：本机音频文件。
    // 播放器已上提 AppState.voicePlayback（2026-10-21），页面只读 playingID。
    /// 已写入历史的视图消息 ID（媒体在 OCR 终态才落库，避免 processing 快照）。
    @State private var persistedMessageIDs: Set<UUID> = []
    /// 历史写入串行链：append 必须先于同消息的 update（2026-10-20）。
    @State private var persistenceTail: Task<Void, Never>?
    @State private var conversationID: UUID?
    /// 会话代次：切换会话后，晚到的持久化任务不得写进新会话（2026-10-20）。
    @State private var conversationGeneration = UUID()
    @State private var titleCaptured = false
    @State private var showHistory = false

    private enum AssistantSheet: Identifiable {
        case history
        case document(documentId: UUID, patientId: UUID)
        case sharedReview(sessionID: UUID)
        case cardReview(cardID: UUID, sessionID: UUID)

        var id: String {
            switch self {
            case .history: return "history"
            case .document(let doc, _): return "document-\(doc.uuidString)"
            case .sharedReview(let id): return "shared-\(id.uuidString)"
            case .cardReview(let cardID, _): return "card-\(cardID.uuidString)"
            }
        }
    }

    private struct MediaInfo: Equatable {
        enum Kind: Equatable { case image, pdf, file, voice }
        enum Status: Equatable { case processing, ready, failed }
        var kind: Kind
        var filename: String
        var status: Status
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
                .photosPicker(isPresented: $showPhotoPicker, selection: $pickedPhoto, matching: .images)
                .onChangeCompat(of: pickedPhoto) { _, item in handlePickedPhoto(item) }
                .fullScreenCover(isPresented: $showCamera) {
                    CameraPicker { image in handleCameraImage(image) }
                }
                .fileImporter(isPresented: $showFileImporter,
                              allowedContentTypes: [.pdf, .image],
                              allowsMultipleSelection: false,
                              onCompletion: handleImportedFile)
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
                    if closed { syncCardSnapshots() }
                }
                .onDisappear {
                    routeMonitor.stop()
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
    /// 2026-10-20：OCR 落库后整块可点开原件——当前会话与历史恢复同一路径）。
    @ViewBuilder
    private func mediaBubble(_ media: MediaInfo, messageID: UUID) -> some View {
        if media.kind == .voice {
            voiceBubble(media, messageID: messageID)
        } else if let documentId = media.documentId, let patientId = media.patientId {
            Button {
                activeSheet = .document(documentId: documentId, patientId: patientId)
            } label: {
                mediaContent(media)
            }
            .buttonStyle(.plain)
            .accessibilityHint(L10n.assistantMediaOpen)
            .accessibilityIdentifier("assistant.media.open")
        } else {
            mediaContent(media)
        }
    }

    private func mediaContent(_ media: MediaInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: media.kind == .image ? "photo.fill"
                  : media.kind == .pdf ? "doc.fill" : "doc.text.fill")
                .font(.title3)
                .foregroundStyle(Color("brand-primary", bundle: .main))
            VStack(alignment: .leading, spacing: 2) {
                Text(media.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(mediaStatusText(media.status))
                    .font(.caption2)
                    .foregroundStyle(media.status == .failed
                        ? Color("semantic-danger", bundle: .main) : Color.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 220, alignment: .leading)
        .background(Color("brand-primary", bundle: .main).opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("assistant.media")
    }

    /// 语音消息（2026-10-19；2026-10-20 业主指令）：本机音频可重放；
    /// 转写文本不再需要手动触发——识别在后台完成，直接展开显示在语音下方。
    private func voiceBubble(_ media: MediaInfo, messageID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    playVoice(media, messageID: messageID)
                } label: {
                    Image(systemName: app.voicePlayback.playingID == messageID ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(media.audioFilename == nil)
                .accessibilityLabel(L10n.assistantVoiceReplay)
                .accessibilityIdentifier("assistant.voice.replay")

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.assistantVoiceMessage)
                        .font(.subheadline)
                    Text(mediaStatusText(media.status))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            if let transcript = media.transcript,
               !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(transcript)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            app.voicePlayback.stop()
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
    private func cardKindStyle(_ card: CardInfo) -> (symbol: String, color: Color) {
        if card.kind == .shared {
            return ("info.circle.fill", Color("card-kind-shared", bundle: .main))
        }
        switch card.entityKind ?? "" {
        case "prescription":
            return ("doc.text.fill", Color("card-kind-rx", bundle: .main))
        case "medication":
            return ("pills.fill", Color("card-kind-med", bundle: .main))
        case "metric_sample", "lab_report", "lab":
            return ("testtube.2", Color("card-kind-lab", bundle: .main))
        case "claim_item":
            return ("creditcard.fill", Color("card-kind-rx", bundle: .main))
        case "diagnosis":
            return ("list.clipboard.fill", Color("card-kind-rx", bundle: .main))
        case "immunization":
            return ("syringe.fill", Color("card-kind-med", bundle: .main))
        case "exam_report":
            return ("waveform.path.ecg", Color("card-kind-lab", bundle: .main))
        case "surgery":
            return ("bandage.fill", Color("card-kind-med", bundle: .main))
        case "treatment_record":
            return ("cross.case.fill", Color("card-kind-med", bundle: .main))
        case "health_exam":
            return ("checklist", Color("card-kind-shared", bundle: .main))
        case "clinical_conclusion":
            return ("text.badge.checkmark", Color("card-kind-lab", bundle: .main))
        case "hospitalization":
            return ("bed.double.fill", Color("card-kind-rx", bundle: .main))
        default:
            return ("doc.text.fill", Color("card-kind-shared", bundle: .main))
        }
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
            audioFilename: filename, transcript: trimmed, incomplete: incomplete)))
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

    /// 2026-10-19 业主指令：选项竖排（一行一项），不做横向图标排。
    private var attachmentPanelView: some View {
        VStack(spacing: 8) {
            attachmentOption(L10n.assistantAttachPhotos, systemImage: "photo.on.rectangle",
                             identifier: "assistant.attach.photos") {
                startCapture(.photos)
            }
            if QuickCaptureView.cameraAvailable {
                attachmentOption(L10n.assistantAttachCamera, systemImage: "camera.fill",
                                 identifier: "assistant.attach.camera") {
                    startCapture(.camera)
                }
            }
            attachmentOption(L10n.assistantAttachPDF, systemImage: "doc.fill",
                             identifier: "assistant.attach.pdf") {
                startCapture(.file)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func attachmentOption(_ title: String, systemImage: String,
                                  identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 24)
                Text(title)
                    .font(.body)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.secondary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        case .document(let documentId, let patientId):
            DocumentSourcePageView(documentId: documentId, patientId: patientId, pageIndex: 0)
        case .history:
            ChatHistoryView(
                patientId: app.currentPatientId,
                onOpen: { summary in openConversation(summary) },
                onNew: { startNewConversation() },
                onClose: { activeSheet = nil },
                onDelete: { id in
                    if id == conversationID { startNewConversation() }
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
        if title != nil { titleCaptured = true }
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
        guard let conversationID,
              let message = messages.first(where: { $0.id == messageID }),
              let payload = encode(message) else { return }
        enqueuePersistence {
            await chatHistory.updateMessagePayload(conversationId: conversationID,
                                                   clientId: messageID,
                                                   payloadJSON: payload)
        }
    }

    /// 懒创建会话：首条消息落库前不产生空会话；并发首条消息只保留一个会话。
    private func ensureConversationID() async -> UUID? {
        if let conversationID { return conversationID }
        guard let created = await chatHistory.createConversation(
            patientId: app.currentPatientId, title: L10n.assistantNewConversation) else { return nil }
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
    /// （如「检验报告 · 血红蛋白」「处方 · 阿莫西林」）；无实体卡时用共同信息；
    /// 用户已命名/已捕获则不再覆盖。
    private func autoTitleFromImport(_ session: DocumentsState.ImportSession) {
        guard !titleCaptured else { return }
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
        } else {
            title = nil
        }
        guard let title else { return }
        titleCaptured = true
        let trimmed = String(title.prefix(24))
        Task {
            guard let id = await ensureConversationID() else { return }
            await chatHistory.rename(id, title: trimmed)
        }
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
                           incomplete: $0.incomplete)
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
        Task {
            let stored = await chatHistory.messages(conversationId: summary.id)
            await MainActor.run {
                stopVoicePlayback()
                conversationGeneration = UUID()
                conversationID = summary.id
                titleCaptured = true
                messages = stored.compactMap(decode)
                resetTransient()
                activeSheet = nil
            }
        }
    }

    private func startNewConversation() {
        // 懒创建：清空界面即可；首条消息落库时创建会话，避免空行。
        stopVoicePlayback()
        conversationGeneration = UUID()
        conversationID = nil
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

    private func handlePickedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        pickedPhoto = nil
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else {   // try?-ok: 相册读取失败统一提示
                append(.init(role: .assistant, text: L10n.assistantMediaFailed, isRefusal: true))
                return
            }
            await importImage(data, filename: L10n.assistantAttachPhotos, origin: "photoLibrary")
        }
    }

    private func handleCameraImage(_ image: UIImage) {
        showCamera = false
        guard let data = image.jpegData(compressionQuality: 1) else {
            append(.init(role: .assistant, text: L10n.assistantMediaFailed, isRefusal: true))
            return
        }
        Task { await importImage(data, filename: L10n.assistantAttachCamera, origin: "camera") }
    }

    private func handleImportedFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let kind: MediaInfo.Kind = url.pathExtension.lowercased() == "pdf" ? .pdf : .image
        Task { await importURL(url, filename: url.lastPathComponent, kind: kind) }
    }

    /// 全图识别：originalData == processedData，跳过区域/遮挡选择（业主 2026-10-19）。
    private func importImage(_ data: Data, filename: String, origin: String) async {
        guard let messageID = appendMedia(filename: filename, kind: .image) else { return }
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
            docType: nil, title: nil, isSensitive: true, origin: origin)
        await finishImport(draft, session: session, messageID: messageID)
    }

    private func importURL(_ url: URL, filename: String, kind: MediaInfo.Kind) async {
        guard let messageID = appendMedia(filename: filename, kind: kind) else { return }
        importing = true
        defer { importing = false }
        guard let session = startChatSession() else {
            failMedia(messageID, text: L10n.assistantImportBusy)
            return
        }
        let draft = await docs.importDocument(patientId: session.patientId, url: url,
                                              docType: nil, isSensitive: true)
        await finishImport(draft, session: session, messageID: messageID)
    }

    @discardableResult
    private func appendMedia(filename: String, kind: MediaInfo.Kind) -> UUID? {
        guard docs.activeImport == nil else {
            append(.init(role: .assistant, text: L10n.assistantImportBusy, isRefusal: true))
            return nil
        }
        let message = ChatMessage(role: .user,
                                  media: MediaInfo(kind: kind, filename: filename, status: .processing))
        // 立即落库（processing 快照）：OCR 中被强退/切会话也不丢上传记录；
        // 终态经串行链 update 覆盖（2026-10-20）。
        append(message)
        return message.id
    }

    private func startChatSession() -> DocumentsState.ImportSession? {
        guard docs.activeImport == nil,
              let session = docs.beginImport(patientId: app.currentPatientId) else { return nil }
        session.captureSensitive = true
        chatSessionID = session.id
        return session
    }

    private func finishImport(_ draft: DocumentsState.ImportDraft?,
                              session: DocumentsState.ImportSession,
                              messageID: UUID?) async {
        // 重复资料：聊天内不静默覆盖（ADR-019），保留原件并提示去资料库处理。
        if session.duplicate != nil {
            updateMedia(messageID, status: .failed)
            append(.init(role: .assistant, text: L10n.assistantMediaDuplicate, isRefusal: true))
            _ = await docs.resolveDuplicate(.keep)
            _ = docs.finishImportPresentation(sessionID: session.id)
            chatSessionID = nil
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
        updateMedia(messageID, status: .ready,
                    document: session.source.map { (id: $0.documentId, patient: $0.patientId) })
        appendImportCards(for: session)
    }

    private func appendImportCards(for session: DocumentsState.ImportSession) {
        let rows = docs.sharedFieldRows(for: session)
        if !rows.isEmpty {
            append(ChatMessage(role: .assistant, card: CardInfo(
                id: "shared-\(session.id.uuidString)", kind: .shared,
                entityKind: nil, fieldCount: rows.count, sessionID: session.id)))
        }
        for card in session.cards {
            let count = card.shared.count + card.rows.reduce(0) { $0 + $1.fields.count }
            append(ChatMessage(role: .assistant, card: CardInfo(
                id: card.id.uuidString, kind: .entity,
                entityKind: card.kind, fieldCount: count, sessionID: session.id)))
        }
        if session.cards.isEmpty && rows.isEmpty {
            append(.init(role: .receipt, text: L10n.assistantCaptureSaved))
        }
        // OCR 内容命名放在卡消息之后：会话已创建/已有首条消息，改名命中同一会话。
        autoTitleFromImport(session)
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
        }
        _ = docs.finishImportPresentation(sessionID: session.id)
        chatSessionID = nil
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
                }
            }
            _ = docs.finishImportPresentation(sessionID: sessionID)
            chatSessionID = nil
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


