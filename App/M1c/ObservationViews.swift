import SwiftUI
import os
import Domain
import Infrastructure

/// F8 观察模块（M1c 切片）：观察创建 + 列表 + 敏感保护链（BR-007/008）。
@MainActor
@Observable
final class ObservationStoreState {
    private(set) var groups: [ObservationGroup] = []
    private(set) var allergies: [AllergyStore.AllergyRow] = []
    private let store: ObservationStore
    private let allergyStore: AllergyStore
    private let logger = Logger(subsystem: "com.vitaliber", category: "observations")

    /// 最近一次请求的成员（BR-001 成员隔离：只允许最新请求写回状态）
    private var loadingPatientId: UUID?

    init(store: ObservationStore, allergyStore: AllergyStore) {
        self.store = store
        self.allergyStore = allergyStore
    }

    func load(patientId: UUID) async {
        loadingPatientId = patientId
        do {
            let events = try await store.list(patientId: patientId)
            let loadedAllergies = try await allergyStore.list(patientId: patientId)
            // 成员切换后晚到的旧结果必须丢弃，不得覆盖当前成员（BR-001）
            guard loadingPatientId == patientId else { return }
            groups = ObservationGroupService.groups(events, member: patientId)
            allergies = loadedAllergies
        } catch {
            logger.error("观察加载失败: \(error)")
        }
    }

    func create(patientId: UUID, kind: String, description: String, selfMark: String?) async {
        do {
            try await store.create(patientId: patientId, kind: kind,
                                   description: description, selfMark: selfMark)
            await load(patientId: patientId)
        } catch {
            logger.error("观察创建失败: \(error)")
        }
    }
}

struct ObservationListView: View {
    @Environment(AppState.self) private var app
    @Environment(ObservationStoreState.self) private var state
    @State private var showCreate = false

    var body: some View {
        List {
            Section("观察记录") {
                ForEach(state.groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.kind).font(.subheadline)
                        Text(L10n.observationGroupSummary(group.occurrences.count, group.selfMark ?? "-"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("SP-14.observation.group")
                }
                Button {
                    showCreate = true
                } label: {
                    Label("记录观察", systemImage: "plus")
                }
                .accessibilityIdentifier("SP-14.observation.add")
            }
            Section("过敏与不良反应（一等事件）") {
                ForEach(state.allergies, id: \.id) { a in
                    HStack {
                        Text(a.substance).font(.body)
                        Spacer()
                        Text(a.severity).font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(Color("semantic-warning", bundle: .main).opacity(0.15)))
                    }
                    .accessibilityIdentifier("SP-50.allergy.row")
                }
            }
        }
        .navigationTitle("观察")
        .task(id: currentPatientId) { await state.load(patientId: currentPatientId) }
        .sheet(isPresented: $showCreate) {
            ObservationCreateSheet { kind, desc, mark in
                Task { await state.create(patientId: currentPatientId, kind: kind,
                                          description: desc, selfMark: mark) }
                showCreate = false
            }
        }
    }

    private var currentPatientId: UUID { app.currentPatientId }
}

struct ObservationCreateSheet: View {
    @Environment(AppState.self) private var app
    let onCreate: (String, String, String?) -> Void
    @State private var kind = "skin"
    @State private var description = ""
    @State private var selfMark = "unchanged"
    @State private var confirmSet: OcrConfirmationSet?
    @State private var routeMonitor = AudioRouteMonitor()

    private let kinds = ["skin", "stool", "urine", "swelling", "secretion", "eye", "generic"]

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $kind) {
                    ForEach(kinds, id: \.self) { Text($0) }
                }
                TextField("描述", text: $description, axis: .vertical)
                    .lineLimit(2...5)
                // FR8.9 观察语音速记：转写文本经统一模板确认后才落到描述字段
                Button {
                    let text = description.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return }
                    // FR17.13-entry: 观察速记 —— 走统一模板，不自建确认逻辑
                    confirmSet = VoiceInputTemplate.confirmationSet(drafts: [
                        FieldDraft(key: "description", value: text, confidence: 0.85)
                    ])
                } label: {
                    Label("语音速记确认", image: "ic-mic").frame(minHeight: 44)
                }
                .disabled(description.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("SP-14.observation.voiceConfirm")
                Picker("自评", selection: $selfMark) {
                    Text(L10n.observationTrendImproved).tag("improved")
                    Text(L10n.observationTrendUnchanged).tag("unchanged")
                    Text(L10n.observationTrendWorsened).tag("worsened")
                }
            }
            .navigationTitle("记录观察")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onCreate(kind, description, selfMark) }
                        .disabled(description.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("SP-14.observation.save")
                }
            }
            .sheet(item: $confirmSet) { set in
                VoiceConfirmSheet(
                    set: set,
                    decision: ReadbackPolicy.decide(route: routeMonitor.route,
                                                    preference: app.readbackPreference,
                                                    careMode: app.careMode),
                    onSpeak: { app.speak($0) },
                    onConfirm: { confirmed in
                        description = confirmed.confirmedFields.first?.value ?? description
                        confirmSet = nil
                    },
                    onRetry: { confirmSet = nil },
                    onCancel: { confirmSet = nil })
                .presentationDetents([.medium])
            }
            .onAppear { routeMonitor.start() }
            .onDisappear { routeMonitor.stop() }
        }
    }
}

/// 敏感媒体保护链（BR-007/008）：默认模糊占位 → 显式解锁（PIN）→ 无操作自动重锁。
/// 状态机与策略全在共享的 `SensitiveMediaContainer` + Domain `MediaUnlockPolicy`——
/// 本视图只提供占位层与解锁后的内容，不再自带一份重锁逻辑。
struct LockedMediaView: View {
    var body: some View {
        SensitiveMediaContainer { revealed in
            Rectangle()
                .fill(Color("bg-grouped", bundle: .main))
                .overlay(
                    VStack(spacing: 12) {
                        VLIcon.lock.resizable().frame(width: 36, height: 36)
                        Text(revealed ? L10n.observationUnlockedHint : L10n.observationLockedHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    })
        } content: { _ in
            Text(L10n.observationUnlockedPlaceholder)
                .font(.caption)
                .padding(8)
                .background(Color("bg-grouped", bundle: .main))
        }
        .frame(height: 220)
        .accessibilityIdentifier("SP-14.lockedMedia")
    }
}
