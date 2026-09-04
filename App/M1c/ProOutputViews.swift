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
        ("医生摘要定制模板", "按就诊生成可定制的医生沟通摘要", "doctorSummary"),
        ("报销汇总导出", "报销票据一键汇总导出", "claimSummaryExport"),
        ("药箱总览", "家庭药箱跨成员总览视图", "familyCabinet"),
        ("核保资料包", "勾选范围加密打包（追加包）", "insurancePack"),
        ("自定义预警阈值", "F16 预警阈值个性化（追加包）", "customThreshold"),
        ("配药清单高级模板", "配药清单模板定制（追加包）", "dispenseTemplate"),
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
        .navigationTitle("Pro 产出包")
        .alert("产出预览", isPresented: Binding(
            get: { previewProduct != nil },
            set: { if !$0 { previewProduct = nil } })) {
            Button(L10n.onboard_gotIt, role: .cancel) {}
        } message: {
            Text(L10n.proPreviewNote(previewProduct ?? ""))
        }
    }
}
