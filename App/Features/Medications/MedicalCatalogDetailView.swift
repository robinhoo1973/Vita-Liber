import Foundation
import SwiftUI
import Domain
import Perception

/// 独立药品目录只读详情。所有参考值保留来源语义，不生成诊断/剂量结论。
struct MedicalCatalogDetailView: View {
    let drugID: Int
    /// 2026-10-28 切片-only：药品读面来自三切片状态（drug 片缺省时自然空态）。
    @Environment(CatalogSlicesState.self) private var catalog
    @State private var drug: MedicalCatalogDrug?
    @State private var detail: MedicalCatalogDrugDetail?
    @State private var references: [MedicalCatalogReference] = []
    @State private var leaflets: CatalogSlicesState.LeafletResult = .unavailable

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
                leaflets = await catalog.leaflets(for: value)
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
            leafletSection
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
    @ViewBuilder
    private var leafletSection: some View {
        switch leaflets {
        case .unavailable:
            Section(L10n.medicalCatalogDetailSectionLeaflet) {
                Text(L10n.medicalCatalogDetailLeafletNotCollected)
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .legacySchema:
            Section(L10n.medicalCatalogDetailSectionLeaflet) {
                Text(L10n.medicalCatalogDetailLeafletLegacy)
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .failed:
            Section(L10n.medicalCatalogDetailSectionLeaflet) {
                Text(L10n.medicalCatalogDetailLeafletNotCollected)
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .loaded(let bundles):
            if bundles.isEmpty {
                Section(L10n.medicalCatalogDetailSectionLeaflet) {
                    Text(L10n.medicalCatalogDetailLeafletNotCollected)
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section(L10n.medicalCatalogDetailSectionLeaflet) {
                    ForEach(bundles) { bundle in
                        DisclosureGroup {
                            ForEach(bundle.sections) { section in
                                if let text = sectionText(section, bundle: bundle) {
                                    Text(text)
                                        .font(.footnote)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bundle.leaflet.nameZh)
                                Text(bundle.leaflet.matchVerified
                                     ? bundle.leaflet.sourceID
                                     : L10n.medicalCatalogDetailLeafletUnverified)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text(L10n.medicalCatalogDetailDisclaimer)
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sectionText(_ section: MedicalCatalogLeafletSection,
                             bundle: CatalogSlicesState.MedicalCatalogLeafletBundle) -> String? {
        let characters = Array(bundle.text)
        guard section.charStart >= 0, section.charEnd > section.charStart,
              section.charEnd <= characters.count else { return nil }
        return String(characters[section.charStart..<section.charEnd])
    }

}
