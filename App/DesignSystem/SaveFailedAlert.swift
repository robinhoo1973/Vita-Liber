import SwiftUI

/// 保存失败错误态统一出口（四态纪律：失败绝不静默呈现为已保存）。
/// 各表单此前各自复制 .alert 三元组（标题 + 提示 + 单一确认按钮），
/// 文案或按钮语义改一处必须同步多处——统一为一个修饰器。
struct SaveFailedAlert: ViewModifier {
    let title: String
    let hint: String
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.alert(title, isPresented: $isPresented) {
            Button(L10n.commonConfirm, role: .cancel) { }
        } message: {
            Text(hint)
        }
    }
}

extension View {
    /// 保存失败警报（统一出口）：isPresented 绑定驱动，标题/提示按域传参。
    func saveFailedAlert(title: String, hint: String,
                         isPresented: Binding<Bool>) -> some View {
        modifier(SaveFailedAlert(title: title, hint: hint, isPresented: isPresented))
    }
}
