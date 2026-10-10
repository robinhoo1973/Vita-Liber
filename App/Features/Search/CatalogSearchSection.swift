import SwiftUI
import Domain
import Perception

// 四域目录搜索段（2026-09-24，任务 8；FR12.1 疾病/医院/检查化验覆盖）：
// 即输入即搜的目录命中分组（医院/疾病/检查化验；科室随医院 depts 呈现）。
// 结果全部为 B 级「目录参考」（GradeBadge 唯一出口），点击复制名称到剪贴板
// （目录行无对应详情页；导航落点随接线期登记）。
// catalog 为 nil（目录未就绪）时整段不渲染——搜索页退化为既有行为。
// 代际守卫与 SearchViewState 同纪律（旧查询结果不覆盖新输入）。
//
// 接线（收口批E①，2026-10-10）：GlobalSearchView 的 healthDataHits 分组之后挂载
// `CatalogSearchSection(query:catalog:state:)`——state **由父视图持有**（空态判据
// 必须感知目录命中，否则「仅医院/疾病命中」的查询会落进「未找到」分支，与
// 2026-09-16 健康分组同族缺陷）。catalog 经 EnvironmentKey 注入（AppContainer
// 装配同一 medical-catalog.sqlite 的只读四域端口；nil = 零渲染）。
// SearchViewState 不在此扩展（新文件扩展纪律）。

@MainActor
@Perceptible
final class CatalogSearchState {
    private(set) var hospitalHits: [MedicalCatalogHospital] = []
    private(set) var diagnosisHits: [MedicalCatalogDiagnosis] = []
    private(set) var examHits: [MedicalCatalogExamItem] = []
    private(set) var loadFailed = false

    private let catalog: any MedicalReferenceCatalogReading
    private var generation = 0

    /// 目录是否有任一命中（父视图空态判据消费——「未找到」不得覆盖仅目录命中的查询）。
    var hasHits: Bool { !(hospitalHits.isEmpty && diagnosisHits.isEmpty && examHits.isEmpty) }

    init(catalog: any MedicalReferenceCatalogReading) {
        self.catalog = catalog
    }

    func search(_ query: String) async {
        generation += 1
        let current = generation
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            hospitalHits = []
            diagnosisHits = []
            examHits = []
            loadFailed = false
            return
        }
        do {
            async let hospitals = catalog.hospitalSuggest(query: trimmed, region: nil, limit: 5)
            async let diagnoses = catalog.diagnosisSuggest(query: trimmed, system: nil, region: nil, limit: 5)
            async let exams = catalog.examSuggest(query: trimmed, category: nil, region: nil, limit: 5)
            let (h, d, e) = try await (hospitals, diagnoses, exams)
            guard current == generation else { return }
            hospitalHits = h
            diagnosisHits = d
            examHits = e
            loadFailed = false
        } catch {
            guard current == generation else { return }
            // 四态纪律:目录查询失败 = 空结果 + 独立失败态(不谎报「未找到」)
            hospitalHits = []
            diagnosisHits = []
            examHits = []
            loadFailed = true
        }
    }
}

/// 目录命中行:名称 + 元信息 + B 级徽章;点击复制名称。
private struct CatalogHitRow: View {
    let title: String
    let meta: String
    let copy: () -> Void

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !meta.isEmpty {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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

/// 目录搜索段主体（catalog 已就绪时挂载）。state 由父视图持有（空态判据联动，
/// E① 接线注释见文件头）。
private struct CatalogSearchContent: View {
    let query: String
    @Perception.Bindable var state: CatalogSearchState

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 8) {
                if state.loadFailed {
                    Text(L10n.searchLoadFailed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !state.hospitalHits.isEmpty {
                    group(title: L10n.templateFieldLabel("hospital")) {
                        ForEach(state.hospitalHits) { hospital in
                            CatalogHitRow(title: hospital.nameZh,
                                          meta: hospital.adminArea ?? "",
                                          copy: { UIPasteboard.general.string = hospital.nameZh })
                        }
                    }
                }
                if !state.diagnosisHits.isEmpty {
                    group(title: L10n.searchGroupDiagnosis) {
                        ForEach(state.diagnosisHits) { diagnosis in
                            CatalogHitRow(title: diagnosis.nameZh,
                                          meta: diagnosis.code,
                                          copy: { UIPasteboard.general.string = diagnosis.nameZh })
                        }
                    }
                }
                if !state.examHits.isEmpty {
                    group(title: L10n.searchGroupExam) {
                        ForEach(state.examHits) { item in
                            CatalogHitRow(title: item.nameZh,
                                          meta: item.unit ?? "",
                                          copy: { UIPasteboard.general.string = item.nameZh })
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
        .onChangeCompat(of: query) { _, _ in
            Task { await state.search(query) }
        }
        .task {
            await state.search(query)
        }
    }

    private func group<Rows: View>(title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            rows()
        }
    }
}

/// 目录搜索段入口:catalog 未就绪时零渲染(搜索页保持既有行为)。
struct CatalogSearchSection: View {
    let query: String
    @Perception.Bindable var state: CatalogSearchState   // 父视图持有（空态判据联动）

    var body: some View {
        CatalogSearchContent(query: query, state: state)
    }
}


// MARK: - 环境注入（E①：AppContainer 装配的只读四域端口）

/// `any MedicalReferenceCatalogReading` 的 Environment 载体（默认 nil =
/// 目录未就绪 → CatalogSearchSection 零渲染，搜索页保持既有行为）。
private struct MedicalReferenceCatalogKey: EnvironmentKey {
    static var defaultValue: (any MedicalReferenceCatalogReading)? { nil }
}

extension EnvironmentValues {
    var medicalReferenceCatalog: (any MedicalReferenceCatalogReading)? {
        get { self[MedicalReferenceCatalogKey.self] }
        set { self[MedicalReferenceCatalogKey.self] = newValue }
    }
}
