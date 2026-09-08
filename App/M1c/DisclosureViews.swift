import SwiftUI
import Domain

/// FR20.3 L2 场景首用须知：半屏底部 Sheet + [我知道了] 单钮。
/// 首次进入场景时展示，确认后写入 ConsentRecord。
struct L2DisclosureSheet: View {
    let disclosure: SceneDisclosure
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "info.circle.fill")
                    .font(VLFont.disclosureIcon)
                    .foregroundStyle(Color("brand-primary", bundle: .main))

                Text(disclosure.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(disclosure.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer()
            }
            .padding()
            .navigationTitle(L10n.disclosureTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.disclosureAcknowledge) {
                        Task {
                            await app.recordConsent(
                                key: disclosure.key,
                                level: disclosure.level,
                                version: disclosure.version
                            )
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// FR20.3 L3 常驻微文案：caption 级别固定位置，可折叠不可关闭。
struct L3DisclosureBanner: View {
    let disclosure: SceneDisclosure
    @State private var isExpanded = true

    var body: some View {
        if isExpanded {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(disclosure.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isExpanded = false
                } label: {
                    // 审查修复：触点 ≥44pt（原 ~16pt 图标，关怀模式要求 64pt）
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.commonCancel)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// 场景须知包装器：根据场景和确认状态自动展示 L2/L4 须知。
///
/// 审查修复（L4 渲染错配）：此前 L4「操作前确认」走 L2 半屏 sheet + 单
/// 「我知道了」按钮——无取消/确认语义，L4DisclosureAlert 从未被接线
/// （死代码），导出等操作前确认的实际 UX 与 FR20.3 相悖。现按 level 分流：
/// L2 → 半屏 sheet（单确认），L4 → 取消/确认弹窗，确认才写 ConsentRecord。
struct SceneDisclosureModifier: ViewModifier {
    let scene: String
    let level: Int  // 2 or 4（L3 常驻微文案不走本修饰器）

    @Environment(AppState.self) private var app
    @State private var showSheet = false
    @State private var showAlert = false
    @State private var alertDisclosure: SceneDisclosure?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if level == 2 || level == 4 {
                    checkAndShowDisclosure()
                }
            }
            .sheet(isPresented: $showSheet) {
                if let disclosure = findDisclosure() {
                    L2DisclosureSheet(disclosure: disclosure)
                }
            }
            .alert(isPresented: $showAlert) {
                guard let d = alertDisclosure else {
                    return Alert(title: Text(L10n.disclosureTitle))
                }
                return Alert(
                    title: Text(d.title),
                    message: Text(d.body),
                    primaryButton: .cancel(Text(L10n.commonCancel)),
                    secondaryButton: .default(Text(L10n.commonConfirm)) {
                        Task {
                            await app.recordConsent(key: d.key, level: d.level, version: d.version)
                        }
                    }
                )
            }
    }

    private func checkAndShowDisclosure() {
        guard let disclosure = findDisclosure() else { return }
        // FR20.5 版本感知：同场景同版本已确认才不重展；条款修订自动重确认一次
        if !DisclosureRegistry.isConfirmed(scene: disclosure.scene,
                                           version: disclosure.version,
                                           consents: app.consentRecords) {
            if level == 4 {
                alertDisclosure = disclosure
                showAlert = true
            } else {
                showSheet = true
            }
        }
    }

    private func findDisclosure() -> SceneDisclosure? {
        let all = DisclosureRegistry.l2Disclosures + DisclosureRegistry.l4Disclosures
        return all.first { $0.scene == scene }
    }
}

extension View {
    /// FR20.3 场景须知修饰器：进入场景时自动检查并展示 L2/L4 须知
    func sceneDisclosure(scene: String, level: Int = 2) -> some View {
        modifier(SceneDisclosureModifier(scene: scene, level: level))
    }
}
