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
                    Label(L10n.helpcard_title, systemImage: "square.and.arrow.up").frame(minHeight: 44)
                }
                .accessibilityIdentifier("FR9.13a.card.open")
            }
        }
        .task(id: currentPatientId) { await hub.load(patientId: currentPatientId) }
        .sheet(item: $reconcileItem) { item in
            InventoryReconcileSheet(item: item) { count in
                Task { await hub.reconcileLot(item: item, physicalCount: count) }
            }
        }
        .sheet(isPresented: $showHelpCard) {
            MedicationHelpCardSheet(items: hub.inventoryItems) { inputs in
                // 第七轮修复：卡文本标签经 L10n 三语词表注入（Domain 不再
                // 硬编码中文——en 用户分享出的是英文卡）
                shareText = MedicationHelpCardRules.cardText(inputs, labels: .init(
                    title: L10n.helpcard_title,
                    remainingPrefix: L10n.helpcardCardRemainingPrefix,
                    storagePrefix: L10n.helpcardCardStoragePrefix,
                    expiryPrefix: L10n.helpcardCardExpiryPrefix))
                showShareHost = true
            }
        }
        .fileExporter(isPresented: $showDispenseExport,
                      document: CSVTextDocument(text: hub.dispenseCSV()),
                      contentType: .commaSeparatedText,
                      defaultFilename: L10n.helpcard_defaultFilename) { _ in }
        .sheet(isPresented: $showShareHost) {
            // FR24.1 发送前模板预览（V3.72）：所见即所得，确认后再选收件人
            HelpCardSendHost(text: shareText,
                             contacts: hub.emergencySelected.contacts.map(\.title)) { recipient in
                Task {
                    await hub.recordSent(patientId: currentPatientId,
                                         kind: "helpCard", recipient: recipient)
                    hub.auditHelpCardSent(recipient: recipient)
                }
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
            onOpenSelector: { showSelector = true },
            careMode: app.careMode)
        .task(id: currentPatientId) { await hub.load(patientId: currentPatientId) }
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
        .task(id: currentPatientId) { await hub.load(patientId: currentPatientId) }
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
        .task(id: currentPatientId) { await hub.load(patientId: currentPatientId) }
    }

    private var currentPatientId: UUID { app.currentPatientId }
}

// MARK: - 发送状态（FR24.2）

struct SentStatusHubView: View {
    @Environment(AppState.self) private var app
    @Environment(M2HubStore.self) private var hub

    var body: some View {
        SentStatusListView(messages: hub.sentMessages)
            .task(id: currentPatientId) { await hub.load(patientId: currentPatientId) }
    }

    private var currentPatientId: UUID { app.currentPatientId }
}

/// FR24.2 发送状态页：只展示类型/收件人/状态/时间，**不存不显原文**（最小必要）。
struct SentStatusListView: View {
    let messages: [SentMessage]
    @Environment(AppState.self) private var app
    @Environment(M2HubStore.self) private var hub

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
                        // FR24.2 P0 手动「标记已送达」占位（不伪造回执——
                        // 推进 sent → ackPending，等待回执；离线环境明示不可确认）
                        if message.status == .sent {
                            Button(L10n.fr24_markDelivered) {
                                Task {
                                    await hub.markDelivered(messageId: message.id,
                                                           patientId: app.currentPatientId)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                                .frame(minHeight: 44)   // 触点≥44pt（审查修复）
                            .accessibilityIdentifier("FR24.2.markDelivered")
                        } else {
                            StatusBadge(status: message.status)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("FR24.2.row")
                }
                Text(L10n.fr24_offlineNote)
                    .font(.caption2).foregroundStyle(.secondary)
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
            .task(id: currentPatientId) { await hub.load(patientId: currentPatientId) }
    }

    private var currentPatientId: UUID { app.currentPatientId }
}

/// FR24.1 发送前预览 + 收件人选择（V3.72）：第一步所见即所得预览
/// （纯文本、行动指引、有效期、回执提示），确认后进入收件人选择。
struct HelpCardSendHost: View {
    let text: String
    let contacts: [String]
    let onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmed = false

    var body: some View {
        Group {
            if confirmed {
                HelpCardRecipientSheet(text: text, contacts: contacts, onSent: onSend)
            } else {
                NavigationStack {
                    ScrollView {
                        Text(text)
                            .font(.body)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .navigationTitle(L10n.helpcardPreviewTitle)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.commonCancel) { dismiss() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.helpcardPreviewContinue) { confirmed = true }
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        Text(L10n.helpcardPreviewHint)
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
            }
        }
    }
}
