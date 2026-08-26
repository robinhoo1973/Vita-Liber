import SwiftUI

/// ADR-021：五模块单一枚举，iPhone Tab / iPad Sidebar 渲染同一枚举
enum MainModule: String, CaseIterable { case home = "首页", records = "档案", reminders = "提醒", assistant = "AI", me = "我的" }

struct RootTabView: View {
    var body: some View {
        TabView {
            ForEach(MainModule.allCases, id: \.self) { m in
                Text(m.rawValue).tabItem { Label(m.rawValue, systemImage: "circle") }
            }
        }
    }
}
