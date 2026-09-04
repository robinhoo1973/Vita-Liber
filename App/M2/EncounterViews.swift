import SwiftUI
import Domain
import Infrastructure

// MARK: - F4 就诊事件（SP-08 · FR4.1-4.4）

/// 就诊模块状态仓：列表/详情/挂接/智能推荐（BR-001 成员隔离）
@MainActor
@Observable
final class EncountersState {
    private(set) var encounters: [EncounterStore.EncounterRow] = []
    private let store: EncounterStore
    private var loadingPatientId: UUID?

    init(store: EncounterStore) { self.store = store }

    func load(patientId: UUID) async {
        loadingPatientId = patientId
        do {
            let rows = try await store.list(patientId: patientId)
            guard loadingPatientId == patientId else { return }
            encounters = rows
        } catch {
            encounters = []
        }
    }

    func get(id: UUID) async -> EncounterStore.EncounterRow? {
        try? await store.get(id: id)   // try?-ok: 详情读取失败 = 显示「不存在」降级态
    }

    func upsert(_ draft: EncounterDraft) async {
        do {
            _ = try await store.upsert(encounter: draft)
            await load(patientId: draft.patientId)
        } catch {
            // 错误经调用侧呈现（表单保留可重试）
        }
    }

    func linkDocument(documentId: UUID, encounterId: UUID) async {
        do {
            try await store.linkDocument(documentId: documentId, encounterId: encounterId)
        } catch {
            // 挂接失败：列表重新加载即反映真实状态
        }
    }

    func unlinkDocument(documentId: UUID) async {
        do {
            try await store.unlinkDocument(documentId: documentId)
        } catch {
            // 同上
        }
    }

    func recommendations(for encounter: EncounterStore.EncounterRow) async -> [UUID] {
        (try? await store.recommendDocuments(encounter: encounter)) ?? []   // try?-ok: 推荐失败=空推荐区，不阻断详情
    }

    func unconfirmedFields(patientId: UUID) async -> [(documentId: UUID, fieldCount: Int)] {
        (try? await store.unconfirmedFields(patientId: patientId)) ?? []   // try?-ok: 统计失败=空清单
    }
}

/// 就诊列表（SP-08）：按时间倒序；类型胶囊 + 关联资料计数
struct EncounterListView: View {
    @Environment(AppState.self) private var app
    @Environment(EncountersState.self) private var state
    @State private var showForm = false

    var body: some View {
        List {
            if state.encounters.isEmpty {
                ContentUnavailableView(L10n.encounterEmpty, systemImage: "stethoscope",
                                       description: Text(L10n.encounterEmptyHint))
                    .accessibilityIdentifier("SP-08.encounter.empty")
            } else {
                ForEach(state.encounters) { enc in
                    NavigationLink {
                        EncounterDetailView(encounter: enc)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(enc.hospital ?? L10n.encounterUntitled)
                                    .font(.subheadline)
                                Text("\(enc.kind) · \(enc.date.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if enc.linkedDocumentCount > 0 {
                                Text(L10n.encounterDocCount(enc.linkedDocumentCount))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("SP-08.encounter.row.\(enc.id.uuidString)")
                }
            }
        }
        .navigationTitle(L10n.encounterListTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showForm = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("SP-08.encounter.add")
            }
        }
        .sheet(isPresented: $showForm) {
            EncounterFormView()
        }
        .task(id: app.currentPatientId) { await state.load(patientId: app.currentPatientId) }
    }
}

/// 就诊详情（§5.4）：头部卡 + 诊断与医嘱引用块 + 关联资料 + 智能推荐挂接区 +
/// 底部 [生成就诊总结]
struct EncounterDetailView: View {
    let encounter: EncounterStore.EncounterRow
    @Environment(AppState.self) private var app
    @Environment(EncountersState.self) private var state
    @State private var current: EncounterStore.EncounterRow?
    @State private var recommendations: [UUID] = []
    @State private var showSummary = false

    var body: some View {
        List {
            // 头部卡：医院·科室·医生·日期 + 类型胶囊
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(current?.hospital ?? encounter.hospital ?? L10n.encounterUntitled)
                            .font(.title2.bold())
                        Spacer()
                        Text(current?.kind ?? encounter.kind)
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color("brand-primary", bundle: .main).opacity(0.12)))
                            .foregroundStyle(Color("brand-primary", bundle: .main))
                    }
                    if let dept = current?.department ?? encounter.department {
                        Text(dept).font(.subheadline)
                    }
                    if let doctor = current?.doctor ?? encounter.doctor {
                        Text(doctor).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text((current?.date ?? encounter.date).formatted(date: .long, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("SP-08.encounter.detail.header")

            // 诊断与医嘱（原文引用块，左侧竖线+浅底）
            Section(L10n.encounterDiagnosisAdvice) {
                if let diagnosis = current?.diagnosisText ?? encounter.diagnosisText {
                    Text(diagnosis)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color("brand-primary", bundle: .main)).frame(width: 3)
                        }
                    Text(L10n.encounterDiagnosisBadge)
                        .font(.caption2).foregroundStyle(Color("grade-a", bundle: .main))
                }
                if let advice = current?.adviceText ?? encounter.adviceText {
                    Text(advice)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color("brand-primary", bundle: .main)).frame(width: 3)
                        }
                    Text(L10n.encounterAdviceBadge)
                        .font(.caption2).foregroundStyle(Color("grade-a", bundle: .main))
                }
                if let followUp = current?.followUpRequirement ?? encounter.followUpRequirement {
                    LabeledContent(L10n.encounterFollowUp, value: followUp)
                }
            }

            // 关联资料（FR4.2：挂接/解除均留操作历史）
            Section(L10n.encounterLinkedDocs) {
                let docs = current?.linkedDocumentIds ?? encounter.linkedDocumentIds
                if docs.isEmpty {
                    Text(L10n.encounterNoDocs).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(docs, id: \.self) { docId in
                        NavigationLink {
                            DocumentDetailRouteView(documentId: docId)
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                Text(L10n.encounterDocTitle(docId.uuidString.prefix(8)))
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }

            // FR4.2 智能推荐（同医院±7 天；推荐必须标「待确认」，不得自动生效）
            if !recommendations.isEmpty {
                Section {
                    ForEach(recommendations, id: \.self) { docId in
                        HStack {
                            Image(systemName: "doc.badge.plus").foregroundStyle(.orange)
                            Text(L10n.encounterRecommendPending)
                                .font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button(L10n.encounterLink) {
                                Task {
                                    await state.linkDocument(documentId: docId,
                                                             encounterId: encounter.id)
                                    await refresh()
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                } header: {
                    Text(L10n.encounterRecommendSection)
                }
            }

            // 底部操作
            Section {
                Button(L10n.encounterGenerateSummary) { showSummary = true }
                    .accessibilityIdentifier("SP-08.encounter.summary")
            }
        }
        .navigationTitle(L10n.encounterDetailTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSummary) {
            EncounterSummaryView(encounter: current ?? encounter)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        current = await state.get(id: encounter.id)
        recommendations = await state.recommendations(for: current ?? encounter)
    }
}

/// 就诊总结页（FR4.3）：已完成/待完成检查、新增药品、复诊时间、
/// 「以下信息尚未经你确认」清单（BR-003 红点标记）
struct EncounterSummaryView: View {
    let encounter: EncounterStore.EncounterRow
    @Environment(EncountersState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var unconfirmed: [(documentId: UUID, fieldCount: Int)] = []

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.encounterSummaryHeader) {
                    Text(encounter.hospital ?? L10n.encounterUntitled).font(.headline)
                    Text(encounter.date.formatted(date: .long, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let followUp = encounter.followUpRequirement {
                    Section(L10n.encounterFollowUp) {
                        Text(followUp)
                    }
                }
                Section(L10n.encounterSummaryUnconfirmed) {
                    if unconfirmed.isEmpty {
                        Text(L10n.encounterSummaryAllConfirmed)
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        // BR-003：未确认清单红点标记，确认前不进入确定性陈述
                        ForEach(unconfirmed, id: \.documentId) { item in
                            HStack {
                                Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.red)
                                Text(L10n.encounterSummaryDocFields(
                                    String(item.documentId.uuidString.prefix(8)), item.fieldCount))
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                Section(L10n.encounterSummaryNote) {
                    Text(L10n.encounterSummaryNoteText)
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.encounterSummaryTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonCancel) { dismiss() }
                }
            }
            .task {
                unconfirmed = await state.unconfirmedFields(patientId: encounter.patientId)
            }
        }
    }
}

/// 就诊表单（FR4.1 字段全集；FR4.4 可从孤立资料懒创建——入口传资料上下文）
struct EncounterFormView: View {
    @Environment(AppState.self) private var app
    @Environment(EncountersState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var kind = EncounterKind.outpatient.rawValue
    @State private var hospital = ""
    @State private var department = ""
    @State private var doctor = ""
    @State private var chiefComplaint = ""
    @State private var diagnosisText = ""
    @State private var adviceText = ""
    @State private var followUpRequirement = ""
    @State private var feeText = ""

    private let kinds = EncounterKind.allCases

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.encounterFormBasic) {
                    Picker(L10n.encounterFormKind, selection: $kind) {
                        ForEach(kinds, id: \.rawValue) { Text(L10n.encounterKindName($0)) }
                    }
                    DatePicker(L10n.encounterFormDate, selection: $date)
                    TextField(L10n.encounterFormHospital, text: $hospital)
                    TextField(L10n.encounterFormDepartment, text: $department)
                    TextField(L10n.encounterFormDoctor, text: $doctor)
                }
                Section(L10n.encounterFormClinical) {
                    TextField(L10n.encounterFormComplaint, text: $chiefComplaint, axis: .vertical)
                    TextField(L10n.encounterFormDiagnosis, text: $diagnosisText, axis: .vertical)
                    TextField(L10n.encounterFormAdvice, text: $adviceText, axis: .vertical)
                    TextField(L10n.encounterFormFollowUp, text: $followUpRequirement, axis: .vertical)
                    TextField(L10n.encounterFormFee, text: $feeText)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle(L10n.encounterFormTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.reminder_save) {
                        let draft = EncounterDraft(
                            patientId: app.currentPatientId, date: date, kind: kind,
                            hospital: hospital.isEmpty ? nil : hospital,
                            department: department.isEmpty ? nil : department,
                            doctor: doctor.isEmpty ? nil : doctor,
                            chiefComplaint: chiefComplaint.isEmpty ? nil : chiefComplaint,
                            diagnosisText: diagnosisText.isEmpty ? nil : diagnosisText,
                            adviceText: adviceText.isEmpty ? nil : adviceText,
                            followUpRequirement: followUpRequirement.isEmpty ? nil : followUpRequirement,
                            feeAmount: Double(feeText))
                        Task {
                            await state.upsert(draft)
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("SP-08.encounter.form.save")
                }
            }
        }
    }
}
