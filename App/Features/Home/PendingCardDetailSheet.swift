import SwiftUI
import Domain
import Infrastructure   // PendingCard / FieldDraft（CoreKit.Infrastructure）
import Perception

/// 首页待办卡详情 sheet（2026-09-26 原子结构轮第三批：自 HomeView 迁出）：
/// Pending detail owns its lookup; another route cannot replace its action target.
/// 自身装载详情、续确认 sheet、原文 sheet、放弃 confirmationDialog 与底部动作条。
struct PendingCardDetailSheet: View {
    let item: AggregatedReminderItem
    @Environment(PendingCardCenterState.self) private var pendingCenter
    @Environment(DocumentsState.self) private var docs
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var resuming = false
    @State private var showDiscard = false
    @State private var showSource = false
    @State private var detail: PendingCard?
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var discardFailed = false
    @State private var discarding = false

    var body: some View {
        WithPerceptionTracking {
            List {
                detailSections
            }
            .navigationTitle(L10n.pendingCardAggregationTitle(item.title))
            .navigationBarTitleDisplayMode(.inline)
            .task(id: item.id.sourceId) {
                await loadDetail()
            }
            .safeAreaInset(edge: .bottom) {
                actionBar
            }
            .sheet(isPresented: $resuming, onDismiss: {
                pendingCenter.refresh(patientId: app.currentPatientId)
                Task {
                    await loadDetail()
                    if detail?.status == "resolved" { dismiss() }
                }
            }) {
                NavigationStack { PendingCardResumeRouteView(cardId: item.id.sourceId) }
            }
            .sheet(isPresented: $showSource) {
                if let detail, let documentID = detail.sourceDocId, let page = detail.sourcePage {
                    DocumentSourcePageView(documentId: documentID, patientId: detail.patientId, pageIndex: page)
                }
            }
            .confirmationDialog(L10n.pendingCardDiscard, isPresented: $showDiscard, titleVisibility: .visible) {
                Button(L10n.pendingCardDiscard, role: .destructive) {
                    guard let detail else { return }
                    discarding = true
                    Task {
                        let discarded = await docs.discardPendingCard(detail)
                        discarding = false
                        pendingCenter.refresh(patientId: app.currentPatientId)
                        if discarded { dismiss() } else { discardFailed = true }
                    }
                }
                Button(L10n.commonCancel, role: .cancel) {}
            }
            .alert(L10n.docConfirmSaveFailedTitle, isPresented: $discardFailed) {
                Button(L10n.onboard_gotIt, role: .cancel) {}
            } message: {
                // alert message 闭包逃逸：同步读 docs.pendingReviews，须自行包裹（子项目 I）
                WithPerceptionTracking {
                    Text(detail.flatMap { docs.pendingReviews[$0.id]?.notificationError } ?? L10n.entityCardSaveFailed)
                }
            }
            .interactiveDismissDisabled(discarding)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.onboard_gotIt) {
                        dismiss()
                    }
                    .disabled(discarding)
                    .accessibilityIdentifier("SP-04.home.pendingCard.close")
                }
            }
        }
    }

    @ViewBuilder
    private var detailSections: some View {
        if let detail {
            Section {
                OCRReviewOwnerRow(patientId: detail.patientId)
                GradeBadge(grade: "D")
            }
            if !detail.incompleteFields.isEmpty {
                Section(L10n.docConfirmSkipTitle) {
                    ForEach(Array(detail.incompleteFields.enumerated()), id: \.offset) { _, field in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.label ?? DocumentsDisplay.fieldLabel(forKey: field.key))
                                .font(.subheadline)
                            Text(L10n.docConfirmHint).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !detail.partialData.shared.isEmpty || !detail.partialData.rows.isEmpty {
                Section(L10n.docConfirmSkipSaved) {
                    if let snapshot = detail.partialData.card {
                        ForEach(snapshot.shared.indices.filter { snapshot.shared[$0].key != "metric_key" }, id: \.self) { index in
                            pendingField(snapshot.shared[index])
                        }
                        ForEach(Array(snapshot.rows.enumerated()), id: \.element.id) { index, row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.entityCardRowIndex(index + 1)).font(.caption)
                                ForEach(row.fields.indices.filter { row.fields[$0].key != "metric_key" }, id: \.self) { field in
                                    pendingField(row.fields[field])
                                }
                            }
                        }
                    } else {
                        // 字典回退形态：与 PendingCardResumeRouteView 同源的单一出口
                        //（2026-09-26 审查去重，见 Documents/PendingCardPartialDataSection.swift）
                        PendingCardPartialDataSection(payload: detail.partialData)
                    }
                }
            }
            if !detail.rawText.isEmpty {
                Section {
                    Text(detail.rawText).font(.footnote)
                } header: {
                    Text(L10n.pendingCardRawText)
                }
            }
        } else if loadFailed {
            Label(L10n.docImportFailed, systemImage: "exclamationmark.triangle")
            Button(L10n.retry) { Task { await loadDetail() } }
        } else if loaded {
            Text(L10n.pendingCardNotFound)
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        if let detail {
            VStack(spacing: 8) {
                Button {
                    resuming = true
                } label: {
                    Label(L10n.pendingCardResume, systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("SP-04.home.pendingCard.resume")
                HStack(spacing: 12) {
                    Button {
                        showSource = true
                    } label: {
                        Label(L10n.pendingCardViewSource, systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(detail.sourceDocId == nil || detail.sourcePage == nil)
                    .accessibilityIdentifier("SP-04.home.pendingCard.viewSource")
                    Button(role: .destructive) {
                        showDiscard = true
                    } label: {
                        Label(L10n.pendingCardDiscard, systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(docs.retainedImport(for: detail) != nil)
                    .accessibilityIdentifier("SP-04.home.pendingCard.discard")
                }
            }
            .padding(16)
            .background(.bar)
            .disabled(discarding)
        }
    }

    private func loadDetail() async {
        loaded = false; loadFailed = false
        do {
            let fetched = try await docs.loadPendingCard(id: item.id.sourceId)
            guard !Task.isCancelled else { return }
            detail = fetched
        } catch { loadFailed = true; detail = nil }
        loaded = true
    }

    private func pendingField(_ field: FieldDraft) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(DocumentsDisplay.fieldLabel(forKey: field.key)).font(.caption).foregroundStyle(.secondary)
            Text(DocumentsDisplay.fieldValueDisplay(forKey: field.key, value: field.value))
                .strikethrough(field.grade == .rejected)
        }
    }
}
