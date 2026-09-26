import SwiftUI
import Domain
import Infrastructure
import Perception

// MARK: - F4 就诊事件（SP-08 · FR4.1-4.4）

/// 第七轮修复：就诊类型显示名统一经 L10n 词表——表单以 rawValue
/// （"outpatient"…）落库，列表行/详情胶囊此前渲染英文枚举值；
/// 历史/未知值（如旧版中文默认）原样降级显示，不 crash。
/// 与 DocumentsDisplay.fieldValueDisplay（FR6.9 展示层映射）单一事实源收敛。
private func encounterKindDisplayName(_ raw: String) -> String {
    DocumentsDisplay.fieldValueDisplay(forKey: "kind", value: raw)
}

/// 就诊模块状态仓：列表/详情/挂接/智能推荐（BR-001 成员隔离）
@MainActor
@Perceptible
final class EncountersState {
    private(set) var encounters: [EncounterStore.EncounterRow] = []
    private let store: EncounterStore
    private var loadingPatientId: UUID?

    init(store: EncounterStore) { self.store = store }

    func load(patientId: UUID) async {
        // BR-001 成员隔离（2026-09-15 同族实测修复，与 TimelineViewState 同款）：
        // **换成员立即清屏**——失败或取消时旧成员的列表不得在新成员筛选
        // 身份下继续渲染（列表头/筛选器已是新成员，行数据却是旧成员 = 跨
        // 成员显示 + 跨成员打开详情）。同一成员重载失败仍保留旧列表
        // （假空态 doctrine 只对同成员成立）。
        if loadingPatientId != patientId {
            loadingPatientId = patientId
            encounters = []
        }
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

    func unconfirmedFields(patientId: UUID) async -> [(documentId: UUID, title: String)] {
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
        WithPerceptionTracking {
            List {
                if filteredEncounters.isEmpty {
                    VLUnavailableView(L10n.encounterEmpty, systemImage: "stethoscope",
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
            .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出
            .tintedCanvas()   // 渐变直挂本容器（根级背景会被 TabView/导航栈系统底色覆盖，V4.06 修正）
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
}

/// 就诊详情（§5.4）：头部卡 + 诊断与医嘱引用块 + 关联资料 + 智能推荐挂接区 +
/// 底部 [生成就诊总结]
struct EncounterDetailView: View {
    let encounter: EncounterStore.EncounterRow
    @Environment(AppState.self) private var app
    @Environment(EncountersState.self) private var state
    @Environment(AppRouter.self) private var router
    @Environment(ReminderStore.self) private var reminders
    @State private var current: EncounterStore.EncounterRow?
    @State private var recommendations: [UUID] = []
    @State private var linkedCards: [EncounterStore.LinkedCardRow] = []
    @State private var sourceDocuments: [EncounterStore.LinkedDocument] = []
    @State private var linkLoadFailed = false
    @State private var cardKind: String?
    @State private var showSummary = false
    /// v27 FR10.7「关联预约」：候选清单（±3 天同医院未挂接）→ 用户点选 → 二次确认 → link。绝不自动挂接。
    @State private var appointmentCandidates: [AppointmentRow] = []
    @State private var showAppointmentPicker = false
    @State private var pendingAppointmentLink: AppointmentRow?
    @State private var appointmentLinkFailed = false

    var body: some View {
        WithPerceptionTracking {
            List {
                headerSection
                diagnosisAdviceSection
                narrativeSections
                linkedDocumentsSection
                episodeCardSections
                appointmentLinkSection
                linkedCardsSection
                recommendationSection
                summaryActionSection
            }
            .navigationTitle(L10n.encounterDetailTitle)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSummary) {
                EncounterSummaryView(encounter: current ?? encounter)
            }
            // 第一步：候选清单（无候选时只有取消）——点选只记 pending，不挂接
            .confirmationDialog(L10n.encounterLinkAppointment, isPresented: $showAppointmentPicker, titleVisibility: .visible) {
                ForEach(appointmentCandidates) { candidate in
                    Button(appointmentTitle(candidate)) { pendingAppointmentLink = candidate }
                }
                Button(L10n.commonCancel, role: .cancel) {}
            } message: {
                Text(appointmentCandidates.isEmpty ? L10n.encounterLinkAppointmentNone : L10n.encounterLinkAppointmentHint)
            }
            // 第二步：显式确认后才写 appointment.encounter_id（FR10.7；失败可见、不静默）
            .alert(L10n.encounterLinkAppointmentConfirm,
                   isPresented: Binding(get: { pendingAppointmentLink != nil }, set: { if !$0 { pendingAppointmentLink = nil } })) {
                Button(L10n.encounterLinkAppointmentConfirm) {
                    if let candidate = pendingAppointmentLink { Task { await linkAppointment(candidate) } }
                }
                .accessibilityIdentifier("SP-08.encounter.linkAppointment.confirm")
                Button(L10n.commonCancel, role: .cancel) { pendingAppointmentLink = nil }
            } message: {
                Text(L10n.encounterLinkAppointmentConfirmTitle(pendingAppointmentLink.map(appointmentTitle) ?? ""))
            }
            .task { await refresh() }
        }
    }

    /// 头部卡：医院·科室·医生·日期 + 类型胶囊
    private var headerSection: some View {
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
                // round2 §3.3：费用此前落库不展示——按票面金额呈现（表单以元录入，FR4.1）
                if let fee = current?.feeAmount ?? encounter.feeAmount {
                    LabeledContent(DocumentsDisplay.fieldLabel(forKey: "fee_amount"),
                                   value: fee.formatted(.currency(code: "CNY").precision(.fractionLength(2))))
                        .font(.caption)
                }
            }
        }
        // 审查修复（L0 §17 家族，判定器盲区）：容器标识不配 .contain 会把标识
        // 下放覆盖子元素自身的标识（XCUITest 按子标识查询失败）。本处上一行是 `}`，
        // 判定器的修饰链回溯只看「以 . 开头的连续行」，且子树内的带标识控件
        // （hospital/kind/dept…）都在本 VStack 内——同文件另外两处同型。
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SP-08.encounter.detail.header")
    }

    /// 诊断与医嘱（原文引用块，左侧竖线+浅底）
    private var diagnosisAdviceSection: some View {
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
    }

    private var narrativeSections: some View {
        // v25 叙事列（§C.1 / round2 §3.3）：主诉·现病史·既往史·体格检查·过敏史·就诊总结
        // 逐字段独立分段、多行原文呈现（不摘要不改写；过敏史只是病历原文，
        // 写入个人资料须经 D4 资料建议逐项确认——此处不推导、不联动）。
        ForEach(narrativeFields(current ?? encounter), id: \.key) { field in
            Section(DocumentsDisplay.fieldLabel(forKey: field.key)) {
                Text(field.value)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("SP-08.encounter.narrative.\(field.key)")
            }
        }
    }

    /// 关联资料（FR4.2：挂接/解除均留操作历史）
    private var linkedDocumentsSection: some View {
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
    }

    /// v26/v27 就诊 episode 分段：仅呈现当前就诊关联的事实卡片。
    private var episodeCardSections: some View {
        // v26（§C.2–§C.5 / SP-08）：住院期 / 诊断 / 检查报告 / 检验报告四分段——事实表 encounter_id 只读投影
        //（写入侧 = 住院卡建就诊 / 确认卡显式归属），点击进同一已确认卡详情；原文摘要，不推导不解释。
        // v27（子项目 J · round1 §D）：+ 手术 / 治疗记录（medicalCard）/ 复诊预约（appointmentDetail）/ 随访提醒（reminderToday）。
        ForEach(Self.episodeSections, id: \.kind) { section in
            let cards = linkedCards.filter { $0.kind == section.kind }
            if !cards.isEmpty {
                Section(section.title) {
                    ForEach(cards, id: \.identity) { card in
                        episodeRow(card)
                    }
                }
                // 审查修复（L0 §17 家族，判定器盲区）：本 Section 的子元素由
                // `episodeRow(_:)`（同文件 @ViewBuilder 方法）产出，其行标识
                // SP-08.encounter.appointment/reminder.<uuid> 在另一函数的行上——
                // 判定器只扫容器**花括号内**的带标识控件，看不到跨函数的子标识，
                // 故此处长期判绿而掩蔽真实存在。
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("SP-08.encounter.section.\(section.kind.rawValue)")
            }
        }
    }

    private var appointmentLinkSection: some View {
        // v27 FR10.7「关联预约」：候选只是清单（AppointmentStore.candidates ±3 天同医院未挂接），
        // 挂接必须经用户点选 + 二次确认（link），不自动生效、不猜。
        Section {
            Button {
                Task { await loadAppointmentCandidates() }
            } label: {
                Label(L10n.encounterLinkAppointment, systemImage: CardKindIcon.symbol(for: TimelineEntryKind.appointment))
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("SP-08.encounter.linkAppointment")
            if appointmentLinkFailed {
                // token-only（审查修复）：语义令牌替代硬编码 .orange
                Text(L10n.encounterLinkAppointmentFailed).font(.caption)
                    .foregroundStyle(Color("semantic-warning", bundle: .main))
            }
        } footer: {
            Text(L10n.encounterLinkAppointmentHint)
        }
    }

    private var linkedCardsSection: some View {
        // FR6.9 期二：卡片互联读面——本就诊关联的处方/收费卡片（写入侧 =
        // OCR 确认卡 EncounterAssociation 显式归属；此处只呈现与跳转，不新增关联语义）
        Section(L10n.encounterLinkedCards) {
            if linkLoadFailed {
                // token-only（审查修复）：语义令牌替代硬编码 .orange
                Text(L10n.docImportFailed).foregroundStyle(Color("semantic-warning", bundle: .main))
                Button(L10n.retry) { Task { await refresh() } }
            }
            if !generalLinkedCards.isEmpty {
                Picker(L10n.encounterLinkedCards, selection: $cardKind) {
                    Text(L10n.filterAll).tag(Optional<String>.none)
                    ForEach(Array(Set(generalLinkedCards.map { $0.kind.cardKind })).sorted(), id: \.self) { kind in
                        Text(L10n.entityCardKindName(kind)).tag(Optional(kind))
                    }
                }
            }
            if generalLinkedCards.isEmpty {
                Text(L10n.encounterLinkedCardsEmpty)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(generalLinkedCards.filter { cardKind == nil || $0.kind.cardKind == cardKind }, id: \.identity) { card in
                    NavigationLink(value: AppRoute.medicalCard(kind: card.kind.cardKind, id: card.id, patientId: encounter.patientId)) {
                        linkedCardRow(card)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SP-08.encounter.linkedCards")
    }

    @ViewBuilder
    private var recommendationSection: some View {
        // FR4.2 智能推荐（同医院±7 天；推荐必须标「待确认」，不得自动生效）
        if !recommendations.isEmpty {
            Section {
                ForEach(recommendations, id: \.self) { docId in
                    HStack {
                        // token-only（审查修复）：语义令牌替代硬编码 .orange
                        Image(systemName: "doc.badge.plus").foregroundStyle(Color("semantic-warning", bundle: .main))
                        Text(L10n.encounterRecommendPending)
                            .font(.caption).foregroundStyle(Color("semantic-warning", bundle: .main))
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
    }

    /// 底部操作
    private var summaryActionSection: some View {
        Section {
            Button(L10n.encounterGenerateSummary) { showSummary = true }
                .accessibilityIdentifier("SP-08.encounter.summary")
        }
    }

    /// v26 四分段 + v27 四分段（kind → 标题）；其余卡类仍走「关联卡片」通用分段。
    private static let episodeSections: [(kind: EncounterStore.LinkedCardRow.Kind, title: String)] = [
        (.hospitalization, L10n.encounterSectionHospitalization), (.diagnosis, L10n.encounterSectionDiagnoses),
        (.examReport, L10n.encounterSectionExamReports), (.labReport, L10n.encounterSectionLabReports),
        (.surgery, L10n.encounterSectionSurgeries), (.treatmentRecord, L10n.encounterSectionTreatments),
        (.appointment, L10n.encounterSectionFollowUpAppointments), (.reminder, L10n.encounterSectionFollowUpReminders),
    ]
    private static let episodeKinds: Set<EncounterStore.LinkedCardRow.Kind> = [
        .hospitalization, .diagnosis, .examReport, .labReport, .surgery, .treatmentRecord, .appointment, .reminder,
    ]

    private var generalLinkedCards: [EncounterStore.LinkedCardRow] {
        linkedCards.filter { !Self.episodeKinds.contains($0.kind) }
    }

    /// 分段行落点：预约 → 预约详情；提醒 → 今日提醒聚合（reminder 无独立详情路由）；其余 → 已确认卡详情。
    @ViewBuilder
    private func episodeRow(_ card: EncounterStore.LinkedCardRow) -> some View {
        switch card.kind {
        case .appointment:
            NavigationLink(value: AppRoute.appointmentDetail(card.id)) { linkedCardRow(card) }
                .accessibilityIdentifier("SP-08.encounter.appointment.\(card.id.uuidString)")
        case .reminder:
            Button { router.navigate(to: .reminderToday) } label: { linkedCardRow(card) }
                .accessibilityIdentifier("SP-08.encounter.reminder.\(card.id.uuidString)")
        case .prescription, .claim, .medication, .metricSample, .immunization, .encounter,
             .hospitalization, .diagnosis, .examReport, .labReport, .surgery, .treatmentRecord:
            NavigationLink(value: AppRoute.medicalCard(kind: card.kind.cardKind, id: card.id, patientId: encounter.patientId)) {
                linkedCardRow(card)
            }
        }
    }

    private func appointmentTitle(_ row: AppointmentRow) -> String {
        [row.hospital, row.department].filter { !$0.isEmpty }.joined(separator: " · ")
            + " · " + row.startsAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func loadAppointmentCandidates() async {
        appointmentLinkFailed = false
        do {
            appointmentCandidates = try await reminders.appointmentCandidates(forEncounter: encounter.id, patientId: encounter.patientId)
            showAppointmentPicker = true
        } catch {
            appointmentLinkFailed = true
        }
    }

    private func linkAppointment(_ candidate: AppointmentRow) async {
        pendingAppointmentLink = nil
        do {
            try await reminders.linkAppointment(id: candidate.id, encounterId: encounter.id, patientId: encounter.patientId)
            appointmentLinkFailed = false
            await refresh()
        } catch {
            appointmentLinkFailed = true
        }
    }

    @ViewBuilder
    private func linkedCardRow(_ card: EncounterStore.LinkedCardRow) -> some View {
        let spec = CardKindIcon.spec(linkedKind: card.kind)
        HStack(spacing: 10) {
            Image(systemName: spec.symbol)
                .foregroundStyle(spec.tint)
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

    /// 非空叙事列（模板键 → 原文），键序 = 病历阅读序；标签经 `DocumentsDisplay.fieldLabel`（与确认卡同词表）。
    private func narrativeFields(_ row: EncounterStore.EncounterRow) -> [(key: String, value: String)] {
        let pairs: [(String, String?)] = [
            ("chief_complaint", row.chiefComplaint), ("present_illness", row.presentIllness),
            ("past_history", row.pastHistory), ("physical_exam", row.physicalExam),
            ("allergy_history", row.allergyHistory), ("visit_summary", row.visitSummary),
        ]
        return pairs.compactMap { pair -> (key: String, value: String)? in
            guard let value = pair.1?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return (key: pair.0, value: value)
        }
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

