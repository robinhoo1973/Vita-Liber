import SwiftUI

extension View {
    /// iOS 17 `onChange(of:initial:_:)` 双参形态；iOS 16 以 `onChange(of:perform:)` + 上一值回放。
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, initial: Bool = false,
                                      _ action: @escaping (_ oldValue: V, _ newValue: V) -> Void) -> some View {
        if #available(iOS 17, *) { self.onChange(of: value, initial: initial, action) }
        else { modifier(OnChangeCompatModifier(value: value, initial: initial, action: action)) }
    }
}
private struct OnChangeCompatModifier<V: Equatable>: ViewModifier {
    let value: V; let initial: Bool; let action: (V, V) -> Void
    @State private var previous: V?
    func body(content: Content) -> some View {
        content
            .onAppear { if previous == nil { previous = value; if initial { action(value, value) } } }   // 与原生 initial 语义一致：首次以 (value, value) 回调
            .onChange(of: value) { newValue in                       // iOS 14–17 API；仅 iOS 16 路径执行，弃用告警可接受
                let old = previous ?? newValue; previous = newValue; action(old, newValue)
            }
    }
}
