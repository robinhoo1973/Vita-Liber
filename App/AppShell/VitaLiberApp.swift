import Foundation
import SwiftUI
import os
import Domain
import Infrastructure
import Protocols
import Perception

/// 薄壳：首帧前只做语言恢复与随包定标，数据库探测/迁移在启动门后台执行。
/// 初始化未完成前只渲染 `DatabaseInitializationView`，不创建任何 store。
@main
struct VitaLiberApp: App {
    @StateObject private var boot = DatabaseBootModel()

    init() {
        // FR14.5 启动语言恢复（评审修正）：同步执行、首帧前完成——
        // 消除非默认语言用户首帧 zh-Hans 闪烁；不广播（重渲染由
        // settingsStore.values[.language] 观察驱动，见 AppRootView）。
        L10n.restoreLanguage()
        // G17（2026-10-18）：B1 随包脚本定标——60 条脚本金样 → voiceDeterministicEnabled。
        // 缺件/不达标保持关闭（release 入口随默认隐藏）；B2 500 真人门独立。
        VoiceCalibrationBundled.apply()
    }

    var body: some Scene {
        WindowGroup {
            WithPerceptionTracking {
                if let container = boot.container {
                    ReadyAppRoot(container: container)
                } else {
                    DatabaseInitializationView(model: boot)
                        .task { await boot.start() }
                }
            }
        }
    }
}
