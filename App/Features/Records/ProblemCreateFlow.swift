import SwiftUI
import Foundation
import Perception
import Domain
import Infrastructure

/// FR11.4 新建健康史条目（2026-10-22 按设计稿改三步流）。
///
/// 常见项 → 按部位查找（人体图两级）→ 详情。只记录用户自报的
/// 「已确诊病名 / 已发生手术」，不诊断、不推断症状。
struct ProblemCreateSheet: View {
    @Environment(AppState.self) private var app
    @Environment(TimelineViewState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .browse
    @State private var browseTab: BrowseTab = .common
    @State private var kind: String
    @State private var query = ""
    @State private var regionID: String?
    @State private var organID: String?
    @State private var selectedItems: [String: CatalogItem] = [:]
    /// 每条目的发生年份（item.id → 年份，来自滚轮的可选范围）；「不详」独立标记。
    @State private var yearByItem: [String: Int] = [:]
    @State private var unknownYearItems: Set<String> = []
    /// 当前打开滚轮的条目。
    @State private var wheelTarget: YearWheelTarget?
    @State private var saveFailed = false
    /// 保存中重入守卫：连点 [保存] 会并发两次 createProblems，写入重复病名行
    @State private var isSaving = false

    init(defaultKind: String) {
        _kind = State(initialValue: defaultKind)
    }

    private enum Step: Int, Hashable {
        case browse
        case detail
    }

    private enum BrowseTab: Int, Hashable {
        case common
        case body
    }

    private struct CatalogItem: Identifiable {
        let id: String
        let name: String
        let aliases: [String]
        let code: String?
        let department: String?
        let departmentCode: String?
        let commonRank: Int?
        let region: String?
        let organ: String?

        /// 慢性病行副标题：相关科室 + 官方码；手术无科室，仅在有码时显示。
        var detailLine: String? {
            let parts = [department.map { "\($0)\(departmentCode.map { " · \($0)" } ?? "")" },
                         code.map { "ICD-10 \($0)" }].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// 滚轮目标：已选条目 id。
    private struct YearWheelTarget: Identifiable, Equatable {
        let id: String
    }

    private var isSurgery: Bool { kind == "surgery" }

    private var patientGender: String? {
        app.members.first {
            $0.id == app.currentPatientId && $0.deletedAt == nil
        }?.gender
    }

    private var allItems: [CatalogItem] {
        if isSurgery {
            return HealthHistoryCatalog.commonSurgeries.map {
                CatalogItem(id: $0.id, name: $0.name, aliases: [],
                            code: nil, department: nil, departmentCode: nil,
                            commonRank: $0.commonRank,
                            region: $0.regionID, organ: $0.organID)
            }
        }
        return HealthHistoryCatalog.commonConditions.map {
            CatalogItem(id: $0.id, name: $0.name, aliases: $0.aliases,
                        code: $0.code, department: $0.department,
                        departmentCode: $0.departmentCode,
                        commonRank: $0.commonRank,
                        region: $0.regionID, organ: $0.organID)
        }
    }

    private var scopedItems: [CatalogItem] {
        guard let regionID else { return allItems }
        if isSurgery {
            return HealthHistoryCatalog.surgeries(in: regionID, organID: organID).map {
                CatalogItem(id: $0.id, name: $0.name, aliases: [],
                            code: nil, department: nil, departmentCode: nil,
                            commonRank: $0.commonRank,
                            region: $0.regionID, organ: $0.organID)
            }
        }
        return HealthHistoryCatalog.conditions(in: regionID, organID: organID).map {
            CatalogItem(id: $0.id, name: $0.name, aliases: $0.aliases,
                        code: $0.code, department: $0.department,
                        departmentCode: $0.departmentCode,
                        commonRank: $0.commonRank,
                        region: $0.regionID, organ: $0.organID)
        }
    }

    private var commonItems: [CatalogItem] {
        // 2026-10-24 业主：官方前 5 置顶，其余按病名拼音；Foundation 中文排序规则。
        matching(allItems).sorted { lhs, rhs in
            let leftRank = lhs.commonRank ?? Int.max
            let rightRank = rhs.commonRank ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.name.compare(rhs.name,
                                    options: [.caseInsensitive, .diacriticInsensitive],
                                    locale: Locale(identifier: "zh-Hans")) == .orderedAscending
        }
    }

    private var bodyItems: [CatalogItem] {
        matching(scopedItems)
    }

    private func matching(_ items: [CatalogItem]) -> [CatalogItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.aliases.contains { $0.localizedCaseInsensitiveContains(q) }
                || ($0.code?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var selectedList: [CatalogItem] {
        selectedItems.values.sorted { $0.name < $1.name }
    }

    private var hasDraft: Bool { !selectedList.isEmpty }

    /// 每条已选目录条目都必须有年份或显式「不详」才可保存。
    /// 年份已由滚轮限定在 Domain 合法范围，这里只判「是否已选」。
    private var allYearsComplete: Bool {
        let selectedComplete = selectedList.allSatisfy {
            unknownYearItems.contains($0.id) || yearByItem[$0.id] != nil
        }
        return selectedComplete
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                VStack(spacing: 0) {
                    Group {
                        switch step {
                        case .browse: browseStep
                        case .detail: detailStep
                        }
                    }
                    .id(step)
                    .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.20), value: step)
                // 切换 慢性病/手术史 时清空已选常见项：否则上一目录选项会带
                // 另一 kind 落库（列表按 kind 过滤后「消失」）
                .onChangeCompat(of: kind) { _, _ in
                    selectedItems.removeAll()
                    yearByItem.removeAll()
                    unknownYearItems.removeAll()
                    query = ""
                }
                .background(Color("bg-grouped", bundle: .main).ignoresSafeArea())
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if step == .detail {
                            Button {
                                goBack()
                            } label: {
                                Label(L10n.commonBack, systemImage: "chevron.left")
                            }
                            .accessibilityIdentifier("SP-49.problem.back")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(L10n.commonCancel)
                        .accessibilityIdentifier("SP-49.problem.close")
                    }
                }
                .sheet(item: $wheelTarget) { target in
                    YearWheelPickerSheet(year: yearBinding(for: target.id))
                }
                .saveFailedAlert(title: L10n.encounterSaveFailed,
                                 hint: L10n.problemSaveFailedHint,
                                 isPresented: $saveFailed)
            }
        }
    }

    // MARK: - Browse

    private var browseStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(isSurgery
                         ? L10n.healthHistoryChooseSurgeryTitle
                         : L10n.healthHistoryChooseChronicTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color("text-primary", bundle: .main))
                    Text(L10n.healthHistoryChooseHint)
                        .font(.subheadline)
                        .foregroundStyle(Color("text-secondary", bundle: .main))

                    Picker(L10n.healthHistoryKind, selection: $kind) {
                        Text(L10n.healthHistoryChronic).tag("chronic")
                        Text(L10n.healthHistorySurgery).tag("surgery")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("SP-49.problem.kind")

                    Picker(L10n.healthHistoryBrowseMode, selection: $browseTab) {
                        Text(isSurgery ? L10n.healthHistoryCommonSurgery
                                       : L10n.healthHistoryCommonChronic)
                            .tag(BrowseTab.common)
                        Text(L10n.healthHistoryByBody).tag(BrowseTab.body)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("SP-49.problem.browseMode")

                    switch browseTab {
                    case .common:
                        searchField
                        if commonItems.isEmpty {
                            emptyCatalogHint
                        } else {
                            sectionLabel(isSurgery ? L10n.healthHistoryCommonSurgery
                                                   : L10n.healthHistoryCommonChronic)
                            catalogRows(commonItems)
                            Text(L10n.healthHistoryRankHint)
                                .font(.caption2)
                                .foregroundStyle(Color("text-secondary", bundle: .main))
                        }
                    case .body:
                        BodyMapPicker(regionID: $regionID, organID: $organID,
                                      gender: patientGender)
                        if bodyItems.isEmpty {
                            emptyCatalogHint
                        } else {
                            sectionLabel(L10n.healthHistoryMappedItems)
                            catalogRows(bodyItems)
                        }
                    }

                    if !selectedList.isEmpty {
                        sectionLabel(L10n.healthHistorySelected)
                        selectedSummary
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            bottomCTA(title: L10n.healthHistoryNextDetail,
                      disabled: selectedItems.isEmpty) {
                step = .detail
            }
        }
    }

    private var emptyCatalogHint: some View {
        Label(browseTab == .common ? L10n.healthHistoryNoMatches
                                   : L10n.healthHistoryNoMappedItems,
              systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(Color("text-secondary", bundle: .main))
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    private func catalogRows(_ items: [CatalogItem]) -> some View {
        LazyVStack(spacing: 8) {
            ForEach(items) { item in
                let selected = selectedItems[item.id] != nil
                Button {
                    chooseItem(item)
                } label: {
                    HStack(spacing: 12) {
                        Text(item.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color("text-primary", bundle: .main))
                        Spacer(minLength: 8)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selected
                                             ? Color("brand-primary", bundle: .main)
                                             : Color("text-tertiary", bundle: .main))
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 56)
                    .background(selected
                                ? Color("brand-primary", bundle: .main).opacity(0.12)
                                : Color("bg-grouped", bundle: .main),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(selected
                                    ? Color("brand-primary", bundle: .main).opacity(0.55)
                                    : Color("text-primary", bundle: .main).opacity(0.06),
                                    lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected
                                        ? AccessibilityTraits.isButton.union(.isSelected)
                                        : .isButton)
                .accessibilityIdentifier("SP-49.problem.common.\(item.id)")
            }
        }
    }

    // MARK: - Step 3

    private var detailStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(isSurgery
                         ? L10n.healthHistoryAddSurgeryTitle
                         : L10n.healthHistoryAddChronicTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color("text-primary", bundle: .main))
                    Text(isSurgery
                         ? L10n.healthHistoryDetailSurgeryHint
                         : L10n.healthHistoryDetailChronicHint)
                        .font(.subheadline)
                        .foregroundStyle(Color("text-secondary", bundle: .main))

                    if !selectedList.isEmpty {
                        sectionLabel(L10n.healthHistorySelected)
                        selectedSummary
                        yearSection
                    }

                    Label(L10n.healthHistoryConfirmedSource, systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(Color("text-secondary", bundle: .main))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            bottomCTA(title: L10n.reminder_save,
                      disabled: !hasDraft || !allYearsComplete) {
                save()
            }
        }
    }

    private var selectedSummary: some View {
        LazyVStack(spacing: 8) {
            ForEach(selectedList) { item in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color("text-primary", bundle: .main))
                        if let detail = item.detailLine {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(Color("text-secondary", bundle: .main))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Button {
                        selectedItems.removeValue(forKey: item.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color("text-tertiary", bundle: .main))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(format: L10n.healthHistorySelectedFmt, item.name))
                    .accessibilityHint(L10n.commonCancel)
                    .accessibilityIdentifier("SP-49.problem.selected.\(item.id)")
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 56)
                .background(Color("brand-primary", bundle: .main).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color("brand-primary", bundle: .main).opacity(0.45),
                                lineWidth: 1)
                )
            }
        }
    }

    private var yearSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(L10n.healthHistoryYearTitle)
            ForEach(selectedList) { item in
                yearRow(title: item.name, id: item.id,
                        year: yearBinding(for: item.id),
                        unknown: unknownBinding(for: item.id))
            }
            Text(L10n.healthHistoryYearHint)
                .font(.caption)
                .foregroundStyle(Color("text-secondary", bundle: .main))
        }
    }

    /// 年份行：滚轮选择 + 「不详」。未知是显式选择，不以空值冒充。
    /// 滚轮范围由 Domain `HealthProblemRules.yearRange` 收口（2026-10-23 业主）。
    private func yearRow(title: String, id: String, year: Binding<Int?>,
                         unknown: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            if unknown.wrappedValue {
                Text(L10n.healthHistoryYearUnknown)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color("text-secondary", bundle: .main))
            } else {
                Button {
                    wheelTarget = YearWheelTarget(id: id)
                } label: {
                    HStack(spacing: 4) {
                        Text(year.wrappedValue.map { String($0) } ?? L10n.healthHistoryYearPlaceholder)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(year.wrappedValue == nil
                                             ? Color("text-tertiary", bundle: .main)
                                             : Color("text-primary", bundle: .main))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color("text-tertiary", bundle: .main))
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.healthHistoryYearPlaceholder)
                .accessibilityValue(year.wrappedValue.map { String($0) } ?? L10n.problemNotSet)
                .accessibilityIdentifier("SP-49.problem.year.\(id)")
                if !L10n.healthHistoryYearUnit.isEmpty {
                    Text(L10n.healthHistoryYearUnit)
                        .font(.subheadline)
                        .foregroundStyle(Color("text-secondary", bundle: .main))
                }
            }
            Button {
                unknown.wrappedValue.toggle()
                if unknown.wrappedValue { year.wrappedValue = nil }
            } label: {
                Text(L10n.healthHistoryYearUnknown)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .foregroundStyle(unknown.wrappedValue
                                     ? Color("brand-primary", bundle: .main)
                                     : Color("text-secondary", bundle: .main))
                    .background(unknown.wrappedValue
                                ? Color("brand-primary", bundle: .main).opacity(0.14)
                                : Color("bg-grouped", bundle: .main),
                                in: Capsule())
                    .overlay(Capsule().stroke(
                        unknown.wrappedValue
                        ? Color("brand-primary", bundle: .main).opacity(0.55)
                        : Color("text-primary", bundle: .main).opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(unknown.wrappedValue ? .isSelected : [])
            .accessibilityIdentifier("SP-49.problem.yearUnknown.\(id)")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .background(Color("bg-grouped", bundle: .main),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color("text-primary", bundle: .main).opacity(0.06), lineWidth: 1)
        )
    }

    private func yearBinding(for id: String) -> Binding<Int?> {
        Binding(
            get: { yearByItem[id] },
            set: { yearByItem[id] = $0 }
        )
    }

    private func unknownBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { unknownYearItems.contains(id) },
            set: { unknown in
                if unknown {
                    unknownYearItems.insert(id)
                    yearByItem[id] = nil
                } else {
                    unknownYearItems.remove(id)
                }
            }
        )
    }

    // MARK: - Components

    private var navigationTitle: String {
        switch step {
        case .browse:
            return L10n.problemCreateTitle
        case .detail:
            return isSurgery ? L10n.healthHistorySurgery : L10n.healthHistoryChronic
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color("text-tertiary", bundle: .main))
            TextField(isSurgery ? L10n.healthHistorySearchSurgery : L10n.healthHistorySearchChronic,
                      text: $query)
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("SP-49.problem.search")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .background(Color("bg-grouped", bundle: .main),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color("text-primary", bundle: .main).opacity(0.06), lineWidth: 1)
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color("text-secondary", bundle: .main))
    }

    private func bottomCTA(title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            Button(action: action) {
                Text(title)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                    .foregroundStyle(.white)
                    .background(Color("brand-primary", bundle: .main),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.45 : 1)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .accessibilityIdentifier("SP-49.problem.cta")
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Actions

    private func chooseItem(_ item: CatalogItem) {
        if selectedItems[item.id] != nil {
            selectedItems.removeValue(forKey: item.id)
            yearByItem.removeValue(forKey: item.id)
            unknownYearItems.remove(item.id)
        } else {
            selectedItems[item.id] = item
        }
    }

    private func goBack() {
        switch step {
        case .browse:
            break
        case .detail:
            step = .browse
        }
    }

    private func save() {
        guard !isSaving else { return }
        // 2026-10-24 业主：取消自由文本；名称/类别/器官全部来自官方目录。
        let problems = selectedList.map {
            HealthProblemStore.NewProblem(
                name: $0.name, kind: kind,
                bodyRegion: $0.region, bodySite: $0.organ,
                year: yearByItem[$0.id],
                catalogId: $0.id,
                alias: nil,
                code: $0.code,
                codeSystem: $0.code == nil ? nil : HealthHistoryCatalog.codeSystemName,
                mappingVersion: $0.code == nil ? nil : HealthHistoryCatalog.mappingVersionName,
                department: $0.department,
                departmentCode: $0.departmentCode)
        }
        guard !problems.isEmpty else { return }
        isSaving = true
        Task {
            if await state.createProblems(patientId: app.currentPatientId, problems: problems) {
                dismiss()
            } else {
                isSaving = false
                saveFailed = true
            }
        }
    }
}

/// FR11.4 后期修改健康史条目（2026-10-23 业主：「慢性病/手术没有提供后期修改的入口」）。
/// 只改用户自报的字段（名称/类型/部位/年份），不动关联的医疗事实行；
/// 年份解析与新建流共用 Domain `HealthProblemRules`。
struct ProblemEditSheet: View {
    @Environment(TimelineViewState.self) private var state
    @Environment(\.dismiss) private var dismiss

    private let problem: HealthProblemStore.HealthProblemRow

    /// 2026-10-24 业主：类别与官方名称只读；只允许修改个人别名、年份，
    /// 以及官方映射给出的器官集合内选择。禁止把慢性病改成手术史。
    @State private var alias: String
    @State private var yearValue: Int?
    @State private var yearUnknown: Bool
    @State private var organID: String?
    @State private var showYearWheel = false
    @State private var saveFailed = false
    @State private var isSaving = false

    init(problem: HealthProblemStore.HealthProblemRow) {
        self.problem = problem
        _alias = State(initialValue: problem.alias ?? "")
        _yearValue = State(initialValue: problem.year)
        // 旧数据 year 为 nil = 未登记（含显式「不详」）——编辑时保持「不详」，
        // 不强迫用户补年份才能保存其他修正。
        _yearUnknown = State(initialValue: problem.year == nil)
        _organID = State(initialValue: problem.bodySite)
    }

    private var kind: String { problem.kind ?? "chronic" }
    private var isSurgery: Bool { kind == "surgery" }

    private var catalogCondition: HealthHistoryCatalog.CommonCondition? {
        if let id = problem.catalogId, let hit = HealthHistoryCatalog.condition(id: id) {
            return hit
        }
        return HealthHistoryCatalog.condition(matching: problem.name)
    }

    private var catalogSurgery: HealthHistoryCatalog.CommonSurgery? {
        if let id = problem.catalogId, let hit = HealthHistoryCatalog.surgery(id: id) {
            return hit
        }
        return HealthHistoryCatalog.commonSurgeries.first { $0.name == problem.name }
    }

    private var mappedRegionID: String? {
        catalogCondition?.regionID ?? catalogSurgery?.regionID ?? problem.bodyRegion
    }

    private var mappedOrganIDs: [String] {
        if let condition = catalogCondition { return condition.organIDs }
        if let surgery = catalogSurgery { return surgery.organID.map { [$0] } ?? [] }
        return problem.bodySite.map { [$0] } ?? []
    }

    private var mappedOrgans: [HealthHistoryCatalog.BodyOrgan] {
        guard let region = HealthHistoryCatalog.bodyRegions.first(where: { $0.id == mappedRegionID }) else {
            return []
        }
        let allowed = Set(mappedOrganIDs)
        return region.organs.filter { allowed.contains($0.id) }
    }

    private var regionName: String? {
        guard let mappedRegionID else { return nil }
        return HealthHistoryCatalog.bodyRegions.first { $0.id == mappedRegionID }?.name
    }

    private var organName: String? {
        let selected = organID.flatMap { id in
            mappedOrgans.first { $0.id == id }?.name
        }
        return selected ?? mappedOrgans.first?.name
    }

    private var codeText: String? {
        guard let code = catalogCondition?.code, !code.isEmpty else { return nil }
        return code
    }

    /// 科室仅慢性病展示；手术不显示（2026-10-24 业主）。
    private var departmentText: String? {
        guard !isSurgery, let condition = catalogCondition,
              let department = condition.department else { return nil }
        return condition.departmentCode.map { "\(department) · \($0)" } ?? department
    }

    private var canSave: Bool {
        (yearUnknown || yearValue != nil) && !isSaving
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                Form {
                    Section(L10n.problemEditTitle) {
                        LabeledContent(L10n.healthHistoryKind) {
                            Text(isSurgery ? L10n.healthHistorySurgery : L10n.healthHistoryChronic)
                        }
                        .accessibilityIdentifier("SP-49.problem.edit.kind")
                        LabeledContent(L10n.problemNamePlaceholder) {
                            Text(problem.name)
                        }
                        .accessibilityIdentifier("SP-49.problem.edit.name")
                        TextField(L10n.healthHistoryAlias, text: $alias)
                            .accessibilityIdentifier("SP-49.problem.edit.alias")
                        if let codeText {
                            LabeledContent(L10n.healthHistoryCode) {
                                Text(codeText)
                                    .font(.body.monospaced())
                            }
                            .accessibilityIdentifier("SP-49.problem.edit.code")
                        }
                        if let departmentText {
                            LabeledContent(L10n.healthHistoryDepartment) {
                                Text(departmentText)
                            }
                            .accessibilityIdentifier("SP-49.problem.edit.department")
                        }
                    }
                    Section {
                        if !yearUnknown {
                            Button {
                                showYearWheel = true
                            } label: {
                                HStack {
                                    Text(L10n.healthHistoryYearPlaceholder)
                                        .foregroundStyle(Color("text-primary", bundle: .main))
                                    Spacer()
                                    Text(yearValue.map { String($0) } ?? L10n.problemNotSet)
                                        .font(.body.monospacedDigit())
                                        .foregroundStyle(yearValue == nil
                                                         ? Color("text-secondary", bundle: .main)
                                                         : Color("text-primary", bundle: .main))
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Color("text-tertiary", bundle: .main))
                                }
                                .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("SP-49.problem.edit.year")
                        }
                        Toggle(L10n.healthHistoryYearUnknown, isOn: $yearUnknown)
                    } header: {
                        Text(L10n.healthHistoryYearTitle)
                    }
                    Section {
                        LabeledContent(L10n.healthHistoryBodyRegion) {
                            Text(regionName ?? L10n.problemNotSet)
                        }
                        if mappedOrgans.count > 1 {
                            Picker(L10n.healthHistoryOrgan, selection: $organID) {
                                Text(L10n.problemNotSet).tag(String?.none)
                                ForEach(mappedOrgans) { organ in
                                    Text(organ.name).tag(Optional(organ.id))
                                }
                            }
                            .accessibilityIdentifier("SP-49.problem.edit.organ")
                        } else {
                            LabeledContent(L10n.healthHistoryOrgan) {
                                Text(organName ?? L10n.problemNotSet)
                            }
                            .accessibilityIdentifier("SP-49.problem.edit.organ")
                        }
                    } footer: {
                        Text(L10n.healthHistoryMappingLocked)
                    }
                }
                .navigationTitle(L10n.problemEditTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.commonCancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.reminder_save) { save() }
                            .disabled(!canSave)
                            .accessibilityIdentifier("SP-49.problem.edit.save")
                    }
                }
                .task {
                    // 旧行可能保存过已退役/重映射的器官 id：收敛到官方映射集合，
                    // 避免界面显示「脑」却把旧「head」写回。
                    if let organID, !mappedOrganIDs.contains(organID) {
                        self.organID = mappedOrganIDs.first
                    } else if organID == nil {
                        organID = mappedOrganIDs.first
                    }
                }
                .sheet(isPresented: $showYearWheel) {
                    YearWheelPickerSheet(year: $yearValue)
                }
                .saveFailedAlert(title: L10n.encounterSaveFailed,
                                 hint: L10n.problemSaveFailedHint,
                                 isPresented: $saveFailed)
            }
        }
    }

    private func save() {
        guard canSave else { return }
        let year: Int? = yearUnknown ? nil : yearValue
        let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        Task {
            let ok = await state.updateProblem(
                id: problem.id,
                update: .init(bodyRegion: mappedRegionID,
                              bodySite: organID ?? mappedOrganIDs.first,
                              year: year,
                              alias: trimmedAlias.isEmpty ? nil : trimmedAlias))
            isSaving = false
            if ok { dismiss() } else { saveFailed = true }
        }
    }
}
