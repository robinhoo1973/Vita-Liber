import Foundation
import Testing
@testable import Domain

@Suite("CER 字符错误率")
struct CharacterErrorRateTests {
    @Test func identicalStringsHaveZeroDistance() {
        #expect(CharacterErrorRate.distance("血红蛋白 135 g/L", "血红蛋白 135 g/L") == 0)
        #expect(CharacterErrorRate.rate(reference: "abc", hypothesis: "abc") == 0)
    }
    @Test func singleSubstitutionCountsOne() {
        #expect(CharacterErrorRate.distance("INV-2026-03821", "INV-2026-O3821") == 1)
    }
    @Test func insertionAndDeletion() {
        #expect(CharacterErrorRate.distance("阿莫西林", "阿莫西林胶囊") == 2)
        #expect(CharacterErrorRate.distance("阿莫西林胶囊", "阿莫西林") == 2)
    }
    @Test func rateNormalizesByReferenceLength() {
        // 参考 10 字，2 处错 → 0.2
        #expect(abs(CharacterErrorRate.rate(reference: "0123456789", hypothesis: "01234567XY") - 0.2) < 1e-9)
    }
    @Test func emptyReferenceIsZeroWhenHypothesisEmptyElseOne() {
        #expect(CharacterErrorRate.rate(reference: "", hypothesis: "") == 0)
        #expect(CharacterErrorRate.rate(reference: "", hypothesis: "x") == 1)
    }

    // MARK: 行级（round4 P-9 迁入 Domain；Stage B 双引擎一致率同口径）

    @Test func lineAlignedCountsMissingAndExtraLinesAsWholeErrors() {
        // 参考 2 行 / 假设 1 行：第二行缺失 → 全错（分子 3 / 分母 3+3）
        #expect(abs(CharacterErrorRate.lineAligned(reference: ["abc", "def"], hypothesis: ["abc"]) - 0.5) < 1e-9)
        // 假设多出一行：分母按 max(r,h,1) 计入该行
        #expect(abs(CharacterErrorRate.lineAligned(reference: ["abc"], hypothesis: ["abc", "xy"]) - 2.0 / 5.0) < 1e-9)
        #expect(CharacterErrorRate.lineAligned(reference: [], hypothesis: []) == 0)
    }

    @Test func lineAlignedUsesMaxLengthDenominatorPerLine() {
        // 行 1：r=4 h=6 → 2 错 / max(4,6)=6；行 2 相同 → 0 / max(2,2)=2；合计 2/8
        let cer = CharacterErrorRate.lineAligned(reference: ["阿莫西林", "口服"], hypothesis: ["阿莫西林胶囊", "口服"])
        #expect(abs(cer - 2.0 / 8.0) < 1e-9)
    }
}
