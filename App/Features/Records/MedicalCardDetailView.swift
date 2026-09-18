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
    /// 多项目处方单默认折叠（业主 2026-09-17 定，同时间轴主卡口径）
    @State private var linesExpanded = false

    var body: some View {
        WithPerceptionTracking {
            List {
                if let detail {
                    Section {
                        OCRReviewOwnerRow(patientId: patientId)
                        GradeBadge(grade: "C")
                        ForEach(Array(headerFields(from: detail).enumerated()), id: \.offset) { _, field in
                            LabeledContent(DocumentsDisplay.fieldLabel(forKey: field.key),
                                           value: DocumentsDisplay.fieldValueDisplay(forKey: field.key, value: field.value))
                        }
                    }
                    if kind == "prescription" {
                        // v25（§C.6）：药品行是 prescription_line 事实行（用户逐行确认过的 C 级数据），
                        // 不再从 advice_text 自由文本猜拆（BR-003：回填/展示只认回执与事实表）。
                        Section(L10n.prescriptionLineSection) {
                            if detail.lines.isEmpty {
                                Text(L10n.prescriptionLineNone).font(.caption).foregroundStyle(.secondary)
                            } else if detail.lines.count == 1, let line = detail.lines.first {
                                prescriptionLineLink(line, index: 0)
                            } else {
                                // 业主 2026-09-17 定：多项目处方单默认折叠（同时间轴主卡口径）；
                                // 单行处方保持平铺（无折叠价值）。
                                DisclosureGroup(isExpanded: $linesExpanded) {
                                    ForEach(Array(detail.lines.enumerated()), id: \.element.id) { index, line in
                                        prescriptionLineLink(line, index: index)
                                    }
                                } label: {
                                    Label(L10n.prescriptionLineCount(detail.lines.count), systemImage: "pills")
                                }
                            }
                        }
                        if let advice = detail.fields.first(where: { $0.key == "advice_text" })?.value {
                            // 共享医嘱原文整段呈现（原文保真），不得冒充药品行。
                            Section(DocumentsDisplay.fieldLabel(forKey: "advice_text")) {
                                Text(advice).font(.callout).textSelection(.enabled)
                            }
                        }
                    }
                    // v26（§C.2–§C.5）：叙事列原文分段（住院期 / 检查所见与意见）、同卡诊断清单、检验报告数值 + 定性行。
                    // 一律报告原文呈现——不摘要、不着色、不解释异常标记（BR-004/012）。
                    ForEach(narrativeSections(from: detail), id: \.key) { block in
                        Section(DocumentsDisplay.fieldLabel(forKey: block.key)) {
                            Text(block.value).font(.callout).textSelection(.enabled)
                                .accessibilityIdentifier("SP-08.\(kind).narrative.\(block.key)")
                        }
                    }
                    if !detail.diagnoses.isEmpty {
                        Section(L10n.encounterSectionDiagnoses) {
                            ForEach(Array(detail.diagnoses.enumerated()), id: \.element.id) { index, diagnosis in
                                DiagnosisRow(diagnosis: diagnosis, index: index)
                                    .accessibilityIdentifier("SP-08.diagnosis.row.\(index)")
                            }
                        }
                    }
                    // v27（子项目 J）：同父结论清单（kind = clinical_conclusion）——类型胶囊 + 原文 + severity_text 纯文本
                    //（打印原文，不编码、不排序、不着色，BR-004/012）。
                    if !detail.clinicalConclusions.isEmpty {
                        Section(L10n.healthExamConclusions) {
                            ForEach(Array(detail.clinicalConclusions.enumerated()), id: \.element.id) { index, conclusion in
                                ClinicalConclusionRow(conclusion: conclusion, highlighted: conclusion.id == entityId)
                                    .accessibilityIdentifier("SP-08.conclusion.row.\(index)")
                            }
                        }
                    }
                    // v27：体检表头卡 → 完整读面（表头 → 一般检查原文 → 子报告 → 结论 → 原件）走专用路由
                    if kind == "health_exam" {
                        Section {
                            NavigationLink(value: AppRoute.healthExamDetail(patientId: patientId, id: entityId)) {
                                Label(L10n.healthExamTitle, systemImage: CardKindIcon.symbol(cardKind: "health_exam"))
                                    .frame(minHeight: 44)
                            }
                            .accessibilityIdentifier("SP-08.healthExam.open")
                        }
                    }
                    if let lab = detail.labReport {
                        LabReportSections(lab: lab, highlighted: kind == "metric_sample" ? entityId : nil)
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

    /// 处方行链接（多项目折叠的单行出口；单行处方平铺时同用）。
    private func prescriptionLineLink(_ line: PrescriptionLine, index: Int) -> some View {
        NavigationLink(value: AppRoute.prescriptionLine(patientId: patientId, lineId: line.id)) {
            PrescriptionLineRow(line: line, index: index)
        }
        .accessibilityIdentifier("SP-08.prescription.line.\(index)")
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

    /// v26 叙事列（原文整段分段呈现，不进头部 LabeledContent）：住院期 §C.2 七段 / 检查报告 §C.4 两段。
    /// v27（子项目 J · 原 D3 §C.8/§C.9 / round1 §E.1）：手术八段 / 治疗六段 / 体检两段（总检结论、健康指导）——一律原文，不解读。
    private static let narrativeKeys: [String: [String]] = [
        "hospitalization": ["admit_diagnosis", "discharge_diagnosis", "admit_condition", "treatment_course",
                            "discharge_condition", "discharge_orders", "take_home_drugs"],
        "exam_report": ["findings", "impression"],
        "surgery": ["preop_diagnosis", "postop_diagnosis", "procedure_course", "intraop_findings",
                    "implants", "specimen", "postop_orders", "complications"],
        "treatment_record": ["diagnosis_text", "content", "drugs_text", "adverse_reaction", "result", "note"],
        "health_exam": ["overall_conclusion", "health_guidance"],
    ]

    private func headerFields(from detail: OCRCardStore.CardDetail) -> [FieldDraft] {
        if kind == "prescription" {
            // 处方卡只将医院、医生等元信息放在头部，药品明细（prescription_line）与医嘱原文各有专门 Section
            return detail.fields.filter { $0.key != "advice_text" }
        }
        if let narrative = Self.narrativeKeys[kind] {
            return detail.fields.filter { !narrative.contains($0.key) }
        }
        if kind == "diagnosis" {
            // 诊断卡：清单分段承载逐条诊断（名称/类型/编码），头部只留日期等共享面
            return detail.fields.filter { !["name", "code_text", "code_system", "diagnosis_type", "note"].contains($0.key) }
        }
        if kind == "clinical_conclusion" {
            // 结论卡：逐条结论（类型/原文/程度原文）由清单分段承载，头部只留机构/日期/编号共享面
            return detail.fields.filter { !["content", "conclusion_type", "severity"].contains($0.key) }
        }
        return detail.fields
    }

    /// 非空叙事列（键序 = 文书阅读序），值为已确认原文。
    private func narrativeSections(from detail: OCRCardStore.CardDetail) -> [(key: String, value: String)] {
        guard let keys = Self.narrativeKeys[kind] else { return [] }
        return keys.compactMap { key -> (key: String, value: String)? in
            guard let value = detail.fields.first(where: { $0.key == key })?.value.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return (key: key, value: value)
        }
    }
}

/// 诊断行（§C.3）：名称原文 + 类型（canonical raw 经展示层映射）+ 打印编码；不猜码、不接码表。
private struct DiagnosisRow: View {
    let diagnosis: Diagnosis
    let index: Int

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(diagnosis.name).font(.body.bold())
                    Spacer()
                    Text(DocumentsDisplay.fieldValueDisplay(forKey: "diagnosis_type", value: diagnosis.diagnosisType))
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color("brand-primary", bundle: .main).opacity(0.12)))
                        .foregroundStyle(Color("brand-primary", bundle: .main))
                }
                let meta = DiagnosisRow.meta(diagnosis)
                if !meta.isEmpty {
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                }
                if let note = diagnosis.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// 编码原文（体系 + 码）与诊断日期，空项省略。
    static func meta(_ diagnosis: Diagnosis) -> String {
        var parts: [String] = []
        if let code = diagnosis.codeText, !code.isEmpty {
            parts.append([diagnosis.codeSystemText, code].compactMap { $0 }.joined(separator: " "))
        }
        if let date = diagnosis.diagnosedAt {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }
}

/// 结论行（v27 §E.1 / 融合方案 §六-6.3）：类型胶囊（canonical raw → 类型名）+ 内容原文 + `severity_text` 原文。
/// 程度只作纯文本呈现——不编码、不排序、不着色（BR-004/012）；`highlighted` = 从该条实体进入时加粗。
struct ClinicalConclusionRow: View {
    let conclusion: ClinicalConclusion
    var highlighted = false

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text(L10n.conclusionTypeName(conclusion.conclusionType))
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color("brand-primary", bundle: .main).opacity(0.12)))
                        .foregroundStyle(Color("brand-primary", bundle: .main))
                    Spacer()
                    if let severity = conclusion.severityText?.trimmingCharacters(in: .whitespacesAndNewlines), !severity.isEmpty {
                        Text(DocumentsDisplay.fieldLabel(forKey: "severity") + ": " + severity)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(conclusion.content)
                    .font(highlighted ? .body.bold() : .body)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
        }
    }
}

/// 检验报告分段（§C.5）：数值项目（metric_sample）+ 定性项目（lab_result）。结果 / 参考范围 / 打印标记一律原文，
/// 不着色、不换算、不解释（BR-004/012）；`highlighted` = 从单个趋势点进入时标出该行。
/// 业主 2026-09-17 定：数值/定性分段**默认折叠**（同时间轴主卡口径），计数入标签；
/// 逐项符号经 `CardKindIcon.symbol(labItem:)`（酶类 = molecule、检查项 = 影像符号、常规 = 试管）。
private struct LabReportSections: View {
    let lab: OCRCardStore.LabReportDetail
    let highlighted: UUID?
    @State private var samplesExpanded = false
    @State private var resultsExpanded = false

    var body: some View {
        WithPerceptionTracking {
            if lab.samples.isEmpty && lab.results.isEmpty {
                Section(L10n.labReportSamplesSection) {
                    Text(L10n.labReportNoRows).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if !lab.samples.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $samplesExpanded) {
                            ForEach(Array(lab.samples.enumerated()), id: \.element.id) { index, sample in
                                LabSampleRowView(sample: sample, highlighted: sample.id == highlighted)
                                    .accessibilityIdentifier("SP-08.labReport.sample.\(index)")
                            }
                        } label: {
                            Label(L10n.labReportSamplesCount(lab.samples.count), systemImage: "testtube.2")
                        }
                    }
                }
                if !lab.results.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $resultsExpanded) {
                            ForEach(Array(lab.results.enumerated()), id: \.element.id) { index, result in
                                LabResultRowView(result: result)
                                    .accessibilityIdentifier("SP-08.labReport.result.\(index)")
                            }
                        } label: {
                            Label(L10n.labReportResultsCount(lab.results.count), systemImage: "list.bullet.clipboard")
                        }
                    }
                }
            }
        }
    }
}

private struct LabSampleRowView: View {
    let sample: OCRCardStore.LabSampleRow
    let highlighted: Bool

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    // 逐项符号（业主 2026-09-17 定）：酶类/检查项/常规检验经图标单一出口
                    Image(systemName: CardKindIcon.symbol(labItem: LabItemRules.classify(label: sample.rawLabel)))
                        .font(.subheadline)
                        .foregroundStyle(Color("text-secondary", bundle: .main))
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(sample.rawLabel).font(highlighted ? .body.bold() : .body)
                    Spacer()
                    Text(LabSampleRowView.valueText(sample)).font(.body)
                }
                let meta = LabSampleRowView.meta(sample)
                if !meta.isEmpty {
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// 数值 + 单位（原文单位，不换算）；打印标记原样附在数值之后（不着色、不解释）。
    /// 数值形态走 Domain `MedicalNumberFormat.oneDecimal` 单一出口（与趋势页同口径，
    /// 可见文本与 VoiceOver 不得念出两种数）。
    static func valueText(_ sample: OCRCardStore.LabSampleRow) -> String {
        var text = MedicalNumberFormat.oneDecimal(sample.value) + " " + sample.unit
        if let flag = sample.abnormalFlag, !flag.isEmpty { text += " " + flag }
        return text
    }

    /// 报告自带参考范围（A 级，原样）。
    static func meta(_ sample: OCRCardStore.LabSampleRow) -> String {
        guard sample.refLow != nil || sample.refHigh != nil else { return "" }
        let low = sample.refLow.map { MedicalNumberFormat.oneDecimal($0) } ?? ""
        let high = sample.refHigh.map { MedicalNumberFormat.oneDecimal($0) } ?? ""
        return DocumentsDisplay.fieldLabel(forKey: "reference_range") + ": " + low + " - " + high
    }
}

private struct LabResultRowView: View {
    let result: LabResult

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    // 逐项符号（业主 2026-09-17 定）：酶类/检查项/常规检验经图标单一出口
                    Image(systemName: CardKindIcon.symbol(labItem: LabItemRules.classify(label: result.itemName)))
                        .font(.subheadline)
                        .foregroundStyle(Color("text-secondary", bundle: .main))
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(result.itemName).font(.body)
                    Spacer()
                    Text(LabResultRowView.valueText(result)).font(.body)
                }
                let meta = LabResultRowView.meta(result)
                if !meta.isEmpty {
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// 定性结果原文 + 单位 + 打印标记（原样拼接，零解释）。
    static func valueText(_ result: LabResult) -> String {
        [result.resultText, result.unit, result.abnormalFlag].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 参考范围原文 / 方法（打印文本）。
    static func meta(_ result: LabResult) -> String {
        var parts: [String] = []
        if let reference = result.referenceText, !reference.isEmpty {
            parts.append(DocumentsDisplay.fieldLabel(forKey: "reference_text") + ": " + reference)
        }
        if let method = result.method, !method.isEmpty {
            parts.append(DocumentsDisplay.fieldLabel(forKey: "method") + ": " + method)
        }
        return parts.joined(separator: " · ")
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
                    Image(systemName: CardKindIcon.symbol(cardKind: "prescription"))
                        .foregroundStyle(CardKindIcon.tint(cardKind: "prescription"))
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
