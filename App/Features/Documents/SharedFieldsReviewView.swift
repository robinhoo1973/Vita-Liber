import SwiftUI
import Domain
import Infrastructure
import Perception

/// 共用信息步（SP-63；业主 2026-09-17 定：确认流程改两步——先共用信息、再逐卡行级）。
///
/// **为什么有这一步**：同一页的多张卡各自持有共用字段的**副本**（`matchPages` 每个模板各建一张卡，
/// `FieldDraft` 是值类型）——处方卡上确认过的日期，在收费卡上仍是 D，同一件事要确认 N 遍。
///
/// **入池**（Domain `SharedFieldPool` 单一事实源）：被 ≥2 张卡携带 ∨（必填 ∧（置信 <0.6 ∨ 缺失），
/// 多卡时）——业主原话：「只要是被多于一个信息卡使用的字段就需要单独拿出来确认」「重要和关键信息
/// 置信度不高且关联到必选字段的……哪怕不被多信息卡公用也需要在这个新页面出现」「缺失的关键字段
/// 也要加在公用字段修正页面」。
///
/// **离场**：处理完 → 回填各承载方并进卡级；未处理完 → **只能「稍后处理」**（业主：不能进入卡级处理）。
struct SharedFieldsReviewView: View {
    let session: DocumentsState.ImportSession
    let patientId: UUID

    @State private var rows: [SharedFieldPool.Row] = []
    @State private var sourceAnchor: SourceAnchor?
    @State private var showLater = false
    @State private var saving = false
    @Environment(DocumentsState.self) private var docs

    /// 原文行锚定的呈现载荷（行 + 该行所属页的文本行）。
    private struct SourceAnchor: Identifiable {
        let id = UUID()
        let lines: [String]
        let line: Int
    }

    private var settled: Bool { SharedFieldPool.isSettled(rows) }
    private var pending: Int { SharedFieldPool.awaitingCount(rows) }
    private var pagesLines: [[String]] { session.source?.pages.map(\.lines) ?? [] }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                List {
                    Section {
                        // 与卡级页同一视觉语言：先说明"这是谁的档案"（代家人记录时戴橙环），再谈字段
                        OCRReviewOwnerRow(patientId: patientId)
                        Text(L10n.sharedFieldsHint).font(.caption).foregroundStyle(.secondary)
                        if !settled {
                            Text(L10n.sharedFieldsPending(pending))
                                .font(.caption)
                                .foregroundStyle(Color("semantic-warning", bundle: .main))
                                .accessibilityIdentifier("SP-63.sharedFields.pending")
                        }
                    }
                    ForEach(rows.indices, id: \.self) { index in
                        Section {
                            fieldRow(index)
                        } header: {
                            rowHeader(index)
                        } footer: {
                            Text(L10n.sharedFieldsCarriers(carriersLabel(rows[index])))
                                .font(.caption)
                        }
                    }
                }
                .disabled(saving)
                .navigationTitle(L10n.sharedFieldsTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .task {
                    // 每帧纪律：清单只算一次（用户编辑落在 rows 上，不回读 session.cards）
                    if rows.isEmpty { rows = docs.sharedFieldRows(for: session) }
                }
                .sheet(item: $sourceAnchor) { anchor in
                    SourceLineSheet(lines: anchor.lines, highlight: anchor.line)
                }
                .confirmationDialog(L10n.entityCardLater, isPresented: $showLater, titleVisibility: .visible) {
                    Button(L10n.docConfirmSkipConfirm) { deferAll() }
                    Button(L10n.commonCancel, role: .cancel) {}
                }
            }
        }
    }

    // MARK: - 行

    /// 一行字段：复用 `FieldConfirmRow`（同一确认语义），但**不给 [放弃]**——
    /// 一个值被多张卡共用时「拒绝」归属不明（同日期对处方对、对检验错），本页只做确认/修正。
    @ViewBuilder
    private func fieldRow(_ index: Int) -> some View {
        FieldConfirmRow(field: $rows[index].field,
                        label: DocumentsDisplay.fieldLabel(forKey: rows[index].key),
                        showUnit: false,
                        cardLevelConfirmation: false,
                        isRequired: rows[index].required,
                        allowsReject: false,
                        sourceLine: sourceLine(rows[index]),
                        onViewSource: { _ in viewSource(rows[index]) })
    }

    @ViewBuilder
    private func rowHeader(_ index: Int) -> some View {
        HStack(spacing: 6) {
            Text(DocumentsDisplay.fieldLabel(forKey: rows[index].key))
            if rows[index].repeatedAcrossCards { reasonChip(L10n.sharedFieldsReasonRepeated) }
            if rows[index].criticalLowConfidence { reasonChip(L10n.sharedFieldsReasonCritical) }
        }
    }

    private func reasonChip(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color("semantic-warning", bundle: .main).opacity(0.18)))
    }

    /// 承载方说明：卡类名（行级时附「第 n 行」；主卡草稿附「主卡草稿」），去重。
    private func carriersLabel(_ row: SharedFieldPool.Row) -> String {
        var parts: [String] = []
        for carrier in row.carriers {
            guard let card = session.cards.first(where: { $0.id == carrier.cardId }) else { continue }
            var name = L10n.entityCardKindName(card.kind)
            switch carrier.face {
            case .shared:
                break
            case .row(let rowId):
                if let position = card.rows.firstIndex(where: { $0.id == rowId }).map({ $0 + 1 }) {
                    name += " · " + L10n.entityCardRowIndex(position)
                }
            case .hubDraft:
                name += " · " + L10n.parentDraftTitle
            }
            if !parts.contains(name) { parts.append(name) }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 原文行锚定（与卡级同一条证据链）

    /// 行所属页的文本行（同一坐标系：`FieldDraft.sourceLineIndex` ↔ 页文本行）。
    private func lines(for row: SharedFieldPool.Row) -> [String] {
        guard let carrier = row.carriers.first,
              let card = session.cards.first(where: { $0.id == carrier.cardId }),
              pagesLines.indices.contains(card.pageIndex) else { return [] }
        return pagesLines[card.pageIndex]
    }

    private func sourceLine(_ row: SharedFieldPool.Row) -> Int? {
        let pageLines = lines(for: row)
        guard let line = row.field.sourceLineIndex, pageLines.indices.contains(line) else { return nil }
        return line
    }

    private func viewSource(_ row: SharedFieldPool.Row) {
        guard let line = sourceLine(row) else { return }   // 无锚定就不给入口（同卡级纪律）
        sourceAnchor = SourceAnchor(lines: lines(for: row), line: line)
    }

    // MARK: - 离场

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L10n.docConfirmSkipLater) { showLater = true }
                .disabled(saving)
                .accessibilityIdentifier("SP-63.sharedFields.later")
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(L10n.sharedFieldsContinue) { settleAndContinue() }
                .disabled(saving || !settled)
                .accessibilityIdentifier("SP-63.sharedFields.continue")
        }
    }

    private func settleAndContinue() {
        guard !saving, settled else { return }
        saving = true
        _ = docs.settleSharedFields(rows, sessionID: session.id)   // 置位后本步从流程中消失
        saving = false
    }

    private func deferAll() {
        guard !saving else { return }
        saving = true
        Task {
            _ = await docs.deferFromSharedFields(rows, sessionID: session.id)
            saving = false
        }
    }
}
