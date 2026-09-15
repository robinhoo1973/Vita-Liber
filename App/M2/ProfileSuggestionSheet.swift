import SwiftUI
import Domain
import Infrastructure
import Perception

// MARK: - 子项目 D · D4-2「资料建议」表单（SP-12 · recognition-remediation-design §0.3 需求 1 / BR-003）

/// 卡确认保存成功后弹出：列出识别内容可用于个人资料的 D 级建议（既往史 / 过敏 / 血型 / 慢性病），
/// 每条 **逐项** 接受 / 忽略、显示来源文档页；**无**「全部接受」、不预选、不自动写入——D → C 只经用户显式接受。
/// 过敏建议须用户选择严重度后方可接受（不占位、不推断）。接受后行变 C 级「已写入」；已有记录 → 「已有记录」。
/// 单一自适应视图（ADR-021），iOS 16 安全；`body` 顶层 `WithPerceptionTracking`。
struct ProfileSuggestionSheet: View {
    let batch: DocumentsState.ProfileSuggestionBatch
    @Environment(DocumentsState.self) private var docs
    @Environment(\.dismiss) private var dismiss

    private enum RowState: Equatable { case pending, busy, written, existing, skipped, failed }
    @State private var states: [UUID: RowState] = [:]
    /// 过敏严重度选择（展示词 轻/中/重；"" = 未选，接受按钮禁用）。
    @State private var severities: [UUID: String] = [:]
    @State private var sourceOf: ProfileSuggestion?
    @State private var skippingAll = false

    private func state(of suggestion: ProfileSuggestion) -> RowState { states[suggestion.id] ?? .pending }
    private var unhandled: [ProfileSuggestion] {
        batch.suggestions.filter { [.pending, .failed].contains(state(of: $0)) }
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                List {
                    Section {
                        ForEach(batch.suggestions) { suggestion in
                            // ForEach 行闭包逃逸：行内同步读感知对象属性，须自行包裹（子项目 I）
                            WithPerceptionTracking { row(suggestion) }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            GradeBadge(grade: "D")
                            Text(L10n.profileSuggestionHint)
                        }
                        .textCase(nil)
                    }
                }
                .navigationTitle(L10n.profileSuggestionTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        if unhandled.isEmpty {
                            Button(L10n.profileSuggestionDone) { dismiss() }
                                .accessibilityIdentifier("SP-12.suggestion.done")
                        } else {
                            Button(L10n.profileSuggestionSkipAll) { skipAll() }
                                .disabled(skippingAll)
                                .accessibilityIdentifier("SP-12.suggestion.skipAll")
                        }
                    }
                }
                .sheet(item: $sourceOf) { suggestion in
                    DocumentSourcePageView(documentId: suggestion.provenance.documentId ?? batch.documentId,
                                           patientId: batch.patientId, pageIndex: suggestion.provenance.pageIndex ?? 0)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("SP-12.suggestion.sheet")
        }
    }

    @ViewBuilder
    private func row(_ suggestion: ProfileSuggestion) -> some View {
        let rowState = state(of: suggestion)
        let actionable = rowState == .pending || rowState == .failed
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // 评审修正 U2：徽章唯一出口 GradeBadge；接受写入后才升 C
                GradeBadge(grade: rowState == .written ? "C" : "D")
                Text(L10n.profileSuggestionKindName(suggestion.kind.rawValue))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                statusLabel(rowState)
            }
            Text(suggestion.value).font(.body).textSelection(.enabled)
            if let code = suggestion.codeText, !code.isEmpty {
                Text([code, suggestion.codeSystemText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                sourceOf = suggestion
            } label: {
                Label(L10n.profileSuggestionSource((suggestion.provenance.pageIndex ?? 0) + 1), systemImage: "doc.text.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            .accessibilityIdentifier("SP-12.suggestion.source.\(suggestion.id.uuidString)")
            if suggestion.kind == .allergy, actionable {
                Picker(L10n.allergySeverityLabel, selection: severityBinding(suggestion.id)) {
                    Text(L10n.profileSuggestionSeverityUnset).tag("")
                    ForEach(SevereReactionRules.severityValues, id: \.self) { value in
                        Text(L10n.allergySeverity(value)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("SP-12.suggestion.severity.\(suggestion.id.uuidString)")
            }
            if actionable {
                HStack(spacing: 12) {
                    Button(L10n.profileSuggestionAccept) { accept(suggestion) }
                        .buttonStyle(.borderedProminent)
                        .disabled(suggestion.kind == .allergy && (severities[suggestion.id] ?? "").isEmpty)
                        .accessibilityIdentifier("SP-12.suggestion.accept.\(suggestion.id.uuidString)")
                    Button(L10n.profileSuggestionSkip) { skip(suggestion) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("SP-12.suggestion.skip.\(suggestion.id.uuidString)")
                }
                .frame(minHeight: 44)
                if rowState == .failed {
                    Text(L10n.profileSuggestionFailed).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
        .disabled(rowState == .busy || skippingAll)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SP-12.suggestion.row.\(suggestion.id.uuidString)")
    }

    @ViewBuilder
    private func statusLabel(_ state: RowState) -> some View {
        switch state {
        case .busy: ProgressView().controlSize(.small)
        case .written: Text(L10n.profileSuggestionApplied).font(.caption).foregroundStyle(.secondary)
        case .existing: Text(L10n.profileSuggestionExisting).font(.caption).foregroundStyle(.secondary)
        case .skipped: Text(L10n.profileSuggestionSkipped).font(.caption).foregroundStyle(.secondary)
        case .pending, .failed: EmptyView()
        }
    }

    private func severityBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { severities[id] ?? "" }, set: { severities[id] = $0 })
    }

    private func accept(_ suggestion: ProfileSuggestion) {
        let severity = severities[suggestion.id] ?? ""
        if suggestion.kind == .allergy, severity.isEmpty { return }   // 严重度只能由用户给出
        states[suggestion.id] = .busy
        Task {
            let outcome = await docs.acceptProfileSuggestion(suggestion, severity: suggestion.kind == .allergy ? severity : nil)
            switch outcome {
            case .written: states[suggestion.id] = .written
            case .skippedExisting: states[suggestion.id] = .existing
            case nil: states[suggestion.id] = .failed
            }
        }
    }

    private func skip(_ suggestion: ProfileSuggestion) {
        states[suggestion.id] = .busy
        Task {
            let ok = await docs.dismissProfileSuggestions([suggestion])
            states[suggestion.id] = ok ? .skipped : .failed
        }
    }

    /// 「全部跳过」= 持久忽略全部未处理项后关闭（无「全部接受」——逐项确认，BR-003）。
    private func skipAll() {
        let rest = unhandled
        guard !rest.isEmpty else { dismiss(); return }
        skippingAll = true
        for suggestion in rest { states[suggestion.id] = .busy }
        Task {
            let ok = await docs.dismissProfileSuggestions(rest)
            for suggestion in rest { states[suggestion.id] = ok ? .skipped : .failed }
            skippingAll = false
            if ok { dismiss() }
        }
    }
}

// MARK: - 宿主：只呈现本宿主键产出的批（导入会话 / 待办卡续办各一），关闭即清批

private struct ProfileSuggestionHost: ViewModifier {
    let presenterKey: String
    /// 宿主有其他弹层（alert）可见时暂不呈现，弹层关闭后再弹（避免同一层级并发呈现）。
    let enabled: Bool
    @Environment(DocumentsState.self) private var docs

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content.sheet(item: Binding(
                get: {
                    guard enabled, let batch = docs.profileSuggestionBatch, batch.presenterKey == presenterKey else { return nil }
                    return batch
                },
                set: { batch, _ in   // 新 SDK Binding.set 携带 (Value, Transaction)——第二参忽略
                    if batch == nil { docs.clearProfileSuggestions(presenterKey: presenterKey) }
                })) { batch in
                ProfileSuggestionSheet(batch: batch)
            }
        }
    }
}

extension View {
    func profileSuggestionHost(presenterKey: String, enabled: Bool = true) -> some View {
        modifier(ProfileSuggestionHost(presenterKey: presenterKey, enabled: enabled))
    }
}
