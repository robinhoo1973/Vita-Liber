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
    init(store: VoiceNoteStore) { self.store = store }

    func load(patientId: UUID) async {
        do { notes = try await store.list(patientId: patientId) }
        catch { logger.error("速记加载失败: \(error)") }
    }

    func create(patientId: UUID, body: String, tags: [String]?) async {
        do {
            try await store.create(patientId: patientId, body: body, tags: tags)
            await load(patientId: patientId)
        } catch {
            logger.error("速记创建失败: \(error)")
        }
    }
}

struct VoiceNotePanelView: View {
    @Environment(AppState.self) private var app
    @Environment(VoiceNoteState.self) private var state
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            List(state.notes) { note in
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.body).font(.body)
                    if !note.tags.isEmpty {
                        Text(note.tags.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("SP-59.voicenote.row")
            }
            HStack(spacing: 8) {
                TextField("记一条速记…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("SP-59.voicenote.input")
                Button {
                    let body = draft.trimmingCharacters(in: .whitespaces)
                    draft = ""
                    guard !body.isEmpty else { return }
                    Task { await state.create(patientId: currentPatientId, body: body, tags: nil) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2).frame(width: 44, height: 44)
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("保存速记")
                .accessibilityIdentifier("SP-59.voicenote.save")
            }
            .padding(12)
        }
        .navigationTitle("语音速记")
        .task { await state.load(patientId: currentPatientId) }
    }

    private var currentPatientId: UUID { app.owner?.selfPatientId ?? app.owner?.id ?? UUID() }
}
