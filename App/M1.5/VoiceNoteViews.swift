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
    @State private var routeMonitor = AudioRouteMonitor()

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
                    // FR17.13-entry: 语音速记 —— 走统一模板，不自建确认逻辑
                    confirmSet = VoiceInputTemplate.confirmationSet(drafts: [
                        FieldDraft(key: "body", value: body, confidence: 0.9)
                    ])
                } label: {
                    VLIcon.send.resizable().frame(width: 22, height: 22)
                        .frame(width: 44, height: 44)
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("保存速记")
                .accessibilityIdentifier("SP-59.voicenote.save")
            }
            .padding(12)
        }
        .navigationTitle("语音速记")
        .task { await state.load(patientId: currentPatientId) }
        // 唯一确认 UI：VoiceConfirmSheet（FR17.13）。本页不再自建确认界面。
        .sheet(item: $confirmSet) { set in
            VoiceConfirmSheet(
                set: set,
                decision: ReadbackPolicy.decide(route: routeMonitor.route,
                                                preference: app.readbackPreference,
                                                careMode: app.careMode),
                onSpeak: { app.speak($0) },
                onConfirm: { confirmed in
                    let body = confirmed.confirmedFields.first?.value ?? ""
                    draft = ""
                    confirmSet = nil
                    guard !body.isEmpty else { return }
                    Task { await state.create(patientId: currentPatientId, body: body, tags: nil) }
                },
                onRetry: { confirmSet = nil },
                onCancel: { confirmSet = nil })
            .presentationDetents([.medium])
        }
        .onAppear { routeMonitor.start() }
        .onDisappear { routeMonitor.stop() }
    }

    private var currentPatientId: UUID { app.currentPatientId }
}
