import SwiftUI
import Domain
import Infrastructure
import Perception

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
        WithPerceptionTracking {
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
                    if kind == "prescription" {
                        // v25（§C.6）：药品行是 prescription_line 事实行（用户逐行确认过的 C 级数据），
                        // 不再从 advice_text 自由文本猜拆（BR-003：回填/展示只认回执与事实表）。
                        Section(L10n.prescriptionLineSection) {
                            if detail.lines.isEmpty {
                                Text(L10n.prescriptionLineNone).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(Array(detail.lines.enumerated()), id: \.element.id) { index, line in
                                NavigationLink(value: AppRoute.prescriptionLine(patientId: patientId, lineId: line.id)) {
                                    PrescriptionLineRow(line: line, index: index)
                                }
                                .accessibilityIdentifier("SP-08.prescription.line.\(index)")
                            }
                        }
                        if let advice = detail.fields.first(where: { $0.key == "advice_text" })?.value {
                            // 共享医嘱原文整段呈现（原文保真），不得冒充药品行。
                            Section(DocumentsState.fieldLabel(forKey: "advice_text")) {
                                Text(advice).font(.callout).textSelection(.enabled)
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
            // 处方卡只将医院、医生等元信息放在头部，药品明细（prescription_line）与医嘱原文各有专门 Section
            return detail.fields.filter { $0.key != "advice_text" }
        }
        return detail.fields
    }
}

/// 处方行列表摘要（SP-08 处方卡内）：药名 + 原文摘要（规格/剂量/数量/频次/途径/疗程按原文 + 单位拼接，
/// 零解析零换算，BR-006/007）；备注另起一行。字段目录与 `PrescriptionLinePresentation` 同源。
private struct PrescriptionLineRow: View {
    let line: PrescriptionLine
    let index: Int

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "pills.fill")
                        .foregroundStyle(Color("brand-primary", bundle: .main))
                    Text(line.printedName)
                        .font(.body.bold())
                    Spacer()
                    Text(L10n.entityCardRowIndex(index + 1))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                let summary = PrescriptionLinePresentation.summary(line)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let notes = PrescriptionLinePresentation.notes(line) {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
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
        WithPerceptionTracking {
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
