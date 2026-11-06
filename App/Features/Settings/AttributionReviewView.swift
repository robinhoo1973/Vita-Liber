import Foundation
import SwiftUI
import Domain
import Infrastructure
import Perception

/// 孤儿卡/文档批量归属（2026-11-06 三轮/红队结论）：逐条确认，无全选；
/// 关联只写现有 FK，忽略写 `notification_state`；不自动关联、不建关系表。
struct AttributionReviewView: View {
    @Environment(AppState.self) private var app
    @Environment(\.attributionReview) private var service
    @State private var suggestions: [AttributionSuggestion] = []
    @State private var loading = false
    @State private var error: String?
    @State private var actingID: String?

    var body: some View {
        WithPerceptionTracking {
            Form {
                if let error {
                    Section {
                        Text(error).foregroundStyle(.secondary)
                        Button(L10n.retry) { Task { await load() } }
                            .frame(minHeight: 44)
                    }
                } else if loading && suggestions.isEmpty {
                    Section { ProgressView() }
                } else if suggestions.isEmpty {
                    Section { Text(L10n.attributionReviewEmpty).foregroundStyle(.secondary) }
                } else {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        suggestionSection(suggestion, index: index)
                    }
                }
            }
            .navigationTitle(L10n.attributionReviewTitle)
            .task(id: app.currentPatientId) { await load() }
        }
    }

    private func suggestionSection(_ suggestion: AttributionSuggestion, index: Int) -> some View {
        Section {
            LabeledContent(L10n.attributionReviewSource, value: sourceText(suggestion.orphan))
            LabeledContent(L10n.attributionReviewTarget, value: targetText(suggestion.evidence))
            LabeledContent(L10n.attributionReviewEvidence, value: evidenceText(suggestion.evidence))
            HStack(spacing: 12) {
                Button(L10n.attributionReviewLink) {
                    Task { await link(suggestion) }
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .disabled(actingID != nil)
                .accessibilityIdentifier("SP-65.attribution.link.\(index)")
                Button(L10n.attributionReviewDismiss) {
                    Task { await dismiss(suggestion) }
                }
                .frame(minHeight: 44)
                .disabled(actingID != nil)
                .accessibilityIdentifier("SP-65.attribution.dismiss.\(index)")
            }
        } footer: {
            Text(L10n.attributionReviewHint)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SP-65.attribution.row.\(index)")
    }

    private func load() async {
        guard let service else {
            error = L10n.attributionReviewFailed
            return
        }
        loading = true
        error = nil
        defer { loading = false }
        do {
            suggestions = try await service.suggestions(patientId: app.currentPatientId)
        } catch {
            self.error = L10n.attributionReviewFailed
        }
    }

    private func link(_ suggestion: AttributionSuggestion) async {
        guard let service else { return }
        actingID = suggestion.id
        defer { actingID = nil }
        do {
            try await service.link(suggestion)
            suggestions.removeAll { $0.id == suggestion.id }
        } catch {
            self.error = L10n.attributionReviewFailed
        }
    }

    private func dismiss(_ suggestion: AttributionSuggestion) async {
        guard let service else { return }
        actingID = suggestion.id
        defer { actingID = nil }
        do {
            try await service.dismiss(suggestion)
            suggestions.removeAll { $0.id == suggestion.id }
        } catch {
            self.error = L10n.attributionReviewFailed
        }
    }

    private func sourceText(_ orphan: OrphanCard) -> String {
        [kindName(orphan.kind), orphan.hospital, dateText(orphan.date)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func targetText(_ evidence: [String: String]) -> String {
        let date = evidence["date"].flatMap { ISO8601DateFormatter().date(from: $0) }
        return [evidence["hospital"], kindName(evidence["kind"] ?? ""), dateText(date)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func evidenceText(_ evidence: [String: String]) -> String {
        ["hospital", "department", "doctor"].compactMap { key in
            evidence[key].map { "\(DocumentsDisplay.fieldLabel(forKey: key)): \($0)" }
        }.joined(separator: " · ")
    }

    private func kindName(_ kind: String) -> String {
        let entry: TimelineEntryKind?
        switch kind {
        case "prescription": entry = .prescription
        case "metric_sample": entry = .labReport
        case "exam_report": entry = .examReport
        case "surgery": entry = .surgery
        case "treatment_record": entry = .treatmentRecord
        default: entry = nil
        }
        return entry.map(L10n.timelineKindName) ?? kind
    }

    private func dateText(_ date: Date?) -> String? {
        date?.formatted(date: .abbreviated, time: .omitted)
    }
}
