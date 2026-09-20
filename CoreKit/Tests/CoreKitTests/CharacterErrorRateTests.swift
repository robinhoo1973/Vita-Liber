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
}
