import Foundation
import Testing
@testable import Domain

// binds: SU-M1A-CAPTURE
/// FR5.1/FR5.5/FR6.2（V3.41 类型后置）：📷 单入口不前置指定文档类型——
/// `AppRoute.scanCapture` 载荷可空；旧持久化路由（带类型）必须仍可解码
/// （AppRouter 把 path 编码进 UserDefaults，升级后首启不得因解码失败丢导航）。
@Suite("SU-M1A-CAPTURE · 相机单入口（类型后置）")
struct CaptureEntryTests {
    @Test func 无类型拍摄路由可编解码() throws {
        let route = AppRoute.scanCapture(nil)
        let data = try JSONEncoder().encode(route)
        #expect(try JSONDecoder().decode(AppRoute.self, from: data) == route)
    }

    @Test func 旧持久化带类型路由仍可解码() throws {
        let legacy = try JSONEncoder().encode(AppRoute.scanCapture(.record))
        let decoded = try JSONDecoder().decode(AppRoute.self, from: legacy)
        #expect(decoded == .scanCapture(.record))
    }

    @Test func 症状入口不再属于相机流() {
        // 症状走 observationCreate（SP-14），相机流 nil = 由理解层判定类型
        #expect(AppRoute.scanCapture(nil) != AppRoute.scanCapture(.symptom))
    }
}
