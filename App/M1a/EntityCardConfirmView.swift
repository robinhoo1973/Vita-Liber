import SwiftUI
import Domain
import Infrastructure

/// FR6.9 V3.61 页级实体卡确认（SP-12 逐卡确认）：文档卡确认后，每页按卡模板匹配出的
/// 信息卡逐张呈现——卡头「第 p/N 页 · 第 k/m 张 · 卡类名」，共享字段 + 逐行字段，
/// 三动作：确认保存 / 稍后处理（待办 + 1h 提醒）/ 放弃本卡；队列级「剩余全部稍后处理」。
///
/// 呈现纪律：**只渲染已识别字段**（缺失推荐字段不渲染空行）；卡级缺失必填渲染单行
/// 「缺少 X，点此填写」并阻断保存；行级缺必填的行标「保存时跳过」不阻断其他行。
/// 低置信闸门沿用 `OcrConfirmationSet.allConfirmAllowed`（BR-003）。
///
/// 同一视图承载两种模式：队列（`.queue`）与待办续确认（`.resume(PendingCard)`），
/// 落库走 `DocumentsState` 同一路径。
struct EntityCardConfirmView: View {
    enum Mode { case queue, resume(PendingCard) }

    @Environment(DocumentsState.self) private var docs
    @Environment(PendingCardCenterState.self) private var pendingCenter
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let card: MatchedCard
    let mode: Mode
    /// 页总数（文档卡传入；续确认从页表读取失败时回落 pageIndex+1）
    var pageCount: Int
    /// 队列位置「第 k/m 张」（续确认为 nil）
    var position: (Int, Int)?

    /// 共享字段确认集（索引与 card.shared 对齐）
    @State private var shared: [CandidateField] = []
    /// 各行字段确认集（外层与 card.rows 对齐）
    @State private var rows: [[CandidateField]] = []
    /// 卡级缺失必填的补填值（键 → 值）
    @State private var filledRequired: [String: String] = [:]
    @State private var editingRequired: String?
    @State private var saving = false
    @State private var showLaterDialog = false
    @State private var showDiscardDialog = false
    @State private var saveFailed = false

    private var allFields: [CandidateField] { shared + rows.flatMap { $0 } }
    private var allConfirmAllowed: Bool {
        !allFields.contains { $0.grade == .ocrUnconfirmed && ConfidenceTier.tier($0.confidence) == .low }
    }
    private var missingRequiredUnfilled: [CompletenessFieldRule] {
        card.missingRequired.filter { (filledRequired[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }
    private var canSave: Bool { !saving && allConfirmAllowed && missingRequiredUnfilled.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Text(L10n.entityCardHeaderPage(card.pageIndex + 1, max(pageCount, card.pageIndex + 1)))
                        if let position {
                            Text("·").foregroundStyle(.tertiary)
                            Text(L10n.entityCardHeaderIndex(position.0, position.1))
                        }
                        Spacer()
                        GradeBadge(grade: "D")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("SP-12.entity.header")
                    Text(L10n.entityCardKindName(card.kind)).font(.headline)
                } footer: {
                    Text(L10n.docConfirmHint)
                }

                // 卡级缺失必填：单行补填，未填阻断保存（≤20% 必填缺口由用户补齐）
                if !card.missingRequired.isEmpty {
                    Section {
                        ForEach(card.missingRequired, id: \.key) { rule in
                            let label = L10n.templateFieldLabel(rule.key)
                            if editingRequired == rule.key {
                                TextField(label, text: Binding(
                                    get: { filledRequired[rule.key] ?? "" },
                                    set: { filledRequired[rule.key] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { editingRequired = nil }
                            } else {
                                Button {
                                    editingRequired = rule.key
                                } label: {
                                    Label((filledRequired[rule.key]?.isEmpty == false) ? "\(label): \(filledRequired[rule.key] ?? "")"
                                          : L10n.entityCardMissingRequired(label),
                                          systemImage: (filledRequired[rule.key]?.isEmpty == false) ? "checkmark.circle" : "exclamationmark.circle")
                                        .foregroundStyle((filledRequired[rule.key]?.isEmpty == false)
                                                         ? Color("semantic-success", bundle: .main)
                                                         : Color("semantic-warning", bundle: .main))
                                }
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("SP-12.entity.missing.\(rule.key)")
                            }
                        }
                    }
                }

                if !shared.isEmpty {
                    Section(L10n.entityCardSharedSection) {
                        ForEach(shared.indices, id: \.self) { idx in
                            FieldConfirmRow(field: $shared[idx])
                        }
                    }
                }

                if !rows.isEmpty, !(rows.count == 1 && rows[0].isEmpty) {
                    Section(L10n.entityCardRowsSection) {
                        ForEach(rows.indices, id: \.self) { rowIndex in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(L10n.entityCardRowIndex(rowIndex + 1))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                    if !card.rows[rowIndex].missingRequired.isEmpty {
                                        Text(L10n.entityCardRowSkipped)
                                            .font(.caption2)
                                            .foregroundStyle(Color("semantic-warning", bundle: .main))
                                            .accessibilityIdentifier("SP-12.entity.rowSkipped")
                                    }
                                }
                                ForEach(rows[rowIndex].indices, id: \.self) { idx in
                                    FieldConfirmRow(field: $rows[rowIndex][idx])
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if !allConfirmAllowed {
                    Section {
                        Text(L10n.docConfirmAllConfirmBlocked)
                            .font(.caption)
                            .foregroundStyle(Color("semantic-danger", bundle: .main))
                    }
                }

                Section {
                    Button {
                        showLaterDialog = true
                    } label: {
                        Label(L10n.entityCardLater, systemImage: "clock.badge.checkmark")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("SP-12.entity.later")
                    Button(role: .destructive) {
                        showDiscardDialog = true
                    } label: {
                        Label(L10n.entityCardDiscard, systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("SP-12.entity.discard")
                    if case .queue = mode, docs.entityQueue.count > 1 {
                        Button {
                            Task {
                                saving = true
                                await docs.deferRemainingEntityCards()
                                saving = false
                            }
                        } label: {
                            Label(L10n.entityCardDeferRemaining, systemImage: "tray.full")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .disabled(saving)
                        .accessibilityIdentifier("SP-12.entity.deferRemaining")
                    }
                } footer: {
                    Text(L10n.entityCardLaterHint)
                }
            }
            .navigationTitle(L10n.entityCardKindName(card.kind))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.entityCardConfirmSave) { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("SP-12.entity.confirm")
                }
            }
            .confirmationDialog(L10n.entityCardLater, isPresented: $showLaterDialog, titleVisibility: .visible) {
                Button(L10n.docConfirmSkipConfirm) { defer_() }
                Button(L10n.commonCancel, role: .cancel) {}
            } message: {
                Text(L10n.entityCardLaterHint)
            }
            .confirmationDialog(L10n.entityCardDiscard, isPresented: $showDiscardDialog, titleVisibility: .visible) {
                Button(L10n.entityCardDiscard, role: .destructive) { discard() }
                Button(L10n.commonCancel, role: .cancel) {}
            }
            .alert(L10n.docConfirmSaveFailedTitle, isPresented: $saveFailed) {
                Button(L10n.onboard_gotIt, role: .cancel) {}
            } message: {
                Text(L10n.entityCardSaveFailed)
            }
            .onAppear(perform: seed)
        }
    }

    // MARK: - 状态装配

    /// 卡字段 → 确认集（共享/逐行分开寻址；显示标签走 L10n 单出口）
    private func seed() {
        guard shared.isEmpty && rows.isEmpty else { return }
        shared = card.shared.map(Self.candidate)
        rows = card.rows.map { $0.fields.map(Self.candidate) }
    }

    private static func candidate(_ draft: FieldDraft) -> CandidateField {
        CandidateField(key: draft.key, displayLabel: L10n.templateFieldLabel(draft.key),
                       rawText: draft.rawText ?? draft.value, confidence: draft.confidence,
                       value: draft.value, codeResolution: draft.codeResolution)
    }

    /// 确认集 → 已确认卡（拒绝字段剔除；补填的必填并入共享；未确认字段批量确认）
    private func confirmedCard() -> MatchedCard {
        func drafts(_ fields: [CandidateField]) -> [FieldDraft] {
            fields.filter { $0.grade != .rejected }.map {
                FieldDraft(key: $0.key, value: $0.value, confidence: $0.confidence,
                           rawText: $0.rawText, codeResolution: $0.codeResolution)
            }
        }
        var confirmed = card
        confirmed.shared = drafts(shared) + filledRequired.compactMap { key, value in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : FieldDraft(key: key, value: trimmed, confidence: 1.0)
        }
        confirmed.rows = zip(card.rows, rows).map { original, fields in
            MatchedCardRow(id: original.id, fields: drafts(fields), missingRequired: original.missingRequired)
        }
        return confirmed
    }

    // MARK: - 三动作

    private func save() {
        guard canSave else { return }
        saving = true
        for idx in shared.indices { _ = shared[idx].confirm() }
        for r in rows.indices { for idx in rows[r].indices { _ = rows[r][idx].confirm() } }
        let confirmed = confirmedCard()
        Task {
            let ok: Bool
            switch mode {
            case .queue:
                ok = await docs.confirmEntityCard(card, confirmed: confirmed)
            case .resume(let pending):
                ok = await docs.completePendingCard(pending, confirmed: confirmed)
                if ok { pendingCenter.refresh(patientId: app.currentPatientId) }
            }
            saving = false
            if ok {
                if case .resume = mode { dismiss() }
                // 队列模式：出队后父级 sheet(item:) 按 currentEntityCard 自动切换/收起
            } else {
                saveFailed = true
            }
        }
    }

    private func defer_() {
        saving = true
        Task {
            switch mode {
            case .queue:
                let ok = await docs.deferEntityCard(card)
                saving = false
                if !ok { saveFailed = true }
            case .resume:
                // 待办卡本就在队列，「稍后」= 关闭即可
                saving = false
                dismiss()
            }
        }
    }

    private func discard() {
        switch mode {
        case .queue:
            docs.discardEntityCard(card)
        case .resume(let pending):
            Task {
                await docs.discardPendingCard(pending)
                pendingCenter.refresh(patientId: app.currentPatientId)
                dismiss()
            }
        }
    }
}

/// FR6.9 待办卡续确认路由落点（1h 通知深链 `.pendingCard(id)`）：读卡 → 还原实体卡 →
/// `EntityCardConfirmView(mode: .resume)`；已处理/不存在 → 可见空态。
struct PendingCardResumeRouteView: View {
    let cardId: String
    @Environment(DocumentsState.self) private var docs
    @Environment(PendingCardCenterState.self) private var pendingCenter
    @State private var pending: PendingCard?
    @State private var card: MatchedCard?
    @State private var pageCount = 1
    @State private var loaded = false

    var body: some View {
        Group {
            if let pending, let card {
                EntityCardConfirmView(card: card, mode: .resume(pending), pageCount: pageCount, position: nil)
            } else if loaded {
                ContentUnavailableView(L10n.pendingCardNotFound, systemImage: "tray")
                    .accessibilityIdentifier("SP-12.pendingCard.notFound")
            } else {
                ProgressView()
            }
        }
        .task(id: cardId) {
            await pendingCenter.loadDetail(id: cardId)
            if let detail = pendingCenter.detail, detail.status == "pending" || detail.status == "in_progress" {
                pending = detail
                card = await docs.resumePendingCard(detail)
                if let docId = detail.sourceDocId {
                    let pages = await docs.pageCount(documentId: docId)
                    pageCount = max(pages, (detail.sourcePage ?? 0) + 1)
                }
            }
            loaded = true
        }
    }
}
