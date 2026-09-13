import SwiftUI

/// iOS 17 `ContentUnavailableView` 垫片（ADR-021：单一视图、版本分支）。iOS 16 原生绘制：大图标 / title2 标题 / 次级说明 / 动作区。
struct VLUnavailableView<LabelContent: View, DescriptionContent: View, ActionsContent: View>: View {
    private let label: LabelContent, description: DescriptionContent, actions: ActionsContent
    init(@ViewBuilder label: () -> LabelContent, @ViewBuilder description: () -> DescriptionContent,
         @ViewBuilder actions: () -> ActionsContent) {
        self.label = label(); self.description = description(); self.actions = actions()
    }
    var body: some View {
        if #available(iOS 17, *) {
            ContentUnavailableView { label } description: { description } actions: { actions }
        } else {
            VStack(spacing: 12) {
                label.labelStyle(StackedUnavailableLabelStyle())
                description.font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                actions.padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        }
    }
}
private struct StackedUnavailableLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 8) {
            configuration.icon.font(.system(size: 48)).foregroundStyle(.secondary)
            configuration.title.font(.title2.bold()).multilineTextAlignment(.center)
        }
    }
}
// 与 ContentUnavailableView 同一组重载——调用点只改类型名（默认实参无法推断泛型，故逐个列出）
extension VLUnavailableView where DescriptionContent == EmptyView, ActionsContent == EmptyView {
    init(@ViewBuilder label: () -> LabelContent) { self.init(label: label, description: { EmptyView() }, actions: { EmptyView() }) }
}
extension VLUnavailableView where ActionsContent == EmptyView {
    init(@ViewBuilder label: () -> LabelContent, @ViewBuilder description: () -> DescriptionContent) { self.init(label: label, description: description, actions: { EmptyView() }) }
}
extension VLUnavailableView where DescriptionContent == EmptyView {
    init(@ViewBuilder label: () -> LabelContent, @ViewBuilder actions: () -> ActionsContent) { self.init(label: label, description: { EmptyView() }, actions: actions) }
}
extension VLUnavailableView where LabelContent == Label<Text, Image>, DescriptionContent == EmptyView, ActionsContent == EmptyView {
    init(_ title: String, systemImage: String) { self.init(label: { Label(title, systemImage: systemImage) }) }
}
extension VLUnavailableView where LabelContent == Label<Text, Image>, DescriptionContent == Text, ActionsContent == EmptyView {
    init(_ title: String, systemImage: String, description: Text) { self.init(label: { Label(title, systemImage: systemImage) }, description: { description }) }
}
