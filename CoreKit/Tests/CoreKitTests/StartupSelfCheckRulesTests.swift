import Domain
import Foundation
import Testing

/// 启动自检交接规则金样（U-批 B2，2026-10-28；纯 Domain，Linux 真跑）。
///
/// 钉死三件事（架构席第三轮 Q13 修正式）：
/// 1. 终态自 `max(presentedAt, terminalAt)` 起至少可见 minDisplay（防「ready
///    很早→终态一闪而过」）；
/// 2. headless（presentedAt=nil）永不放行；
/// 3. 常量钉版（0.8/3.0/1.5/3.0 秒，业主 O12 与既有卡片节奏）。
@Suite("SU-M2-SLICE-BOOT-POLICY · 启动自检交接规则")
struct StartupSelfCheckRulesTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("常量钉版：被动 0.8 / VO 3.0 / 卡片 1.5 / VO 卡片 3.0")
    func pinnedConstants() {
        #expect(StartupSelfCheckRules.minDisplaySeconds == 0.8)
        #expect(StartupSelfCheckRules.voiceOverMinDisplaySeconds == 3.0)
        #expect(StartupSelfCheckRules.catalogAutoEnterSeconds == 1.5)
        #expect(StartupSelfCheckRules.voiceOverCatalogAutoEnterSeconds == 3.0)
    }

    @Test("headless（presentedAt=nil）永不放行 UI")
    func headlessNeverHandsOff() {
        #expect(!StartupSelfCheckRules.shouldHandOffUI(
            presentedAt: nil, terminalAt: t0, now: t0.addingTimeInterval(3600),
            minDisplay: StartupSelfCheckRules.minDisplaySeconds))
    }

    @Test("终态晚于首帧：从终态起算最短展示（ready 早于首帧同理从首帧起算）")
    func terminalAnchoredVisibility() {
        let minDisplay = StartupSelfCheckRules.minDisplaySeconds
        // 情形 A：首帧很早，终态在 t0+10s —— 终态后 0.7s 不放行、0.8s 放行。
        let presentedEarly = t0
        let terminalLate = t0.addingTimeInterval(10)
        #expect(!StartupSelfCheckRules.shouldHandOffUI(
            presentedAt: presentedEarly, terminalAt: terminalLate,
            now: terminalLate.addingTimeInterval(0.7), minDisplay: minDisplay))
        #expect(StartupSelfCheckRules.shouldHandOffUI(
            presentedAt: presentedEarly, terminalAt: terminalLate,
            now: terminalLate.addingTimeInterval(0.8), minDisplay: minDisplay))
        // 情形 B：终态早于首帧（预加载） —— 从首帧起算。
        let terminalEarly = t0
        let presentedLate = t0.addingTimeInterval(5)
        #expect(!StartupSelfCheckRules.shouldHandOffUI(
            presentedAt: presentedLate, terminalAt: terminalEarly,
            now: presentedLate.addingTimeInterval(0.79), minDisplay: minDisplay))
        #expect(StartupSelfCheckRules.shouldHandOffUI(
            presentedAt: presentedLate, terminalAt: terminalEarly,
            now: presentedLate.addingTimeInterval(0.8), minDisplay: minDisplay))
    }

    @Test("VO 3.0s 分支与自定义 minDisplay")
    func voiceOverAndCustom() {
        let vo = StartupSelfCheckRules.voiceOverMinDisplaySeconds
        #expect(!StartupSelfCheckRules.shouldHandOffUI(
            presentedAt: t0, terminalAt: t0, now: t0.addingTimeInterval(2.9), minDisplay: vo))
        #expect(StartupSelfCheckRules.shouldHandOffUI(
            presentedAt: t0, terminalAt: t0, now: t0.addingTimeInterval(3.0), minDisplay: vo))
        #expect(StartupSelfCheckRules.shouldHandOffUI(
            presentedAt: t0, terminalAt: t0, now: t0.addingTimeInterval(0.5),
            minDisplay: 0.5))
    }

    // 批 ②（2026-10-29）：摘要展开/收起恢复锚点（测试席裁定——floor 已过期
    // 时收起不得立即交接，须保 500ms 可读窗口）。

    @Test("恢复锚点：floor 未过时取 floor（500ms 不延长正常驻留）")
    func resumeAnchorBeforeFloor() {
        let floor = t0.addingTimeInterval(2.0)
        let collapsed = t0.addingTimeInterval(0.2)
        #expect(StartupSelfCheckRules.resumeAnchor(collapsedAt: collapsed, floorEnd: floor) == floor)
    }

    @Test("恢复锚点：floor 已过时取收起时刻+500ms（不立即交接）")
    func resumeAnchorAfterFloor() {
        let floor = t0
        let collapsed = t0.addingTimeInterval(5.0)
        #expect(StartupSelfCheckRules.resumeAnchor(collapsedAt: collapsed, floorEnd: floor)
                == collapsed.addingTimeInterval(0.5))
    }

    @Test("floorEnd：headless=nil；有首帧=max(presentedAt,terminalAt)+minDisplay")
    func floorEndComputation() {
        #expect(StartupSelfCheckRules.floorEnd(presentedAt: nil, terminalAt: t0,
                                               minDisplay: 0.8) == nil)
        let presented = t0.addingTimeInterval(-1)
        let terminal = t0.addingTimeInterval(3)
        #expect(StartupSelfCheckRules.floorEnd(presentedAt: presented, terminalAt: terminal,
                                               minDisplay: 0.8)
                == terminal.addingTimeInterval(0.8))
    }

    @Test("恢复延迟常量钉版 0.5s")
    func resumeDelayConstant() {
        #expect(StartupSelfCheckRules.expandedResumeDelay == 0.5)
    }
}
