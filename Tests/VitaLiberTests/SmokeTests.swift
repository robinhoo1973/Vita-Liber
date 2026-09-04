import UIKit
import XCTest
import Domain
@testable import VitaLiber

// binds: SU-M0-SMOKE — TC-M0-09 启动冒烟
final class SmokeTests: XCTestCase {
    func test_SU_M0_SMOKE_MainModule五枚举完整() { XCTAssertEqual(MainModule.allCases.count, 5) }

    /// 评审 S2-1 修正：模块键必须与 ui-ux §9 规范一致（home/records/reminders/ai/me），
    /// 且每个模块都有系统字形与本地化标题——枚举不再兼职中文 UI 串。
    /// 评审补充（V3.35）：字形为 SF Symbols 名称，运行时校验可解析——拼写/改名错误
    /// 编译期不拦截，`Image(systemName:)` 静默返回空图；本断言把「空 Tab 图标」拦在 L1。
    func test_MainModule_键与规范一致() {
        XCTAssertEqual(MainModule.allCases.map(\.rawValue), ["home", "records", "reminders", "ai", "me"])
        for m in MainModule.allCases {
            XCTAssertFalse(m.title.isEmpty, "\(m.rawValue) 缺本地化标题（L10n 单出口）")
            XCTAssertNotNil(UIImage(systemName: m.systemGlyph),
                            "无效 SF Symbol 名：\(m.systemGlyph)（Tab 图标将渲染为空）")
        }
    }

    /// 评审补充（F8 八类观察类型）：Domain ObservationKind 是列表与宫格的单一事实源，
    /// FR8.1 要求八类齐全且名称非空——类型 rawValue 直上屏回归由本断言拦截。
    func test_ObservationKind_八类齐全且名称非空() {
        XCTAssertEqual(ObservationKind.allCases.count, 8)
        let keys = Set(ObservationKind.allCases.map(\.rawValue))
        XCTAssertEqual(keys, Set(["stool", "urine", "skin", "eye", "secretion", "swelling", "generic", "custom"]))
        for kind in ObservationKind.allCases {
            XCTAssertFalse(L10n.observationKindName(kind).isEmpty, "\(kind.rawValue) 类型名缺失（L10n 单出口）")
        }
    }
}
