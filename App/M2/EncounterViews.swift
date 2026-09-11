import SwiftUI
import Domain
import Infrastructure

// MARK: - F4 就诊事件（SP-08 · FR4.1-4.4）

/// 第七轮修复：就诊类型显示名统一经 L10n 词表——表单以 rawValue
/// （"outpatient"…）落库，列表行/详情胶囊此前渲染英文枚举值；
/// 历史/未知值（如旧版中文默认）原样降级显示，不 crash
private func encounterKindDisplayName(_ raw: String) -> String {
    EncounterKind(rawValue: raw).map { L10n.encounterKindName($0) } ?? raw
}

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
            // 读取失败保留旧列表（DocumentsState/CaregiverViews 同款
            // doctrine）——原置空把存在记录渲染成「暂无就诊记录」假空态
        }
    }

    func get(id: UUID) async -> EncounterStore.EncounterRow? {
        try? await store.get(id: id)   // try?-ok: 详情读取失败 = 显示「不存在」降级态
    }

    /// 返回是否保存成功——调用侧据此决定 dismiss 或呈现错误（保存失败
    /// 绝不静默呈现为「已保存」，四态纪律）
    @discardableResult
    func upsert(_ draft: EncounterDraft) async -> Bool {
        do {
            _ = try await store.upsert(encounter: draft)
            // 刷新必须按发起成员回读（loadSection 同款惯用法）：列表当前
            // 展示的成员（memberFilter 投影）与表单写入成员（currentPatientId）
            // 可能不同——此前 load(draft.patientId) 无条件改 loadingPatientId
            // 并提交，把筛选成员的投影覆盖掉（BR-001 跨成员脏读）
            do {
                let rows = try await store.list(patientId: draft.patientId)
                guard loadingPatientId == draft.patientId else { return true }
                encounters = rows
            } catch {
                // 刷新失败保留旧列表；写入已成功，不得回传失败诱导重试
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func linkDocument(documentId: UUID, encounterId: UUID) async -> Bool {
        do {
            try await store.linkDocument(documentId: documentId, encounterId: encounterId)
            return true
        } catch {
            return false
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

    /// FR6.9 期二：就诊关联卡片（处方/收费）——读取失败=空关联区，不阻断详情。
    func linkedCards(id: UUID, patientId: UUID) async throws -> [EncounterStore.LinkedCardRow] {
        try await store.linkedCards(encounterId: id, patientId: patientId)
    }
    func linkedDocuments(id: UUID, patientId: UUID) async throws -> [EncounterStore.LinkedDocument] {
        try await store.linkedDocuments(encounterId: id, patientId: patientId)
    }
}

/// 就诊列表（SP-08）：按时间倒序；类型胶囊 + 关联资料计数
struct EncounterListView: View {
    @Environment(AppState.self) private var app
    @Environment(EncountersState.self) private var state
    @State private var showForm = false
    /// §5.44 成员筛选（V3.72）
    @State private var memberFilter: UUID?

    private var filteredEncounters: [EncounterStore.EncounterRow] {
        guard let m = memberFilter else { return state.encounters }
        return state.encounters.filter { $0.patientId == m }
    }

    var body: some View {
        List {
            if filteredEncounters.isEmpty {
                ContentUnavailableView(L10n.encounterEmpty, systemImage: "stethoscope",
                                       description: Text(L10n.encounterEmptyHint))
                    .accessibilityIdentifier("SP-08.encounter.empty")
            } else {
                ForEach(filteredEncounters) { enc in
                    NavigationLink {
                        EncounterDetailView(encounter: enc)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(enc.hospital ?? L10n.encounterUntitled)
                                    .font(.subheadline)
                                Text("\(encounterKindDisplayName(enc.kind)) · \(enc.date.formatted(date: .abbreviated, time: .omitted))")
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
        .frame(maxWidth: 672)   // §9.1 正文行宽 ≤672pt（iPad 常宽列可读性）
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                Menu {
                    Button(L10n.filterAll) { memberFilter = nil }
                    ForEach(app.members) { m in
                        Button(m.displayName) { memberFilter = m.id }
                    }
                } label: {
                    Text(memberFilter.flatMap { id in app.members.first(where: { $0.id == id })?.displayName }
                         ?? L10n.filterAll)
                        .font(.caption).padding(.horizontal, 10).frame(minHeight: 44)
                        .background(Capsule().fill(Color(.systemGray5)))
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.thinMaterial)
        }
        .navigationTitle(L10n.encounterListTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showForm = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.encounterAdd)
                .accessibilityIdentifier("SP-08.encounter.add")
            }
        }
        .sheet(isPresented: $showForm) {
            EncounterFormView()
        }
        // 成员筛选必须触发对应成员的加载——此前只按 currentPatientId 加载，
        // 选其他成员恒为「暂无就诊记录」空态（§5.44 成员筛选失效）
        .task(id: memberFilter.map { $0.uuidString } ?? app.currentPatientId.uuidString) {
            await state.load(patientId: memberFilter ?? app.currentPatientId)
        }
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
    @State private var linkedCards: [EncounterStore.LinkedCardRow] = []
    @State private var sourceDocuments: [EncounterStore.LinkedDocument] = []
    @State private var linkLoadFailed = false
    @State private var cardKind: String?
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
                        Text(encounterKindDisplayName(current?.kind ?? encounter.kind))
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
                    // 评审修正 U1：就诊正文由用户手输/复诊自动建档（无医院原文链路），
                    // 硬编码 A（医院原文）是伪造来源（BR-003/§4.1 一眼可辨来源）——
                    // 应为 C（用户确认）。GradeBadge 自带色彩，去除手写覆盖。
                    GradeBadge(grade: "C")
                }
                if let advice = current?.adviceText ?? encounter.adviceText {
                    Text(advice)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color("brand-primary", bundle: .main)).frame(width: 3)
                        }
                    // 评审修正 U1：手写徽章变体 → GradeBadge 唯一出口（C 用户确认）
                    GradeBadge(grade: "C")
                }
                if let followUp = current?.followUpRequirement ?? encounter.followUpRequirement {
                    LabeledContent(L10n.encounterFollowUp, value: followUp)
                }
            }

            // 关联资料（FR4.2：挂接/解除均留操作历史）
            Section(L10n.encounterLinkedDocs) {
                if sourceDocuments.isEmpty {
                    Text(L10n.encounterNoDocs).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(sourceDocuments) { document in
                        NavigationLink {
                            DocumentDetailRouteView(documentId: document.id)
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                Text(document.title ?? document.type)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }

            // FR6.9 期二：卡片互联读面——本就诊关联的处方/收费卡片（写入侧 =
            // OCR 确认卡 EncounterAssociation 显式归属；此处只呈现与跳转，不新增关联语义）
            Section(L10n.encounterLinkedCards) {
                if linkLoadFailed {
                    Text(L10n.docImportFailed).foregroundStyle(.orange)
                    Button(L10n.retry) { Task { await refresh() } }
                }
                if !linkedCards.isEmpty {
                    Picker(L10n.encounterLinkedCards, selection: $cardKind) {
                        Text(L10n.filterAll).tag(Optional<String>.none)
                        ForEach(Array(Set(linkedCards.map { $0.kind.cardKind })).sorted(), id: \.self) { kind in
                            Text(L10n.entityCardKindName(kind)).tag(Optional(kind))
                        }
                    }
                }
                if linkedCards.isEmpty {
                    Text(L10n.encounterLinkedCardsEmpty)
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(linkedCards.filter { cardKind == nil || $0.kind.cardKind == cardKind }, id: \.identity) { card in
                        NavigationLink(value: AppRoute.medicalCard(kind: card.kind.cardKind, id: card.id, patientId: encounter.patientId)) {
                            linkedCardRow(card)
                        }
                    }
                }
            }
            .accessibilityIdentifier("SP-08.encounter.linkedCards")

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
                                    if await state.linkDocument(documentId: docId, encounterId: encounter.id) { await refresh() }
                                    else { linkLoadFailed = true }
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                                .frame(minHeight: 44)   // 触点≥44pt（审查修复）
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

    @ViewBuilder
    private func linkedCardRow(_ card: EncounterStore.LinkedCardRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: card.kind == .prescription ? "pills" : "creditcard")
                .foregroundStyle(Color("brand-primary", bundle: .main))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // 审查修复：与同页头部「就诊类型胶囊」同一形态（8/4 内距、
                    // brand-primary 12% 底 + brand-primary 前景）——旧实现为
                    // bg-grouped 底 6/2 内距的第二种胶囊，同屏两种徽章形态漂移。
                    Text(L10n.entityCardKindName(card.kind.cardKind))
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color("brand-primary", bundle: .main).opacity(0.12)))
                        .foregroundStyle(Color("brand-primary", bundle: .main))
                    if let date = card.date {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !card.summary.isEmpty {
                    Text(card.summary).font(.subheadline).lineLimit(2)
                }
            }
        }
        .frame(minHeight: 44)
    }

    private func refresh() async {
        current = await state.get(id: encounter.id)
        recommendations = await state.recommendations(for: current ?? encounter)
        do {
            linkedCards = try await state.linkedCards(id: encounter.id, patientId: encounter.patientId)
            sourceDocuments = try await state.linkedDocuments(id: encounter.id, patientId: encounter.patientId)
            linkLoadFailed = false
        } catch { linkLoadFailed = true }
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
                                Image(systemName: "circle.fill").font(.caption2)
                                    .foregroundStyle(Color("semantic-danger", bundle: .main))
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
    @State private var saveFailed = false

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
            .saveFailedAlert(title: L10n.encounterSaveFailed,
                             hint: L10n.encounterSaveFailedHint,
                             isPresented: $saveFailed)
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
                            // 保存失败保留表单并提示可重试——此前 upsert 吞错后
                            // 无条件 dismiss，失败呈现为「已保存」而数据丢失
                            if await state.upsert(draft) {
                                dismiss()
                            } else {
                                saveFailed = true
                            }
                        }
                    }
                    .accessibilityIdentifier("SP-08.encounter.form.save")
                }
            }
        }
    }
}

/// §5.45 路由式就诊详情（V3.72）：深链/通知指向就诊时按 id 从
/// EncountersState 投影查找并渲染详情；查无（已删除）回落可见降级。
struct EncounterDetailRouteView: View {
    let encounterId: UUID
    @Environment(EncountersState.self) private var state
    /// 深链冷启动投影未加载时按 id 直取（跨成员可见，路由成员即就诊成员）
    @State private var direct: EncounterStore.EncounterRow?

    var body: some View {
        Group {
            if let enc = state.encounters.first(where: { $0.id == encounterId }) ?? direct {
                EncounterDetailView(encounter: enc)
            } else {
                RouteFallbackView(route: .encounterDetail(encounterId))
            }
        }
        .task {
            // 此前视图从不加载：冷启动深链恒渲染「该资料已不存在」并自动弹回
            if state.encounters.first(where: { $0.id == encounterId }) == nil {
                direct = await state.get(id: encounterId)
            }
        }
    }
}
