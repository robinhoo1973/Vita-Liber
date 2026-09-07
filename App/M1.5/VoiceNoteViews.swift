import SwiftUI
import os
import Domain
import Infrastructure

/// FR17.14 语音速记面板（SP-59）：文本输入速记 + 标签 + 入轴开关。
/// M1.5 文法子集阶段的速记 = 手输文本（语音转写随基线轨装配后接入，
/// 转写文本同样走 VoiceInputTemplate 统一确认——FR17.13 模板复用）。
@MainActor
@Observable
final class VoiceNoteState {
    private(set) var notes: [VoiceNoteStore.VoiceNoteRow] = []
    private let store: VoiceNoteStore
    private let logger = Logger(subsystem: "com.vitaliber", category: "voicenote")
    /// 最近一次请求的成员（BR-001 成员隔离：只允许最新请求写回状态）
    private var loadingPatientId: UUID?
    init(store: VoiceNoteStore) { self.store = store }

    func load(patientId: UUID) async {
        loadingPatientId = patientId
        do {
            let loaded = try await store.list(patientId: patientId)
            // 成员切换后晚到的旧结果必须丢弃，不得覆盖当前成员（BR-001）
            guard loadingPatientId == patientId else { return }
            notes = loaded
        }
        catch { logger.error("速记加载失败: \(error)") }
    }

    /// 写操作统一出口（审查修复）：此前 create/update/delete 三段复制粘贴
    /// 且错误被吞、返回 Void——调用方无条件弹「已保存」。现在写失败
    /// 返回 false 由调用侧可见呈现；写后重载列表策略只维护一处。
    private func perform(patientId: UUID, _ op: () async throws -> Void) async -> Bool {
        do {
            try await op()
            await refreshIfCurrent(patientId: patientId)
            return true
        } catch {
            logger.error("速记写操作失败: \(error)")
            return false
        }
    }

    /// 写后刷新（不重盖 loadingPatientId 标记）：写路径若经 load() 刷新，
    /// 慢写（A）完成后会把标记改回 A——B 成员已在途的加载结果被守卫误弃、
    /// 旧成员笔记挂到新成员名下（BR-001 残留）。只在本请求仍是最新时应用。
    private func refreshIfCurrent(patientId: UUID) async {
        guard loadingPatientId == patientId else { return }
        do {
            let loaded = try await store.list(patientId: patientId)
            guard loadingPatientId == patientId else { return }
            notes = loaded
        } catch {
            logger.error("速记刷新失败: \(error)")
        }
    }

    @discardableResult
    func create(patientId: UUID, body: String, tags: [String]?) async -> Bool {
        await perform(patientId: patientId) {
            try await store.create(patientId: patientId, body: body, tags: tags)
        }
    }

    @discardableResult
    func update(id: UUID, patientId: UUID, body: String, tags: [String]?, inTimeline: Bool) async -> Bool {
        await perform(patientId: patientId) {
            try await store.update(id: id, patientId: patientId, body: body,
                                   tags: tags, inTimeline: inTimeline)
        }
    }

    @discardableResult
    func delete(id: UUID, patientId: UUID) async -> Bool {
        await perform(patientId: patientId) {
            try await store.delete(id: id, patientId: patientId)
        }
    }
}

struct VoiceNotePanelView: View {
    @Environment(AppState.self) private var app
    @Environment(VoiceNoteState.self) private var state
    @State private var draft = ""
    @State private var confirmSet: OcrConfirmationSet?
    @State private var routeMonitor = AudioRouteMonitor()
    /// §5.61 详情/编辑（V3.72）：行点击进入编辑（正文/标签/入轴/删除）
    @State private var editingNote: VoiceNoteStore.VoiceNoteRow?
    /// 写失败可见反馈（审查修复：此前 store 错误被吞、无任何 UI 反馈——
    /// 用户以为速记已保存/已更新/已删除，刷新后发现记录依旧）
    @State private var writeFailed = false

    var body: some View {
        VStack(spacing: 0) {
            if state.notes.isEmpty {
                ContentUnavailableView(L10n.voicenoteEmptyTitle, systemImage: "waveform",
                                       description: Text(L10n.voicenoteEmptyHint))
                    .accessibilityIdentifier("SP-59.voicenote.empty")
            } else {
                List(state.notes) { note in
                    Button {
                        editingNote = note
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(note.body).font(.body)
                            Spacer()
                            if note.inTimeline {
                                Text(L10n.voicenoteInTimeline).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text(note.occurredAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                        if !note.tags.isEmpty {
                            Text(note.tags.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("SP-59.voicenote.row")
                    }
                    .buttonStyle(.plain)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField(L10n.voicenoteDraftPlaceholder, text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .accessibilityLabel(L10n.voicenoteDraftAccessibility)
                        .accessibilityIdentifier("SP-59.voicenote.input")
                    Button {
                        let body = draft.trimmingCharacters(in: .whitespaces)
                        guard !body.isEmpty else { return }
                        // FR17.13-entry: 语音速记 —— 走统一模板，不自建确认逻辑
                        confirmSet = VoiceInputTemplate.confirmationSet(drafts: [
                            FieldDraft(key: "body", value: body, confidence: 0.9)
                        ])
                    } label: {
                        VLIcon.send.resizable().frame(width: 22, height: 22)
                            .frame(width: 44, height: 44)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel(L10n.voicenoteSaveAccessibility)
                    .accessibilityIdentifier("SP-59.voicenote.save")
                }
                // FR17.14 语音速记（纯转写层，评审修正）：此前速记 = 手输文本，
                // 语音转写未接线——接入端上听写，转写文本走同一 FR17.13 确认模板。
                // 确认前不预填 draft（评审修正）：取消/重试不留未确认转写文本。
                VoiceDictationButton { text, confidence in
                    confirmSet = VoiceInputTemplate.confirmationSet(drafts: [
                        FieldDraft(key: "body", value: text, confidence: confidence)
                    ])
                }
                .accessibilityIdentifier("SP-59.voicenote.dictation")
            }
            .padding(12)
        }
        .navigationTitle(L10n.voicenoteTitle)
        .task(id: currentPatientId) { await state.load(patientId: currentPatientId) }
        .alert(L10n.voicenoteSaveFailed, isPresented: $writeFailed) {
            Button(L10n.onboard_gotIt, role: .cancel) { }
        }
        // 唯一确认 UI：VoiceConfirmSheet（FR17.13）。本页不再自建确认界面。
        .voiceConfirmSheet($confirmSet, route: routeMonitor.route) { confirmed in
            let body = confirmed.confirmedFields.first?.value ?? ""
            draft = ""
            confirmSet = nil
            guard !body.isEmpty else { return }
            Task {
                if !(await state.create(patientId: currentPatientId, body: body, tags: nil)) {
                    writeFailed = true
                }
            }
        }
        .sheet(item: $editingNote) { note in
            VoiceNoteDetailSheet(note: note) { body, tags, inTimeline in
                editingNote = nil
                Task {
                    if !(await state.update(id: note.id, patientId: currentPatientId,
                                            body: body, tags: tags, inTimeline: inTimeline)) {
                        writeFailed = true
                    }
                }
            } onDelete: {
                editingNote = nil
                Task {
                    if !(await state.delete(id: note.id, patientId: currentPatientId)) {
                        writeFailed = true
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .onAppear { routeMonitor.start() }
        .onDisappear { routeMonitor.stop() }
    }

    private var currentPatientId: UUID { app.currentPatientId }
}

/// §5.61 语音速记详情/编辑（V3.72）：正文可编辑、标签输入、入时间轴开关、
/// 删除前明示「仅删除该条备忘，不影响医疗数据」（FR6.4 修订语义从简）
struct VoiceNoteDetailSheet: View {
    let note: VoiceNoteStore.VoiceNoteRow
    let onSave: (String, [String]?, Bool) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var draftBody = ""
    @State private var tagsText = ""
    @State private var inTimeline = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.voicenoteDetailBody) {
                    TextField(L10n.voicenoteDraftPlaceholder, text: $draftBody, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section(L10n.voicenoteDetailTags) {
                    TextField(L10n.voicenoteDetailTagsHint, text: $tagsText)
                }
                Section {
                    Toggle(L10n.voicenoteDetailTimeline, isOn: $inTimeline)
                } footer: {
                    Text(L10n.voicenoteDetailTimelineHint)
                }
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text(L10n.voicenoteDetailDelete)
                    }
                }
            }
            .navigationTitle(L10n.voicenoteTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.reminder_save) {
                        let tags = tagsText.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
                        onSave(draftBody, tags.isEmpty ? nil : tags, inTimeline)
                        dismiss()
                    }
                    .disabled(draftBody.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert(L10n.voicenoteDetailDeleteConfirm, isPresented: $confirmDelete) {
                Button(L10n.voicenoteDetailDelete, role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Button(L10n.onboard_cancel, role: .cancel) {}
            }
            .onAppear {
                draftBody = note.body
                tagsText = note.tags.joined(separator: ", ")
                inTimeline = note.inTimeline
            }
        }
    }
}
