import SwiftUI
import Domain

/// FR6.8 待确认字段聚合队列（SP-53 · ui-ux §5.30）：
/// 跨文档聚合全部未确认高风险字段，按成员/来源文档分组、低置信度置顶；
/// 支持逐字段确认与「全部确认」（仅当无红色低置信度字段时可用）；
/// 每条可一键跳回来源文档原文（BR-002）。
/// FR2.3：超过 72 小时未处理的字段置顶钉住（重复置顶提醒）。
struct PendingOcrQueueView: View {
    @Environment(AppState.self) private var app
    @Environment(AppRouter.self) private var router

    /// 低置信度置顶 + 72h 置顶钉住（FR2.3/FR6.8 排序规则）
    private var sortedFields: [(entry: TimelineDocumentEntry, field: CandidateField)] {
        app.pendingOcrFields().sorted { a, b in
            let aLow = ConfidenceTier.tier(a.field.confidence) == .low
            let bLow = ConfidenceTier.tier(b.field.confidence) == .low
            if aLow != bLow { return aLow }
            let a72 = isOver72h(a.entry)
            let b72 = isOver72h(b.entry)
            if a72 != b72 { return a72 }
            return a.entry.occurredAt > b.entry.occurredAt
        }
    }

    var body: some View {
        Group {
            if sortedFields.isEmpty {
                ContentUnavailableView(L10n.ocrQueueEmpty, systemImage: "checkmark.seal",
                                       description: Text(L10n.ocrQueueEmptyHint))
                    .accessibilityIdentifier("SP-53.queue.empty")
            } else {
                List {
                    Section {
                        HStack {
                            Text(L10n.ocrQueueCount(sortedFields.count))
                                .font(.subheadline)
                            Spacer()
                            // FR6.8：全部确认闸门（红色低置信度存在时禁用）
                            if app.queueAllConfirmAllowed {
                                Button(L10n.ocrQueueAllConfirm) {
                                    app.confirmAllPendingFields()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .accessibilityIdentifier("SP-53.queue.confirmAll")
                            } else {
                                Text(L10n.ocrQueueAllConfirmBlocked)
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                    ForEach(Array(sortedFields.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                // FR6.3 颜色语义：高绿 / 中黄 / 低红
                                Circle()
                                    .fill(tierColor(item.field))
                                    .frame(width: 10, height: 10)
                                Text(item.field.displayLabel)
                                    .font(.subheadline)
                                if isOver72h(item.entry) {
                                    Text(L10n.ocrQueue72h)
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.red.opacity(0.12)))
                                        .foregroundStyle(.red)
                                }
                                Spacer()
                                // FR6.8 一键跳回来源文档原文（BR-002）
                                Button(L10n.ocrQueueJumpSource) {
                                    router.navigate(to: .documentDetail(item.entry.id))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Text(item.field.value)
                                .font(.body)
                            Text(item.field.rawText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                Button(L10n.onboard_confirm) {
                                    app.confirmTimelineField(entryId: item.entry.id, fieldId: item.field.id)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .accessibilityIdentifier("SP-53.queue.confirm.\(item.field.key)")
                                Button(L10n.onboard_revise) {
                                    reviseField(item)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Button(L10n.onboard_reject) {
                                    app.rejectTimelineField(entryId: item.entry.id, fieldId: item.field.id)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("SP-53.queue.row")
                    }
                }
            }
        }
        .navigationTitle(L10n.ocrQueueTitle)
        // FR6.4 修订入口（队列与工作台同语义：原识别值永久保留 + 修订历史）
        .alert(L10n.onboardReviseTitle(reviseTarget?.field.displayLabel ?? ""),
               isPresented: reviseBinding) {
            TextField(L10n.onboard_newValue, text: $reviseDraft)
            Button(L10n.onboard_saveEdit) {
                if let target = reviseTarget {
                    app.reviseTimelineField(entryId: target.entry.id,
                                            fieldId: target.field.id, to: reviseDraft)
                }
                reviseTarget = nil
            }
            Button(L10n.onboard_cancel, role: .cancel) { reviseTarget = nil }
        } message: {
            Text(L10n.onboardOcrRaw(reviseTarget?.field.rawText ?? ""))
        }
    }

    private func isOver72h(_ entry: TimelineDocumentEntry) -> Bool {
        Date().timeIntervalSince1970 - entry.occurredAt > 72 * 3600
    }

    private func tierColor(_ field: CandidateField) -> Color {
        switch ConfidenceTier.tier(field.confidence) {
        case .high: return .green
        case .mid: return .orange
        case .low: return .red
        }
    }

    private func reviseField(_ item: (entry: TimelineDocumentEntry, field: CandidateField)) {
        // FR6.4：修改留「谁改的、何时、改成什么」历史（写入路径在 AppState）
        reviseTarget = item
        reviseDraft = item.field.value
    }

    @State private var reviseTarget: (entry: TimelineDocumentEntry, field: CandidateField)?
    @State private var reviseDraft = ""

    private var reviseBinding: Binding<Bool> {
        Binding(get: { reviseTarget != nil }, set: { if !$0 { reviseTarget = nil } })
    }
}
