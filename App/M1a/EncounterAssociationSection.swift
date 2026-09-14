import SwiftUI
import Domain
import Infrastructure
import Perception

/// 建议只写入当前卡草稿；保存卡时才在同一事务验证成员并建立关系。
/// v27（子项目 J · §0.4 改判）：默认裁决单入口 = `ParentCardDraftRules.association`——就诊族子卡先跑 ±3 日同医院预选
/// （`.suggested`），无命中 → `.newHub(草稿)`（草稿区在本区上方呈现）；体检枢纽子卡恒草稿；无枢纽卡类 → 未选择。
/// Picker 首项按卡类：有枢纽卡类 = 「新建就诊/体检（草稿）」，无枢纽 = 「不关联」。
struct EncounterAssociationSection: View {
    @Binding var card: MatchedCard
    let patientId: UUID
    var readOnly = false
    /// 文档稳定键（主卡草稿的 kind / 体检重定向依据）：队列模式由确认页从导入会话传入；续办模式无（nil → 门诊缺省）。
    var documentTypeKey: String?
    @Environment(DocumentsState.self) private var docs
    @State private var candidates: [EncounterResolver.Candidate] = []
    @State private var failed = false
    @State private var loading = false

    private static let draftTag = "draft"
    private static let noneTag = "none"

    private var hub: RecordHub? { ParentCardDraftRules.hub(for: card, documentTypeKey: documentTypeKey) }

    /// Picker 选中值：草稿 / 未选（占位）/ 就诊 id / 体检 id（无候选清单，只作「不可用」行）。
    private var selection: String {
        switch card.encounterAssociation {
        case .newHub: return Self.draftTag
        case .unselected, .none: return Self.noneTag
        case .existing(let id), .suggested(let id, _): return id.uuidString
        case .existingHub(let hub, let id): return hub == .healthExam ? "hub:" + id.uuidString : id.uuidString
        }
    }

    private func select(_ tag: String) {
        guard !readOnly else { return }
        if tag == Self.draftTag {
            card.encounterAssociation = ParentCardDraftRules.deriveHub(from: card, documentTypeKey: documentTypeKey).map(EncounterAssociation.newHub) ?? .none
        } else if tag == Self.noneTag {
            // 有枢纽卡类的「请选择」占位只是回到未选择（识别出的子卡永远有父，不提供「不关联」）；无枢纽卡类 = 显式不关联
            card.encounterAssociation = hub == nil ? .none : .unselected
        } else if let id = UUID(uuidString: tag) {
            card.encounterAssociation = .existing(id)
        }
    }

    var body: some View {
        WithPerceptionTracking {
            Section {
                Picker(L10n.ocrAssociatedEncounter, selection: Binding<String>(get: { selection }, set: { select($0) })) {
                    if let hub {
                        if selection == Self.noneTag {
                            Text(L10n.entityCardPickValue).tag(Self.noneTag)
                        }
                        Text(hub == .healthExam ? L10n.parentDraftNewHealthExam : L10n.parentDraftNewEncounter).tag(Self.draftTag)
                    } else {
                        Text(card.kind == "encounter" ? L10n.encounterAdd : L10n.ocrUnlinked).tag(Self.noneTag)
                    }
                    ForEach(candidates) { candidate in
                        Text((candidate.hospital ?? L10n.encounterUntitled) + " · " + candidate.date.formatted(date: .abbreviated, time: .omitted))
                            .tag(candidate.id.uuidString)
                    }
                    if selection != Self.draftTag, selection != Self.noneTag, !candidates.contains(where: { $0.id.uuidString == selection }) {
                        Text(L10n.ocrAssociationUnavailable).tag(selection)
                    }
                }
                .accessibilityIdentifier("SP-12.entity.encounter")
                if case .suggested = card.encounterAssociation { Text(L10n.ocrAssociationSuggestion).font(.caption).foregroundStyle(.orange) }
                if loading { ProgressView() }
                if failed {
                    Text(L10n.ocrAssociationUnavailable).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.retry) { Task { await load() } }
                }
            } header: { Text(L10n.ocrAssociatedEncounter) } footer: { Text(L10n.ocrAssociationHint) }
            .disabled(readOnly)
            .task(id: "\(readOnly)-" + EncounterResolver.evidenceKey(for: card)) { await load() }
        }
    }

    private func load() async {
        guard !readOnly else { return }
        let id = card.id, evidence = EncounterResolver.evidenceKey(for: card)
        loading = true; failed = false
        defer { loading = false }
        do {
            let values = try await docs.encounterCandidates(patientId: patientId)
            guard !Task.isCancelled, !readOnly, card.id == id, EncounterResolver.evidenceKey(for: card) == evidence else { return }
            candidates = values
            // 只在「未选择」时裁决默认值：用户显式选择（含「改为选择已有主卡」后的未选择态，本 task 不重跑）优先
            guard card.encounterAssociation == .unselected else { return }
            card.encounterAssociation = ParentCardDraftRules.association(for: card, documentTypeKey: documentTypeKey,
                                                                          patientId: patientId, candidates: values)
        } catch { if !Task.isCancelled { failed = true } }
    }
}
