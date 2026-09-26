import SwiftUI
import Domain
import Perception

/// 业主裁决 4（2026-09-26，EntityCardConfirmView 全拆分）：确认页的渲染段全部出列
/// 为无状态叶子视图（值 + 闭包依赖，无 @State/@Environment）——与 HomeSubviews
/// 同一组合模式；编排器（EntityCardConfirmView）保留状态与业务变异逻辑。

// MARK: - 卡头段

struct EntityCardHeaderSectionView: View {
    let patientId: UUID
    let pageIndex: Int
    let pageCount: Int
    let position: (Int, Int)?
    let onViewScan: () -> Void

    var body: some View {
        Section {
            OCRReviewOwnerRow(patientId: patientId)
            HStack {
                Text(L10n.entityCardHeaderPage(pageIndex + 1, max(pageCount, pageIndex + 1)))
                if let position { Text(L10n.entityCardHeaderIndex(position.0, position.1)) }
                Spacer()
                GradeBadge(grade: "D")
            }.font(.caption)
            Button {
                onViewScan()
            } label: {
                Label(L10n.pendingCardViewSource, systemImage: "doc.text.magnifyingglass").frame(minHeight: 44)
            }.buttonStyle(.borderless)
        } footer: { Text(L10n.docConfirmHint) }
    }
}

// MARK: - 复核清单段

struct EntityCardReviewSectionView: View {
    let items: [CardConfirmationRules.ReviewItem]
    let proxy: ScrollViewProxy
    let rowPosition: (UUID?) -> Int?
    let sourceLineFor: (CardConfirmationRules.ReviewItem) -> Int?
    let onAppendMissing: (CardConfirmationRules.ReviewItem) -> Void
    let onChoose: (CardConfirmationRules.ReviewItem) -> Void
    let onConfirm: (CardConfirmationRules.ReviewItem) -> Void
    let onViewSource: (CardConfirmationRules.ReviewItem) -> Void

    /// 清单表头的字段名（同键多行只报一次——12 药处方不会把表头撑爆）。
    private func uniqueLabels() -> [String] {
        var seen = Set<String>()
        return items.compactMap { item in
            seen.insert(item.key).inserted ? DocumentsDisplay.fieldLabel(forKey: item.key) : nil
        }
    }

    var body: some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in reviewQueueRow(item) }
            } header: {
                Text(L10n.entityCardReviewQueue(count: items.count,
                                                labels: ListFormatter.localizedString(byJoining: uniqueLabels())))
                    .foregroundStyle(Color("semantic-warning", bundle: .main))
                    .accessibilityIdentifier("SP-12.entity.reviewQueue")
            }
        }
    }

    /// 清单一项：就地处置（确认 / 补填），不要求用户先找到它。
    private func reviewQueueRow(_ item: CardConfirmationRules.ReviewItem) -> some View {
        let label = DocumentsDisplay.fieldLabel(forKey: item.key)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let rowId = item.rowId, let position = rowPosition(rowId) {
                    Text(L10n.entityCardRowIndex(position)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.isMissing {
                // 缺 = 另一条路（业界把「缺」与「低置信」分开处理是明确口径）：
                // 与既有的「缺少 X，点此填写」同一动作——补上字段并滚到它。
                Button(L10n.entityCardMissingRequired(label)) { onAppendMissing(item) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("SP-12.review.fill.\(item.id)")
            } else if item.severity == 2 {
                // 歧义项**不给就地确认**：有候选就必须先做选择（业主 2026-09-17 裁定「挡」），
                // 一键确认会让默认胜出值溜过去——只跳到字段处的候选选择器。
                Button(L10n.entityCardReviewChoose) { onChoose(item) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("SP-12.review.choose.\(item.id)")
            } else {
                Button(L10n.commonConfirm) { onConfirm(item) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("SP-12.review.confirm.\(item.id)")
                if sourceLineFor(item) != nil {
                    Button(L10n.entityCardReviewSource) { onViewSource(item) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("SP-12.review.source.\(item.id)")
                }
            }
        }
        .frame(minHeight: 44)
    }
}

// MARK: - 校验提示段

struct EntityCardValidationHintSectionView: View {
    let hasValidationIssues: Bool

    var body: some View {
        if hasValidationIssues {
            Section { Text(L10n.docConfirmHint).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - 确认动作段

struct EntityCardConfirmationActionsSectionView: View {
    let showDeferRemaining: Bool
    let onLater: () -> Void
    let onDiscard: () -> Void
    let onDeferRemaining: () -> Void

    var body: some View {
        Section {
            Button { onLater() } label: {
                Label(L10n.entityCardLater, systemImage: "clock.badge.checkmark").frame(minHeight: 44)
            }
            Button(role: .destructive) { onDiscard() } label: {
                Label(L10n.entityCardDiscard, systemImage: "xmark.circle").frame(minHeight: 44)
            }
            if showDeferRemaining {
                Button {
                    onDeferRemaining()
                } label: {
                    Label(L10n.entityCardDeferRemaining, systemImage: "tray.full").frame(minHeight: 44)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.entityCardConfirmAllHint)
                Text(L10n.entityCardLaterHint)
            }
        }
        .buttonStyle(.borderless)
    }
}
