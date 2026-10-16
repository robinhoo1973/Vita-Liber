import Foundation
import Testing
@testable import Domain

/// 30 位恢复码（discussions/2026-10-16-backup-sync-share-design.md §5.2，Linux 可跑）。
struct RecoveryCodeTests {

    @Test func lengthAndAlphabet() {
        let code = RecoveryCode.generate()
        #expect(code.count == RecoveryCode.length)
        let allowed = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        #expect(code.allSatisfy { allowed.contains($0) })
        // 易混字符被剔除（手抄/朗读歧义最小化）
        #expect(!code.contains("I") && !code.contains("O") && !code.contains("0") && !code.contains("1"))
    }

    @Test func generatedCodesDiffer() {
        #expect(RecoveryCode.generate() != RecoveryCode.generate())
    }

    @Test func seededGeneratorDeterministic() {
        struct Fixed: RandomNumberGenerator {
            var state: UInt64 = 42
            mutating func next() -> UInt64 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return state
            }
        }
        var a = Fixed(); var b = Fixed()
        #expect(RecoveryCode.generate(using: &a) == RecoveryCode.generate(using: &b))
    }
}
