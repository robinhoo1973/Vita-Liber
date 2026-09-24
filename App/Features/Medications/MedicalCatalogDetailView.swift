import Foundation
import SwiftUI
import Domain
import Perception

/// 独立药品目录只读详情。所有参考值保留来源语义，不生成诊断/剂量结论。
struct MedicalCatalogDetailView: View {
    let drugID: Int
    @Environment(MedicalCatalogState.self) private var catalog
    @State private var drug: MedicalCatalogDrug?
    @State private var detail: MedicalCatalogDrugDetail?
    @State private var references: [MedicalCatalogReference] = []

    var body: some View {
        WithPerceptionTracking {
            Group {
                if let drug {
                    content(drug)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(drug?.displayName ?? L10n.medicalCatalogDetailTitle)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: drugID) {
                guard let value = await catalog.drug(id: drugID) else { return }
                drug = value
                detail = await catalog.detail(for: value)
                references = await catalog.references(for: value)
            }
        }
    }

    @ViewBuilder
    private func content(_ drug: MedicalCatalogDrug) -> some View {
        List {
            Section(L10n.medicalCatalogDetailSectionBasic) {
                LabeledContent(L10n.medicalCatalogDetailNameZh, value: drug.nameZh ?? L10n.medicalCatalogDetailNotProvided)
                if let name = drug.nameEn, !name.isEmpty { LabeledContent(L10n.medicalCatalogDetailNameEn, value: name) }
                if let brand = drug.brandName, !brand.isEmpty { LabeledContent(L10n.medicalCatalogDetailBrand, value: brand) }
                LabeledContent(L10n.medicalCatalogDetailRegion, value: drug.region)
                if let license = drug.licenseNo { LabeledContent(L10n.medicalCatalogDetailLicense, value: license) }
                if let code = drug.drugCode, !code.isEmpty { LabeledContent(L10n.medicalCatalogDetailCode, value: code) }
            }
            Section(L10n.medicalCatalogDetailSectionSpec) {
                if let spec = drug.spec, !spec.isEmpty { LabeledContent(L10n.medicalCatalogDetailSpec, value: spec) }
                if let form = drug.dosageForm, !form.isEmpty { LabeledContent(L10n.medicalCatalogDetailDosageForm, value: form) }
                if let ingredient = drug.activeIngredients, !ingredient.isEmpty {
                    LabeledContent(L10n.medicalCatalogDetailIngredient, value: ingredient)
                }
                Text(L10n.medicalCatalogDetailDisclaimer)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let detail {
                Section(L10n.medicalCatalogDetailSectionSpec) {
                    if let usage = detail.usageText, !usage.isEmpty {
                        LabeledContent(L10n.medicalCatalogDetailUsage, value: usage)
                    }
                    if let indications = detail.indications, !indications.isEmpty {
                        LabeledContent(L10n.medicalCatalogDetailIndications, value: indications)
                    }
                }
            }
            if !references.isEmpty {
                Section(L10n.medicalCatalogDetailSectionSources) {
                    ForEach(references, id: \.referenceID) { reference in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(reference.region + " · " + (reference.matchStatus.rawValue))
                                .font(.caption).foregroundStyle(.secondary)
                            if let url = firstURL(from: reference.imageURLsJSON) {
                                Link(L10n.medicalCatalogDetailOfficialLink, destination: url)
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .tintedCanvas()
    }

    private func firstURL(from json: String) -> URL? {
        guard let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([CatalogURL].self, from: data), // try?-ok: 行内 URL JSON 解码失败=无链接（降级不崩）
              let raw = values.first?.url else { return nil }
        return URL(string: raw)
    }

    private struct CatalogURL: Decodable {
        let url: String
    }
}
