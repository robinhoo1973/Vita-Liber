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

    /// 评审修正：let 存储属性在结构体初始化时一次性求值——语言切换后本页
    /// 文案停留在旧语言（曾依赖 .id 全树重建兜底）；改为计算属性，
    /// 每次 body 求值按当前语言重新解析。
    private var products: [(name: String, detail: String, capability: String)] {
        [
            (L10n.proFeatureDoctorSummary, L10n.proFeatureDoctorSummaryDesc, "doctorSummary"),
            (L10n.proFeatureClaimExport, L10n.proFeatureClaimExportDesc, "claimSummaryExport"),
            (L10n.proFeatureFamilyCabinet, L10n.proFeatureFamilyCabinetDesc, "familyCabinet"),
            (L10n.proFeatureInsurancePack, L10n.proFeatureInsurancePackDesc, "insurancePack"),
            (L10n.proFeatureCustomThreshold, L10n.proFeatureCustomThresholdDesc, "customThreshold"),
            (L10n.proFeatureDispenseTemplate, L10n.proFeatureDispenseTemplateDesc, "dispenseTemplate"),
        ]
    }

    var body: some View {
        List(products, id: \.capability) { product in
            EntitlementGate(capability: product.capability) {
                Button {
                    // 五时机 proOutputFirstTap：价值触发 + 24h 频控（Domain 调度）。
                    // 审查修复：evaluateTrigger 返回 true = 已弹墙（PaywallHost
                    // 观察 pendingPaywallTrigger 呈现），此时必须跳过预览 alert——
                    // 原实现丢弃返回值继续设 previewProduct，弹墙 sheet 与本
                    // alert 双模态同时呈现（文档化契约「true=已弹墙，调用方应
                    // 跳过原动作」被违反）。
                    if entitlements.evaluateTrigger(.proOutputFirstTap) { return }
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
