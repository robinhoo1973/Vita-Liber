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

    @Test func normalizedTranscriptionNoise() {
        // 评审补测（DoD：normalize 在 KEK 派生路径上，此前零覆盖）：
        // 转抄噪声（大小写/空格/连字符/全角/表情）不改变码身份——恢复码
        // 逃生舱可达性依赖「normalize(用户输入) == 签发产物」这一等价性。
        let code = RecoveryCode.generate()
        #expect(RecoveryCode.normalize(code) == code)   // 签发产物归一化=恒等
        #expect(RecoveryCode.normalize(code.lowercased()) == code)
        let noisy = code.lowercased().map(String.init).joined(separator: " - ")
        #expect(RecoveryCode.normalize(noisy) == code)
        #expect(RecoveryCode.normalize("\u{3000}\(code)\u{1F600}") == code)   // 全角空格/表情剥除
        #expect(RecoveryCode.normalize("---  ") == "")
        #expect(RecoveryCode.normalize("") == "")
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
