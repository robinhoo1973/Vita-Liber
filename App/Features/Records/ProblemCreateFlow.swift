import SwiftUI
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

    @State private var step: Step = .choose
    @State private var kind: String
    @State private var name = ""
    @State private var query = ""
    @State private var regionID: String?
    @State private var organID: String?
    @State private var selectedItems: [String: CatalogItem] = [:]
    @State private var saveFailed = false
    /// 保存中重入守卫：连点 [保存] 会并发两次 createProblems，写入重复病名行
    @State private var isSaving = false

    init(defaultKind: String) {
        _kind = State(initialValue: defaultKind)
    }

    private enum Step: Int, Hashable {
        case choose
        case body
        case detail
    }

    private struct CatalogItem: Identifiable {
        let id: String
        let name: String
        let region: String?
        let organ: String?
    }

    private var isSurgery: Bool { kind == "surgery" }

    private var patientGender: String? {
        app.members.first {
            $0.id == app.currentPatientId && $0.deletedAt == nil
        }?.gender
    }

    private var selectedRegion: HealthHistoryCatalog.BodyRegion? {
        guard let regionID else { return nil }
        return HealthHistoryCatalog.bodyRegions.first { $0.id == regionID }
    }

    private var selectedOrgan: HealthHistoryCatalog.BodyOrgan? {
        guard let organID else { return nil }
        return selectedRegion?.organs.first { $0.id == organID }
    }

    private var allItems: [CatalogItem] {
        if isSurgery {
            return HealthHistoryCatalog.commonSurgeries.map {
                CatalogItem(id: $0.id, name: $0.name, region: $0.regionID, organ: $0.organID)
            }
        }
        return HealthHistoryCatalog.commonConditions.map {
            CatalogItem(id: $0.id, name: $0.name, region: $0.regionID, organ: $0.organID)
        }
    }

    private var scopedItems: [CatalogItem] {
        guard let regionID else { return allItems }
        if isSurgery {
            return HealthHistoryCatalog.surgeries(in: regionID, organID: organID).map {
                CatalogItem(id: $0.id, name: $0.name, region: $0.regionID, organ: $0.organID)
            }
        }
        return HealthHistoryCatalog.conditions(in: regionID, organID: organID).map {
            CatalogItem(id: $0.id, name: $0.name, region: $0.regionID, organ: $0.organID)
        }
    }

    private var filteredItems: [CatalogItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return scopedItems }
        return scopedItems.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var selectedList: [CatalogItem] {
        selectedItems.values.sorted { $0.name < $1.name }
    }

    private var hasDraft: Bool {
        !selectedList.isEmpty || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                VStack(spacing: 0) {
                    Group {
                        switch step {
                        case .choose: chooseStep
                        case .body: bodyStep
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
                    name = ""
                    query = ""
                }
                .background(Color("bg-grouped", bundle: .main).ignoresSafeArea())
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if step != .choose {
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
                .saveFailedAlert(title: L10n.encounterSaveFailed,
                                 hint: L10n.problemSaveFailedHint,
                                 isPresented: $saveFailed)
            }
        }
    }

    // MARK: - Step 1

    private var chooseStep: some View {
        VStack(spacing: 0) {
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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

                searchField

                sectionLabel(L10n.healthHistoryCommon)
                chipGrid(filteredItems, action: chooseItem)

                Button {
                    step = .body
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "figure.stand")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color("brand-primary", bundle: .main))
                        Text(L10n.healthHistoryByBody)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color("text-primary", bundle: .main))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color("text-tertiary", bundle: .main))
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
                .buttonStyle(.plain)
                .accessibilityIdentifier("SP-49.problem.byBody")

                primaryButton(L10n.healthHistoryFreeText) {
                    step = .detail
                }
                .accessibilityIdentifier("SP-49.problem.directInput")
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

    // MARK: - Step 2

    private var bodyStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(isSurgery ? L10n.healthHistorySurgeryWhere : L10n.healthHistoryChronicWhere)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color("text-primary", bundle: .main))
                    Text(L10n.healthHistoryRegionStepHint)
                        .font(.subheadline)
                        .foregroundStyle(Color("text-secondary", bundle: .main))
                    BodyMapPicker(regionID: $regionID, organID: $organID, gender: patientGender)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            bottomCTA(title: L10n.healthHistoryNextDetail,
                      disabled: regionID == nil && selectedItems.isEmpty) {
                step = .detail
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
                        selectedSummary
                    }
                    // 常见项各自带部位；只有自由文本才使用当前人体图选择。
                    // 避免「选了胸部 + 勾了全身性高血压」时卡片把整批写成胸部。
                    if selectedItems.isEmpty
                        || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        selectedLocationCard
                    }
                    searchField
                    if !filteredItems.isEmpty {
                        sectionLabel(L10n.healthHistoryCommon)
                        chipGrid(filteredItems, action: chooseItem)
                    }

                    TextField(L10n.problemNamePlaceholder, text: $name)
                        .font(.body.weight(.medium))
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 56)
                        .background(Color("bg-grouped", bundle: .main),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color("text-primary", bundle: .main).opacity(0.08), lineWidth: 1)
                        )
                        .accessibilityIdentifier("SP-49.problem.name")

                    Label(L10n.healthHistoryConfirmedSource, systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(Color("text-secondary", bundle: .main))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            bottomCTA(title: L10n.reminder_save,
                      disabled: !hasDraft) {
                save()
            }
        }
    }

    private var selectedSummary: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)],
                  alignment: .leading, spacing: 8) {
            ForEach(selectedList) { item in
                Button {
                    selectedItems.removeValue(forKey: item.id)
                } label: {
                    HStack(spacing: 4) {
                        Text(item.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color("brand-primary", bundle: .main).opacity(0.14),
                                in: Capsule())
                    .overlay(Capsule().stroke(
                        Color("brand-primary", bundle: .main).opacity(0.55), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color("brand-primary", bundle: .main))
                .accessibilityLabel(String(format: L10n.healthHistorySelectedFmt, item.name))
                .accessibilityHint(L10n.commonCancel)
                .accessibilityIdentifier("SP-49.problem.selected.\(item.id)")
            }
        }
    }

    private var selectedLocationCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "figure.stand")
                .foregroundStyle(Color("brand-primary", bundle: .main))
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedRegion?.name ?? L10n.healthHistoryBodyRegion)
                    .font(.subheadline.weight(.semibold))
                if let selectedOrgan {
                    Text(selectedOrgan.name)
                        .font(.caption)
                        .foregroundStyle(Color("text-secondary", bundle: .main))
                }
            }
            Spacer()
            Button {
                step = .body
            } label: {
                Text(L10n.healthHistoryChooseRegion)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color("brand-primary", bundle: .main))
            .accessibilityIdentifier("SP-49.problem.changeRegion")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 64)
        .background(Color("bg-grouped", bundle: .main),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color("text-primary", bundle: .main).opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Components

    private var navigationTitle: String {
        switch step {
        case .choose:
            return L10n.problemCreateTitle
        case .body, .detail:
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

    private func chipGrid(_ items: [CatalogItem], action: @escaping (CatalogItem) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)],
                  alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                let selected = selectedItems[item.id] != nil
                Button {
                    action(item)
                } label: {
                    Text(item.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(selected
                                    ? Color("brand-primary", bundle: .main).opacity(0.14)
                                    : Color("bg-grouped", bundle: .main),
                                    in: Capsule())
                        .overlay(
                            Capsule().stroke(selected
                                             ? Color("brand-primary", bundle: .main).opacity(0.65)
                                             : Color("text-primary", bundle: .main).opacity(0.06),
                                             lineWidth: 1)
                        )
                        .foregroundStyle(selected
                                         ? Color("brand-primary", bundle: .main)
                                         : Color("text-primary", bundle: .main))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? AccessibilityTraits.isButton.union(.isSelected) : .isButton)
                .accessibilityIdentifier("SP-49.problem.common.\(item.id)")
            }
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
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
        } else {
            selectedItems[item.id] = item
        }
    }

    private func goBack() {
        switch step {
        case .choose:
            break
        case .body:
            step = .choose
        case .detail:
            step = regionID == nil ? .choose : .body
        }
    }

    private func save() {
        guard !isSaving else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var problems = selectedList.map {
            HealthProblemStore.NewProblem(name: $0.name, kind: kind,
                                          bodyRegion: $0.region, bodySite: $0.organ)
        }
        // 去重折叠与「资料建议接受流」同一条 Domain 规则（大小写/空白归一），
        // 否则手填「高血压」与常见项「高血压」大小写不同会写成两行
        let folded = trimmed.isEmpty ? "" : ProfileSuggestionExtractor.fold(trimmed, kind: .chronicCondition)
        if !folded.isEmpty,
           !problems.contains(where: {
               ProfileSuggestionExtractor.fold($0.name, kind: .chronicCondition) == folded
           }) {
            problems.append(.init(name: trimmed, kind: kind,
                                  bodyRegion: regionID, bodySite: organID))
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
