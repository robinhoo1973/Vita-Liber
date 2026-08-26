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
    @State private var confirmSet: OcrConfirmationSet?

    var body: some View {
        VStack(spacing: 0) {
            if state.notes.isEmpty {
                ContentUnavailableView("还没有语音速记", systemImage: "waveform",
                                       description: Text("记录的第一条速记会出现在这里（默认不进时间轴）"))
                    .accessibilityIdentifier("SP-59.voicenote.empty")
            } else {
                List(state.notes) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(note.body).font(.body)
                            Spacer()
                            if note.inTimeline {
                                Text("已入轴").font(.caption2).foregroundStyle(.secondary)
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
            }
            HStack(spacing: 8) {
                TextField("记一条速记…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .accessibilityLabel("速记内容")
                    .accessibilityIdentifier("SP-59.voicenote.input")
                Button {
                    let body = draft.trimmingCharacters(in: .whitespaces)
                    guard !body.isEmpty else { return }
                    // FR17.13：统一确认模板——速记同样走确认集（待确认态）
                    confirmSet = VoiceInputTemplate.confirmationSet(drafts: [
                        FieldDraft(key: "body", value: body, confidence: 0.9)
                    ])
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
        .sheet(item: $confirmSet) { set in
            VStack(spacing: 16) {
                Text("确认速记内容").font(.headline)
                ForEach(set.fields) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.value).font(.body)
                        Text("待确认 · 确认后保存").font(.caption).foregroundStyle(Color("grade-d", bundle: .main))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color("bg-grouped", bundle: .main)))
                }
                HStack(spacing: 12) {
                    Button("取消") { confirmSet = nil }
                    Button("确认保存") {
                        let body = set.fields.first?.value ?? ""
                        draft = ""
                        confirmSet = nil
                        Task { await state.create(patientId: currentPatientId, body: body, tags: nil) }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("SP-59.voicenote.confirm")
                }
            }
            .padding(24)
            .presentationDetents([.height(300)])
        }
    }

    private var currentPatientId: UUID { app.owner?.selfPatientId ?? app.owner?.id ?? UUID() }
}
