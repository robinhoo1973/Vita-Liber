import SwiftUI
import Domain

// 四域目录联想输入组件（2026-09-24，任务 6）：
// TextField + 内联候选行。候选 = B 级「目录参考」（GradeBadge 唯一渲染出口，
// 禁手写徽章）；写入仍是用户点选的确认值，无自动落库（BR-003/004）。
// catalog 为 nil（目录未就绪/旧包）时退化为普通 TextField——降级不崩。
// 候选行触控目标 ≥44pt；候选请求带取消（旧查询结果不覆盖新输入）。

// MARK: - 共用候选行

private struct CatalogCandidateRow<Detail: View>: View {
    let title: String
    let select: () -> Void
    let detail: Detail

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                detail
                Spacer(minLength: 0)
                GradeBadge(grade: "B")
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }
}

private struct CatalogSuggestSection<Item: Identifiable, Detail: View>: View {
    let title: String
    let items: [Item]
    let titleOf: (Item) -> String
    let select: (Item) -> Void
    let detailOf: (Item) -> Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.catalogSuggestTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            ForEach(items.prefix(5)) { item in
                CatalogCandidateRow(title: titleOf(item), select: { select(item) }) {
                    detailOf(item)
                }
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - 医院

/// 医院名称联想字段：prefix/别名命中（跨区或按 region 过滤）。
public struct MedicalHospitalField: View {
    private let label: String
    @Binding private var text: String
    private let region: String?
    private let catalog: (any MedicalReferenceCatalogReading)?

    @State private var candidates: [MedicalCatalogHospital] = []
    @State private var lookup: Task<Void, Never>?

    public init(label: String, text: Binding<String>, region: String? = nil,
                catalog: (any MedicalReferenceCatalogReading)? = nil) {
        self.label = label
        self._text = text
        self.region = region
        self.catalog = catalog
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(label, text: $text)
            if let catalog, !text.trimmingCharacters(in: .whitespaces).isEmpty, !candidates.isEmpty {
                CatalogSuggestSection(
                    title: L10n.catalogSuggestTitle,
                    items: candidates,
                    titleOf: { $0.nameZh },
                    select: { text = $0.nameZh }
                ) { hospital in
                    if let area = hospital.adminArea, !area.isEmpty {
                        Text(area).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChangeCompat(of: text) { _, _ in
            refresh(catalog: catalog)
        }
        .onDisappear { lookup?.cancel() }
    }

    private func refresh(catalog: (any MedicalReferenceCatalogReading)?) {
        lookup?.cancel()
        let query = text.trimmingCharacters(in: .whitespaces)
        guard let catalog, !query.isEmpty else {
            candidates = []
            return
        }
        lookup = Task {
            if let result = try? await catalog.hospitalSuggest(query: query, region: region, limit: 8) { // try?-ok: 目录查询失败=无候选（降级为普通输入，不崩）
                guard !Task.isCancelled else { return }
                candidates = result
            }
        }
    }
}

// MARK: - 科室

/// 科室名称联想字段：目录科室全量 ≤2000 行，本地按输入过滤（prefix 优先）。
public struct MedicalDepartmentField: View {
    private let label: String
    @Binding private var text: String
    private let region: String?
    private let catalog: (any MedicalReferenceCatalogReading)?

    @State private var all: [MedicalCatalogDepartment] = []
    @State private var loadTask: Task<Void, Never>?

    public init(label: String, text: Binding<String>, region: String? = nil,
                catalog: (any MedicalReferenceCatalogReading)? = nil) {
        self.label = label
        self._text = text
        self.region = region
        self.catalog = catalog
    }

    private var matches: [MedicalCatalogDepartment] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let prefix = all.filter { $0.nameZh.hasPrefix(query) }
        let contains = all.filter { !$0.nameZh.hasPrefix(query) && $0.nameZh.contains(query) }
        return Array((prefix + contains).prefix(5))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(label, text: $text)
            if catalog != nil && !text.trimmingCharacters(in: .whitespaces).isEmpty && !matches.isEmpty {
                CatalogSuggestSection(
                    title: L10n.catalogSuggestTitle,
                    items: matches,
                    titleOf: { $0.nameZh },
                    select: { text = $0.nameZh }
                ) { department in
                    if let category = department.categoryZh, !category.isEmpty {
                        Text(category).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: catalog != nil) {
            guard let catalog else { return }
            loadTask = Task {
                if let list = try? await catalog.departmentList(region: region) { // try?-ok: 目录查询失败=无候选（降级为普通输入，不崩）
                    all = list
                }
            }
        }
        .onDisappear { loadTask?.cancel() }
    }
}

// MARK: - 检查/化验项目

/// 检查/化验项目联想字段：编码/名称/英文名/别名命中，可按类别与区域过滤。
public struct MedicalExamItemField: View {
    private let label: String
    @Binding private var text: String
    private let category: String?
    private let region: String?
    private let catalog: (any MedicalReferenceCatalogReading)?

    @State private var candidates: [MedicalCatalogExamItem] = []
    @State private var lookup: Task<Void, Never>?

    public init(label: String, text: Binding<String>, category: String? = nil, region: String? = nil,
                catalog: (any MedicalReferenceCatalogReading)? = nil) {
        self.label = label
        self._text = text
        self.category = category
        self.region = region
        self.catalog = catalog
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(label, text: $text)
            if let catalog, !text.trimmingCharacters(in: .whitespaces).isEmpty, !candidates.isEmpty {
                CatalogSuggestSection(
                    title: L10n.catalogSuggestTitle,
                    items: candidates,
                    titleOf: { $0.nameZh },
                    select: { text = $0.nameZh }
                ) { item in
                    if let unit = item.unit, !unit.isEmpty {
                        Text(unit).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChangeCompat(of: text) { _, _ in
            refresh(catalog: catalog)
        }
        .onDisappear { lookup?.cancel() }
    }

    private func refresh(catalog: (any MedicalReferenceCatalogReading)?) {
        lookup?.cancel()
        let query = text.trimmingCharacters(in: .whitespaces)
        guard let catalog, !query.isEmpty else {
            candidates = []
            return
        }
        lookup = Task {
            if let result = try? await catalog.examSuggest(query: query, category: category, region: region, limit: 8) { // try?-ok: 目录查询失败=无候选（降级为普通输入，不崩）
                guard !Task.isCancelled else { return }
                candidates = result
            }
        }
    }
}
