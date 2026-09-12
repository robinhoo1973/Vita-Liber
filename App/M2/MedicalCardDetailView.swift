import SwiftUI
import Domain
import Infrastructure

/// FR4.2/FR6.9：从就诊和原件进入同一个已确认卡详情；原图仍走原有敏感媒体认证。
struct MedicalCardDetailView: View {
    let kind: String
    let entityId: UUID
    let patientId: UUID
    @Environment(DocumentsState.self) private var docs
    @State private var detail: OCRCardStore.CardDetail?
    @State private var candidates: [EncounterResolver.Candidate] = []
    @State private var selectedEncounter: UUID?
    @State private var source: OCRCardStore.SourcePage?
    @State private var failed = false
    @State private var associationFailed = false
    @State private var saving = false

    var body: some View {
        List {
            if let detail {
                Section {
                    OCRReviewOwnerRow(patientId: patientId)
                    GradeBadge(grade: "C")
                    ForEach(Array(headerFields(from: detail).enumerated()), id: \.offset) { _, field in
                        LabeledContent(DocumentsState.fieldLabel(forKey: field.key),
                                       value: DocumentsState.fieldValueDisplay(forKey: field.key, value: field.value))
                    }
                }
                if kind == "prescription", let advice = detail.fields.first(where: { $0.key == "advice_text" })?.value {
                    let parsed = prescriptionLines(from: advice)
                    if !parsed.drugs.isEmpty {
                        Section(L10n.prescriptionFieldDrugName) {
                            ForEach(Array(parsed.drugs.enumerated()), id: \.offset) { index, line in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "pills.fill")
                                            .foregroundStyle(Color("brand-primary", bundle: .main))
                                        Text(line.name)
                                            .font(.body.bold())
                                        Spacer()
                                        Text(L10n.entityCardRowIndex(index + 1))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if !line.details.isEmpty {
                                        Text(line.details)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                                .accessibilityIdentifier("medicalCard.prescription.row.\(index)")
                            }
                        }
                    }
                    if !parsed.notes.isEmpty {
                        // 自由文本医嘱不得冒充药品行——按医嘱字段标签单独呈现。
                        Section(DocumentsState.fieldLabel(forKey: "advice_text")) {
                            ForEach(Array(parsed.notes.enumerated()), id: \.offset) { _, note in
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 2)
                            }
                        }
                    }
                }
                Section(L10n.ocrAssociatedEncounter) {
                    if detail.encounterIDs.isEmpty { Text(L10n.ocrUnlinked).foregroundStyle(.secondary) }
                    ForEach(detail.encounterIDs, id: \.self) { id in
                        NavigationLink(value: AppRoute.encounterDetail(id)) {
                            Text(encounterTitle(id))
                        }
                    }
                    if detail.relationshipEditable {
                        Picker(L10n.ocrAssociatedEncounter, selection: $selectedEncounter) {
                            Text(L10n.ocrUnlinked).tag(Optional<UUID>.none)
                            ForEach(candidates) { candidate in
                                Text(encounterTitle(candidate.id)).tag(Optional(candidate.id))
                            }
                        }
                        Button(L10n.commonSave) { saveAssociation() }.disabled(saving)
                            .accessibilityIdentifier("medicalCard.association.save")
                        if associationFailed {
                            Text(L10n.ocrAssociationUnavailable).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Section(L10n.pendingCardViewSource) {
                    ForEach(detail.sources) { page in
                        Button {
                            source = page
                        } label: {
                            Label((page.title ?? L10n.docUntitled) + " · " + L10n.entityCardRowIndex(page.pageIndex + 1), systemImage: "doc.text.magnifyingglass")
                        }.frame(minHeight: 44)
                    }
                }
            } else if !failed { ProgressView() }
            if failed {
                Text(L10n.docImportFailed).foregroundStyle(.orange)
                Button(L10n.retry) { Task { await load() } }
            }
        }
        .navigationTitle(L10n.entityCardKindName(kind))
        .task(id: entityId) { await load() }
        .sheet(item: $source) { page in
            DocumentSourcePageView(documentId: page.documentId, patientId: patientId, pageIndex: page.pageIndex)
        }
    }

    private func encounterTitle(_ id: UUID) -> String {
        guard let candidate = candidates.first(where: { $0.id == id }) else { return L10n.encounterDetailTitle }
        return (candidate.hospital ?? L10n.encounterUntitled) + " · " + candidate.date.formatted(date: .abbreviated, time: .omitted)
    }

    private func load() async {
        guard let store = docs.cardStore else { failed = true; return }
        // 审查修复（路由替换残留）：同一视图实例被复用为另一张卡（通知深链
        // 顶替栈顶）时，.task(id: entityId) 重跑前必须先清空旧卡投影——
        // 否则旧卡的字段/来源页在加载期间渲染在新卡标题下，加载失败时更会
        // 永久滞留。
        detail = nil; source = nil; associationFailed = false; failed = false
        do {
            let value = try await store.detail(kind: kind, entityId: entityId, patientId: patientId)
            let options = try await store.encounterCandidates(patientId: patientId)
            guard !Task.isCancelled else { return }
            detail = value; candidates = options; selectedEncounter = value.encounterIDs.first; failed = false
        } catch { if !Task.isCancelled { failed = true } }
    }

    private func saveAssociation() {
        guard let store = docs.cardStore, !saving else { return }
        let selected = selectedEncounter
        saving = true; associationFailed = false
        Task {
            defer { saving = false }
            do {
                try await store.associate(kind: kind, entityId: entityId, patientId: patientId, encounterId: selected)
                docs.pendingDidChange()
                await load()
            } catch {
                // 审查修复：关系保存冲突不得复用详情加载的 failed 通道——
                // 旧实现把 invalidAssociation/committedDataChanged 呈现为
                // 「导入失败」且重试按钮重载卡片（既不解说也不重试保存）。
                associationFailed = true
            }
        }
    }

    private func headerFields(from detail: OCRCardStore.CardDetail) -> [FieldDraft] {
        if kind == "prescription" {
            // 处方卡只将医院、医生等元信息放在头部，药品明细由专门的 Section 渲染
            return detail.fields.filter { $0.key != "advice_text" }
        }
        return detail.fields
    }

    private struct ParsedDrugLine {
        let name: String
        let details: String
    }

    /// 拆分提交的 advice_text：≥2 空格分段的行视为结构化药物行（「药名 规格/剂量…」），
    /// 其余（无空格的中文叙述，如「每日两次，饭后服用」）归为自由文本医嘱——
    /// 前者进药品名称节，后者按医嘱标签单独呈现，绝不互相冒充。
    private func prescriptionLines(from adviceText: String) -> (drugs: [ParsedDrugLine], notes: [String]) {
        var drugs: [ParsedDrugLine] = []
        var notes: [String] = []
        for line in adviceText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: " ")
            guard parts.count >= 2 else {
                notes.append(trimmed)
                continue
            }
            // 规格以括号包裹时药名可含空格（「阿莫西林 克拉维酸钾 (0.25g)…」）——
            // 以首个 "(" 切分，防多词药名截断。
            if let paren = trimmed.firstIndex(of: "(") {
                let name = String(trimmed[..<paren]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else {
                    notes.append(trimmed)
                    continue
                }
                drugs.append(ParsedDrugLine(name: name, details: String(trimmed[paren...])))
            } else {
                drugs.append(ParsedDrugLine(name: parts[0], details: parts.dropFirst().joined(separator: " ")))
            }
        }
        return (drugs, notes)
    }
}

/// 原件保留一个页级来源入口；关联卡和所属就诊都是事实读投影，零内容复制。
struct DocumentRelationsSection: View {
    let documentId: UUID
    let patientId: UUID
    @Environment(DocumentsState.self) private var docs
    @State private var cards: [CardReference] = []
    @State private var encounters: [UUID] = []
    @State private var failed = false
    private struct CardReference: Identifiable {
        let kind: String
        let entityId: UUID
        var id: String { kind + ":" + entityId.uuidString }
    }
    var body: some View {
        Section(L10n.encounterLinkedCards) {
            ForEach(encounters, id: \.self) { id in
                NavigationLink(L10n.encounterDetailTitle, value: AppRoute.encounterDetail(id))
            }
            ForEach(Array(Set(cards.map(\.kind))).sorted(), id: \.self) { kind in
                let group = cards.filter { $0.kind == kind }
                DisclosureGroup(L10n.entityCardKindName(kind) + " (\(group.count))") {
                    ForEach(Array(group.enumerated()), id: \.element.id) { index, card in
                        NavigationLink(L10n.entityCardRowIndex(index + 1),
                            value: AppRoute.medicalCard(kind: card.kind, id: card.entityId, patientId: patientId))
                    }
                }
            }
            if failed { Text(L10n.docImportFailed).foregroundStyle(.orange); Button(L10n.retry) { Task { await load() } } }
        }
        .task(id: documentId) { await load() }
    }
    private func load() async {
        guard let store = docs.cardStore else { return }
        do {
            let references = try await store.cards(documentId: documentId, patientId: patientId)
            let linked = try await store.associatedEncounters(documentId: documentId, patientId: patientId)
            guard !Task.isCancelled else { return }
            cards = references.map { CardReference(kind: $0.kind, entityId: $0.id) }
            encounters = linked; failed = false
        } catch { if !Task.isCancelled { failed = true } }
    }
}
