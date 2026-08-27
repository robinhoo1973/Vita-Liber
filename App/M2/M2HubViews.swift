import SwiftUI
import UniformTypeIdentifiers
import Domain
import Infrastructure

/// M2 各页的**挂载壳**：从 M2HubStore 加载数据 → 透传给纯渲染视图。
/// 纯渲染视图（InventoryListView/EmergencyCardView/…）保持无装配依赖，
/// 壳承担 patientId 解析、加载与回调接线（tech-spec §1.1：装配根不散落视图）。

// MARK: - 药箱（F9.8 全家桶 + FR13.8 配药清单 + FR9.13a 求助卡）

struct InventoryHubView: View {
    @Environment(AppState.self) private var app
    @Environment(M2HubStore.self) private var hub

    @State private var reconcileItem: MedicationStore.InventorySummaryItem?
    @State private var showHelpCard = false
    @State private var showDispenseExport = false
    @State private var shareText = ""
    @State private var showShareHost = false

    var body: some View {
        InventoryListView(
            items: hub.inventoryItems,
            onReconcile: { reconcileItem = $0 },
            onExportDispenseList: { showDispenseExport = true })
        .navigationTitle(L10n.inventory_title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showHelpCard = true
                } label: {
                    Label("求助卡", image: "ic-share").frame(minHeight: 44)
                }
                .accessibilityIdentifier("FR9.13a.card.open")
            }
        }
        .task { await hub.load(patientId: currentPatientId) }
        .sheet(item: $reconcileItem) { item in
            InventoryReconcileSheet(item: item) { count in
                Task { await hub.reconcileLot(item: item, physicalCount: count) }
            }
        }
        .sheet(isPresented: $showHelpCard) {
            MedicationHelpCardSheet(items: hub.inventoryItems) { inputs in
                shareText = MedicationHelpCardRules.cardText(inputs)
                showShareHost = true
            }
        }
        .fileExporter(isPresented: $showDispenseExport,
                      document: CSVTextDocument(text: hub.dispenseCSV()),
                      contentType: .commaSeparatedText,
                      defaultFilename: "配药清单") { _ in }
        .sheet(isPresented: $showShareHost) {
            HelpCardShareHost(text: shareText, photoAttachments: []) {
                // 分享完成 → 落发送状态（FR24.2）
                Task { await hub.recordSent(patientId: currentPatientId,
                                            kind: "helpCard", recipient: "家人") }
            }
        }
    }

    private var currentPatientId: UUID { app.currentPatientId }
}

/// CSV 文本导出文档（配药清单，FR13.8）
struct CSVTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - 急救卡（F15）

struct EmergencyCardHubView: View {
    @Environment(AppState.self) private var app
    @Environment(M2HubStore.self) private var hub
    @State private var showSelector = false

    var body: some View {
        EmergencyCardView(
            card: hub.emergencySelected,
            bloodType: hub.bloodType,
            onGuideMedicalID: { UIApplication.shared.open(URL(string: "x-apple-health://") ?? URL(string: "https://support.apple.com/medical-id")!) },
            onOpenSelector: { showSelector = true })
        .task { await hub.load(patientId: currentPatientId) }
        .sheet(isPresented: $showSelector) {
            NavigationStack {
                EmergencyCardSelectorView(
                    candidates: hub.emergencyCandidates,
                    selectedIds: hub.emergencySelectedIds) { item, selected in
                        Task { await hub.toggleEmergency(item: item, selected: selected,
                                                         patientId: currentPatientId) }
                    }
            }
        }
    }

    private var currentPatientId: UUID { app.currentPatientId }
}

// MARK: - 疫苗（FR4.5）

struct ImmunizationHubView: View {
    @Environment(AppState.self) private var app
    @Environment(M2HubStore.self) private var hub

    var body: some View {
        ImmunizationListView(records: hub.immunizationRecords,
                             patientId: currentPatientId) { name, dose, date, provider, lot in
            Task { await hub.createImmunization(patientId: currentPatientId, name: name,
                                                dose: dose, date: date,
                                                provider: provider, lot: lot) }
        }
        .task { await hub.load(patientId: currentPatientId) }
    }

    private var currentPatientId: UUID { app.currentPatientId }
}

// MARK: - 报销（FR13.7）

struct ClaimHubView: View {
    @Environment(AppState.self) private var app
    @Environment(M2HubStore.self) private var hub

    var body: some View {
        ClaimListView(rows: hub.claimRows, totals: hub.claimTotals) { type, amount, date, merchant, summary in
            Task { await hub.createClaim(patientId: currentPatientId, type: type,
                                         amount: amount, date: date,
                                         merchant: merchant, summary: summary) }
        }
        .task { await hub.load(patientId: currentPatientId) }
    }

    private var currentPatientId: UUID { app.currentPatientId }
}

// MARK: - 发送状态（FR24.2）

struct SentStatusHubView: View {
    @Environment(AppState.self) private var app
    @Environment(M2HubStore.self) private var hub

    var body: some View {
        SentStatusListView(messages: hub.sentMessages)
            .task { await hub.load(patientId: currentPatientId) }
    }

    private var currentPatientId: UUID { app.currentPatientId }
}

/// FR24.2 发送状态页：只展示类型/收件人/状态/时间，**不存不显原文**（最小必要）。
struct SentStatusListView: View {
    let messages: [SentMessage]

    var body: some View {
        List {
            if messages.isEmpty {
                ContentUnavailableView(L10n.fr24_empty, systemImage: "paperplane",
                                       description: Text(L10n.fr24_emptyHint))
                    .accessibilityIdentifier("FR24.2.empty")
            } else {
                ForEach(messages) { message in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kindLabel(message.kind)).font(.subheadline)
                            Text("\(L10n.fr24_recipient) \(message.recipient)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(message.sentAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        StatusBadge(status: message.status)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("FR24.2.row")
                }
            }
        }
        .navigationTitle(L10n.fr24_title)
    }

    private func kindLabel(_ kind: String) -> String {
        kind == "helpCard" ? L10n.fr24_kindHelpCard : L10n.fr24_kindSos
    }
}

struct StatusBadge: View {
    let status: MessageStatus

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .sent: return L10n.fr24_statusSent
        case .ackPending: return L10n.fr24_statusAckPending
        case .acked: return L10n.fr24_statusAcked
        case .timeout: return L10n.fr24_statusTimeout
        }
    }
    private var color: Color {
        switch status {
        case .sent: return Color("brand-primary", bundle: .main)
        case .ackPending: return Color("grade-d", bundle: .main)
        case .acked: return .green
        case .timeout: return Color("text-tertiary", bundle: .main)
        }
    }
}

// MARK: - 信源库（F16 准入展示）

struct GuidelineHubView: View {
    @Environment(AppState.self) private var app
    @Environment(M2HubStore.self) private var hub

    var body: some View {
        GuidelineSourceListView(entries: hub.guidelineEntries)
            .task { await hub.load(patientId: currentPatientId) }
    }

    private var currentPatientId: UUID { app.currentPatientId }
}
