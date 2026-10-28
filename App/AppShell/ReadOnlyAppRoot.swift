import SwiftUI
import Domain
import Infrastructure
import Perception

/// 只读降级壳（2026-10-28 只读降级 B2 骨架；B3 补齐只读页面矩阵）。
///
/// 零写纪律：容器由 `AppContainer.readOnly` 装配（no-op 调度器、无切片 facade/
/// checker/updater/通告面、无会话/holder）；本壳只读 store，不挂任何写入口。
/// 入口仅 `.tooNew` 且只读打开成功（失败卡「只读查看」显式动作）。
struct ReadOnlyAppRoot: View {
    let container: AppContainer

    var body: some View {
        WithPerceptionTracking {
            VLUnavailableView(
                L10n.startupReadonlyTitle,
                systemImage: "lock.doc",
                description: Text(L10n.startupReadonlyBanner))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tintedCanvas()
                // 容器标识必须配 .contain 才能与子元素共存（L0 第 17 节）。
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("READONLY.root")
        }
    }
}
