import SwiftUI
import Domain

/// Pro 产出包入口（comercial §2.2/§2.3）：未解锁=预览态（EntitlementGate 语义，
/// 可用但提示升级，绝不报错阻断）；**首次点击任一产出 = proOutputFirstTap
/// 五时机触发点**（comercial §3）。
///
/// 各产出的实体能力随对应 FR 交付（医生摘要/核保包/报销汇总为 P2/P3 模板），
/// 本页承担的是**入口与权益门**——产出未就绪时如实预览说明，不装成品。
struct ProOutputHubView: View {
    @Environment(AppEntitlementStore.self) private var entitlements
    @State private var previewProduct: String?

    private let products: [(name: String, detail: String, capability: String)] = [
        (L10n.proFeatureDoctorSummary, L10n.proFeatureDoctorSummaryDesc, "doctorSummary"),
        (L10n.proFeatureClaimExport, L10n.proFeatureClaimExportDesc, "claimSummaryExport"),
        (L10n.proFeatureFamilyCabinet, L10n.proFeatureFamilyCabinetDesc, "familyCabinet"),
        (L10n.proFeatureInsurancePack, L10n.proFeatureInsurancePackDesc, "insurancePack"),
        (L10n.proFeatureCustomThreshold, L10n.proFeatureCustomThresholdDesc, "customThreshold"),
        (L10n.proFeatureDispenseTemplate, L10n.proFeatureDispenseTemplateDesc, "dispenseTemplate"),
    ]

    var body: some View {
        List(products, id: \.capability) { product in
            EntitlementGate(capability: product.capability) {
                Button {
                    // 五时机 proOutputFirstTap：价值触发 + 24h 频控（Domain 调度）
                    _ = entitlements.evaluateTrigger(.proOutputFirstTap)
                    previewProduct = product.name
                } label: {
                    HStack {
                        Image(systemName: "diamond")   // §11-13 设计系统规则：行内小尺寸用 SF Symbols
                        VStack(alignment: .leading, spacing: 2) {
                            Text(product.name).font(.subheadline)
                            Text(product.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("SP-61.output.\(product.capability)")
            }
        }
        .navigationTitle(L10n.proOutputTitle)
        .alert(L10n.proOutputPreview, isPresented: Binding(
            get: { previewProduct != nil },
            set: { if !$0 { previewProduct = nil } })) {
            Button(L10n.onboard_gotIt, role: .cancel) {}
        } message: {
            Text(L10n.proPreviewNote(previewProduct ?? ""))
        }
    }
}
