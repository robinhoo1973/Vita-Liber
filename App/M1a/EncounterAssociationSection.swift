import SwiftUI
import Domain
import Infrastructure

/// 建议只写入当前卡草稿；保存卡时才在同一事务验证成员并建立关系。
struct EncounterAssociationSection: View {
    @Binding var card: MatchedCard
    let patientId: UUID
    var readOnly = false
    @Environment(DocumentsState.self) private var docs
    @State private var candidates: [EncounterResolver.Candidate] = []
    @State private var failed = false
    @State private var loading = false

    var body: some View {
        Section {
            Picker(L10n.ocrAssociatedEncounter, selection: Binding<UUID?>(get: { card.encounterAssociation.encounterID }, set: {
                card.encounterAssociation = $0.map(EncounterAssociation.existing) ?? .none
            })) {
                Text(card.kind == "encounter" ? L10n.encounterAdd : L10n.ocrUnlinked).tag(Optional<UUID>.none)
                ForEach(candidates) { candidate in
                    Text((candidate.hospital ?? L10n.encounterUntitled) + " · " + candidate.date.formatted(date: .abbreviated, time: .omitted))
                        .tag(Optional(candidate.id))
                }
                if let id = card.encounterAssociation.encounterID, !candidates.contains(where: { $0.id == id }) {
                    Text(L10n.ocrAssociationUnavailable).tag(Optional(id))
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

    private func load() async {
        guard !readOnly else { return }
        let id = card.id, evidence = EncounterResolver.evidenceKey(for: card)
        loading = true; failed = false
        defer { loading = false }
        do {
            let values = try await docs.encounterCandidates(patientId: patientId)
            guard !Task.isCancelled, !readOnly, card.id == id, EncounterResolver.evidenceKey(for: card) == evidence else { return }
            candidates = values
            guard card.encounterAssociation == .unselected else { return }
            let context = EncounterResolver.context(for: card)
            if let match = EncounterResolver.suggest(date: context.date, hospital: context.hospital, doctor: context.doctor,
                                                    patientId: patientId, candidates: values) {
                card.encounterAssociation = .suggested(match, evidence: evidence)
            }
        } catch { if !Task.isCancelled { failed = true } }
    }
}
