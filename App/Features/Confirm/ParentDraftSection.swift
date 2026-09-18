import SwiftUI
import Domain
import Infrastructure
import Perception

/// SP-12 主卡草稿区（子项目 J · recognition-remediation-design §0.4 改判 / BR-003）：
/// 关联区裁决为 `.newHub(draft)` 时置于确认页**最前**——识别出的子卡永远有父，无可挂接主卡即随本卡新建一条 D 级主卡草稿，
/// 与子卡同流确认、同事务落库（`OCRCardStore.save`）。草稿字段逐条 `FieldConfirmRow`（卡级确认；必填与低置信逐项）；
/// 日期缺失/不可解析 → 内联 DatePicker 补填（写 yyyy-MM-dd，用户显式选择 = 已确认）；可切回「选择已有主卡」。
/// 只搬子卡共享字段原文，不推断（Domain `ParentCardDraftRules`）。
struct ParentDraftSection: View {
    @Binding var card: MatchedCard
    let patientId: UUID
    var readOnly = false
    /// 字段 → 原文行锚定：sheet 由父视图（确认页）持有，草稿区只转发（`FieldConfirmRow.sourceLine`）。
    var onViewSource: ((Int) -> Void)?
    private let calendar = Calendar(identifier: .gregorian)

    var body: some View {
        WithPerceptionTracking {
            if case .newHub(let draft) = card.encounterAssociation {
                Section {
                    HStack(spacing: 8) {
                        let spec = CardKindIcon.spec(hub: draft.hub)
                        Image(systemName: spec.symbol).foregroundStyle(spec.tint)
                        Text(draft.hub == .healthExam ? L10n.parentDraftNewHealthExam : L10n.parentDraftNewEncounter)
                            .font(.subheadline)
                        Spacer()
                        GradeBadge(grade: "D")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("SP-12.parentDraft.kind.\(draft.hub.rawValue)")
                    ForEach(draft.fields.indices, id: \.self) { index in
                        // ForEach 行闭包逃逸：同步读 card 绑定，须自行包裹（子项目 I）
                        WithPerceptionTracking {
                            if index < draft.fields.count {
                                FieldConfirmRow(field: fieldBinding(index: index),
                                                label: DocumentsDisplay.fieldLabel(forKey: draft.fields[index].key),
                                                showUnit: false, readOnly: readOnly, cardLevelConfirmation: true,
                                                isRequired: draftRequired.contains(draft.fields[index].key),
                                                sourceLine: draft.fields[index].sourceLineIndex,
                                                onViewSource: onViewSource,
                                                onRevise: { revise(index: index, value: $0) })
                                    .accessibilityIdentifier("SP-12.parentDraft.field.\(draft.fields[index].key)")
                            }
                        }
                    }
                    if !dateResolvable(draft) {
                        // 日期缺失或不可解析：内联日期选择（保存前必须补齐；与 store `isComplete` 同口径）
                        Text(L10n.parentDraftDateRequired).font(.caption).foregroundStyle(.orange)
                            .accessibilityIdentifier("SP-12.parentDraft.dateRequired")
                        DatePicker(DocumentsDisplay.fieldLabel(forKey: draft.dateKey), selection: dateBinding(draft), displayedComponents: .date)
                            .accessibilityIdentifier("SP-12.parentDraft.datePicker")
                    }
                    let pendingRequired = draftRequired.subtracting(Set(draft.fields.filter(\.isConfirmed).map(\.key)))
                    if !pendingRequired.isEmpty {
                        // 必填逐项确认（FR6.9 2026-09-17 裁定）：`isComplete` 要求草稿字段全部已确认，
                        // 而必填不参与卡级批量——如实报出还差哪几项，别让用户只见灰按钮。
                        // 此处只报**必填**（草稿的非必填合格字段由卡级动作批量升 C；低置信另有下面一行提示）。
                        Text(L10n.entityCardReviewQueue(
                            count: pendingRequired.count,
                            labels: ListFormatter.localizedString(byJoining: pendingRequired.sorted().map { DocumentsDisplay.fieldLabel(forKey: $0) })))
                            .font(.caption)
                            .foregroundStyle(Color("semantic-warning", bundle: .main))
                            .accessibilityIdentifier("SP-12.parentDraft.pendingRequired")
                    }
                    if hasUnconfirmedLowConfidence(draft) {
                        Text(L10n.parentDraftUnconfirmed).font(.caption).foregroundStyle(.secondary)
                    }
                    Button(L10n.parentDraftUseExisting) {
                        // 回到候选 Picker：显式放弃草稿 → 未选择；关联区不再自动回落草稿（用户显式选择优先）
                        card.encounterAssociation = .unselected
                    }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("SP-12.parentDraft.useExisting")
                } header: { Text(L10n.parentDraftTitle) } footer: { Text(L10n.parentDraftHint) }
                .disabled(readOnly)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("SP-12.parentDraft.section")
            }
        }
    }

    // MARK: - 草稿字段读写（只经 card.encounterAssociation 单一真值）

    private var draft: HubDraft? {
        if case .newHub(let d) = card.encounterAssociation { return d }
        return nil
    }

    private func update(_ mutate: (inout HubDraft) -> Void) {
        guard !readOnly, case .newHub(var d) = card.encounterAssociation else { return }
        mutate(&d)
        card.encounterAssociation = .newHub(d)
    }

    private func fieldBinding(index: Int) -> Binding<FieldDraft> {
        let fallback = FieldDraft(key: "", value: "", confidence: 0)
        return Binding(get: {
            guard let d = draft, d.fields.indices.contains(index) else { return fallback }
            return d.fields[index]
        }, set: { field in
            update { d in if d.fields.indices.contains(index) { d.fields[index] = field } }
        })
    }

    /// 主卡草稿的必填集按**其枢纽**取（`RecordHub` 的 raw 值即 `CardKindRegistry` 的 kind）——
    /// 与 `CardConfirmationRules.confirmingDraft` 同源，视图不复制键表。
    private var draftRequired: Set<String> {
        guard case .newHub(let draft) = card.encounterAssociation else { return [] }
        return Set(CardKindRegistry.entry(for: draft.hub.rawValue)?.sharedRequired ?? [])
    }

    private func revise(index: Int, value: String) {
        // 用户手填走 `fillByUser`（FR6.9 2026-09-17）：原值为空的草稿字段填入即确认。
        update { d in if d.fields.indices.contains(index) { d.fields[index].fillByUser(value) } }
    }

    /// 日期字段存在且可解析（yyyy-MM-dd / yyyy/M/d / yyyy年M月d日）。
    private func dateResolvable(_ draft: HubDraft) -> Bool {
        guard let field = draft.fields.first(where: { $0.key == draft.dateKey }), field.grade != .rejected else { return false }
        return EntityCardProjection.parseDate(field.value, calendar: calendar) != nil
    }

    /// 低置信且未确认的草稿字段（卡级批量确认不覆盖低置信，FR6.9 资格谓词）。
    private func hasUnconfirmedLowConfidence(_ draft: HubDraft) -> Bool {
        draft.fields.contains { $0.grade != .rejected && !$0.isConfirmed && ConfidenceTier.tier($0.confidence) == .low }
    }

    /// 内联日期选择：写 yyyy-MM-dd 到日期字段（缺席则追加）；用户显式选择 = 已确认（C）。
    private func dateBinding(_ draft: HubDraft) -> Binding<Date> {
        Binding(get: {
            draft.fields.first { $0.key == draft.dateKey }.flatMap { EntityCardProjection.parseDate($0.value, calendar: calendar) } ?? Date()
        }, set: { picked in
            let text = Self.dateText(picked)
            update { d in
                if let index = d.fields.firstIndex(where: { $0.key == d.dateKey }) {
                    if d.fields[index].grade == .rejected { d.fields[index].reenable() }   // 拒绝过的日期字段经选择日期重新启用
                    d.fields[index].revise(to: text)
                    _ = d.fields[index].confirm()
                } else {
                    var field = FieldDraft(key: d.dateKey, value: text, confidence: 1)
                    _ = field.confirm()
                    d.fields.append(field)
                }
            }
        })
    }

    /// yyyy-MM-dd（公历、当前时区）——`EntityCardProjection.parseDate` 可逆解析。
    static func dateText(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}
