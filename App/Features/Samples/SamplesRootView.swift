#if DEBUG
import SwiftUI

/// 样张图库根（仅 DEBUG；2026-10-29）。宿主注入：`VitaLiberApp.body` 在
/// 启动参数含 `-uitest-samples` 时首选本视图（模拟器直达，不进产品导航）。
///
/// 深链演示：`SamplesRoute` 值枚举 + `navigationDestination`——与产品
/// AppRoute 同构的最小演示（类型安全路径、程序化 push 两条入口都在此页）。
enum SamplesRoute: Hashable {
    case camera
    case dashboard
    case settings

    @ViewBuilder
    var destination: some View {
        switch self {
        case .camera: CameraSampleView()
        case .dashboard: DashboardSampleView()
        case .settings: SettingsSampleView()
        }
    }
}

struct SamplesRootView: View {
    @State private var path: [SamplesRoute] = []

    private struct Entry: Identifiable {
        let route: SamplesRoute
        let icon: String
        let title: String
        let subtitle: String
        var id: String { title }
    }

    private let entries: [Entry] = [
        Entry(route: .camera, icon: "camera.viewfinder", title: "Camera",
              subtitle: "Viewfinder, flash states, capture flow"),
        Entry(route: .dashboard, icon: "square.grid.2x2", title: "Dashboard",
              subtitle: "Async repository, session resume, weekly chart"),
        Entry(route: .settings, icon: "gearshape", title: "Settings",
              subtitle: "Grouped form, toggles, destructive confirm"),
    ]

    var body: some View {
        NavigationStack(path: $path) {
            List(entries) { entry in
                NavigationLink(value: entry.route) {
                    HStack(spacing: 14) {
                        Image(systemName: entry.icon)
                            .font(.title3)
                            .foregroundStyle(Color("brand-primary", bundle: .main))
                            .frame(width: 44, height: 44)
                            .background(Color("brand-primary", bundle: .main).opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: VLCornerRadius.compact,
                                                             style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title)
                                .font(.headline)
                            Text(entry.subtitle)
                                .font(.caption)
                                .foregroundStyle(Color("text-secondary", bundle: .main))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("sample.gallery.\(entry.title.lowercased())")
            }
            .navigationTitle("Sample Gallery")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // 深链演示：程序化 push（与通知点击重建路径的产品模式同构）。
                    Button("Deep Link") {
                        path = [.dashboard]
                    }
                    .accessibilityIdentifier("sample.gallery.deeplink")
                    .accessibilityLabel("Push dashboard via deep link")
                }
            }
            .navigationDestination(for: SamplesRoute.self) { route in
                route.destination
            }
        }
    }
}

#Preview("Samples") {
    SamplesRootView()
}
#endif
