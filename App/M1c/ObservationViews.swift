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

    init(store: ObservationStore, allergyStore: AllergyStore) {
        self.store = store
        self.allergyStore = allergyStore
    }

    func load(patientId: UUID) async {
        do {
            let events = try await store.list(patientId: patientId)
            groups = ObservationGroupService.groups(events, member: patientId)
            allergies = try await allergyStore.list(patientId: patientId)
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
                        Text("\(group.occurrences.count) 次记录 · 最近 \(group.selfMark ?? "-")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("SP-16.observation.group")
                }
                Button {
                    showCreate = true
                } label: {
                    Label("记录观察", systemImage: "plus")
                }
                .accessibilityIdentifier("SP-16.observation.add")
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
                    .accessibilityIdentifier("SP-29.allergy.row")
                }
            }
        }
        .navigationTitle("观察")
        .task { await state.load(patientId: currentPatientId) }
        .sheet(isPresented: $showCreate) {
            ObservationCreateSheet { kind, desc, mark in
                Task { await state.create(patientId: currentPatientId, kind: kind,
                                          description: desc, selfMark: mark) }
                showCreate = false
            }
        }
    }

    private var currentPatientId: UUID { app.owner?.selfPatientId ?? app.owner?.id ?? UUID() }
}

struct ObservationCreateSheet: View {
    let onCreate: (String, String, String?) -> Void
    @State private var kind = "skin"
    @State private var description = ""
    @State private var selfMark = "unchanged"

    private let kinds = ["skin", "stool", "urine", "swelling", "secretion", "eye", "generic"]

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $kind) {
                    ForEach(kinds, id: \.self) { Text($0) }
                }
                TextField("描述", text: $description, axis: .vertical)
                    .lineLimit(2...5)
                Picker("自评", selection: $selfMark) {
                    Text("好转").tag("improved")
                    Text("无变化").tag("unchanged")
                    Text("加重").tag("worsened")
                }
            }
            .navigationTitle("记录观察")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onCreate(kind, description, selfMark) }
                        .disabled(description.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("SP-16.observation.save")
                }
            }
        }
    }
}

/// 敏感媒体保护链（BR-007/008）：默认模糊占位 → 显式解锁（PIN）→ 30 秒自动重锁。
/// 解锁动作走门禁验证；占位层不渲染任何可识别内容。
struct LockedMediaView: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var revealed = false
    @State private var showPinSheet = false
    @State private var unlockDeadline: Date?
    @State private var verifiedAt: Date?       // 本视图的验证时点（评审修正：
                                               // 不监听全局 lastVerifiedAt——任意门禁
                                               // 验证不得解锁本视图的敏感内容，BR-007）

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color("bg-grouped", bundle: .main))
                .overlay(
                    VStack(spacing: 12) {
                        VLIcon.lock.resizable().frame(width: 36, height: 36)
                        Text(revealed ? "已解锁（30 秒后自动重锁）" : "敏感内容已锁定")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    })
            if revealed {
                Text("解锁后的内容区域（原图渲染占位）")
                    .font(.caption)
                    .padding(8)
                    .background(Color("bg-grouped", bundle: .main))
            }
        }
        .frame(height: 220)
        .accessibilityIdentifier("SP-08.lockedMedia")
        .onTapGesture {
            guard !revealed else { return }
            showPinSheet = true          // BR-007：解锁是显式动作，经门禁验证
        }
        .sheet(isPresented: $showPinSheet) {
            PinEntryView(mode: .verify)
                .presentationDetents([.height(420)])
        }
        .onChange(of: app.lastVerifiedAt) { _, value in
            // 只认「本视图发起验证之后」的时点：验证成功发生在 sheet 内
            // （PinEntryView 更新 lastVerifiedAt），但必须晚于本视图的解锁请求
            guard showPinSheet, let value, verifiedAt == nil || value > (verifiedAt ?? .distantPast) else { return }
            verifiedAt = value
            showPinSheet = false
            revealed = true
            unlockDeadline = Date().addingTimeInterval(30)   // §5.10：30 秒自动重锁
            Task {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    if let d = unlockDeadline, Date() >= d { revealed = false }
                } catch {
                    // 睡眠被取消（视图销毁）——revealed 随视图生命周期回收
                }
            }
        }
        // 评审修正：退后台立即重锁（敏感内容不跨生命周期存活）
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && revealed {
                revealed = false
                showPinSheet = false
            }
        }
    }
}
