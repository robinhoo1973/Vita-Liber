import SwiftUI
import Domain
import Infrastructure

/// SP-61 付费墙（comercial V1.5）：Pro 买断 ¥68/年 或 ¥12/月、7 天试用、
/// 恢复购买常驻、信任文案固定。五时机由 PaywallRules 调度（24h 频控）。
/// EntitlementGate 语义：未解锁=权益预览，绝不报错阻断（免费体验保护八条）。
struct PaywallView: View {
    @Environment(AppState.self) private var app
    @State private var owned: Set<ProductID> = []
    @State private var busy = false

    var body: some View {
        VStack(spacing: 16) {
            VLIcon.proDiamond.resizable().frame(width: 56, height: 56)
            Text("Vita Liber Pro").font(.title2.bold())
            Text("解锁增量生产型能力，核心功能永久免费").font(.footnote).foregroundStyle(.secondary)

            VStack(spacing: 12) {
                productCard("Pro 年度", "¥68/年", detail: "多成员扩展 · 医生摘要模板 · 报销导出 · 药箱总览")
                productCard("Pro 月度", "¥12/月", detail: "同上能力，按月订阅（7 天免费试用）")
                productCard("追加包", "单独定价", detail: "核保资料包 · 自定义预警阈值 · 配药清单高级模板")
            }
            .padding(.horizontal, 16)

            Button {
                Task { await purchase(.proBase) }
            } label: {
                Text(busy ? "处理中…" : "购买 Pro")
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
            .accessibilityIdentifier("SP-61.paywall.buy")

            Button("恢复购买") {
                Task { await restore() }
            }
            .accessibilityIdentifier("SP-61.paywall.restore")

            Text(PaywallRules.trustCopy)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .accessibilityIdentifier("SP-61.paywall.trust")
        }
        .padding(.vertical, 24)
        .task { await load() }
    }

    private func productCard(_ title: String, _ price: String, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(price).font(.subheadline.bold())
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color("bg-grouped", bundle: .main)))
    }

    private func load() async { /* 权益状态经 EntitlementStore 注入（测试桩/L2 StoreKit） */ }
    private func purchase(_ p: ProductID) async {
        busy = true
        defer { busy = false }
        owned.insert(p)   // 生产路径经 EntitlementStore.purchase；此处为 UI 闭环占位
    }
    private func restore() async { /* 生产路径经 EntitlementStore.restore */ }
}

/// 权益门（§5.14）：未解锁=预览态（可用但提示升级），绝不以报错阻断
struct EntitlementGate<Content: View>: View {
    let capability: String
    @ViewBuilder let content: Content

    var body: some View {
        if PaywallRules.isBlockable(capability) {
            VStack(spacing: 8) {
                content
                Label("Pro 权益 · 预览", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(Color("grade-e", bundle: .main))
            }
        } else {
            content   // 免费红线能力：直接呈现，无任何门
        }
    }
}
