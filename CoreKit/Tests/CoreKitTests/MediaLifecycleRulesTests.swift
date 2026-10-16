import Foundation
import Testing
@testable import Domain

/// 媒体生命周期纯判定（discussions/2026-10-16-local-storage-layout-council.md §8 切片 13，Linux 可跑）。
/// 分支表：形状（规范 sha/旧布局/其他）× 引用（在/不在）× 宽限（内/外）逐分支映射用例；
/// keep-on-doubt = 非规范形态一律保留（BR-002 宁留勿删）。
struct MediaLifecycleRulesTests {

    private let sha = String(repeating: "ab", count: 32)
    private let now: TimeInterval = 1_000_000
    private let grace: TimeInterval = 600

    // MARK: sha 文件形态

    @Test func shaFileShape() {
        #expect(MediaLifecycleRules.isSHAFile("\(sha).bin"))
        #expect(MediaLifecycleRules.isSHAFile("\(String(repeating: "0", count: 64)).bin"))
        #expect(!MediaLifecycleRules.isSHAFile("\(sha).bin.partial"))   // 写盘中形态
        #expect(!MediaLifecycleRules.isSHAFile("\(sha.uppercased()).bin"))  // 大写非规范形
        #expect(!MediaLifecycleRules.isSHAFile("\(sha).jpg"))
        #expect(!MediaLifecycleRules.isSHAFile("\(String(sha.dropFirst(2))).bin"))  // 短
        #expect(!MediaLifecycleRules.isSHAFile("\(sha).blur.jpg"))
    }

    // MARK: originals/ 判定

    @Test func originalsUnreferencedBeyondGraceDeleted() {
        let verdict = MediaLifecycleRules.verdictOriginals(
            relativePath: "ab/\(sha).bin", mtime: now - grace - 1,
            referencedSHAs: [], now: now, grace: grace)
        #expect(verdict.delete)
    }

    @Test func originalsReferencedKept() {
        let verdict = MediaLifecycleRules.verdictOriginals(
            relativePath: "ab/\(sha).bin", mtime: now - grace - 1,
            referencedSHAs: [sha], now: now, grace: grace)
        #expect(!verdict.delete)
        #expect(verdict.reason == "referenced")
    }

    @Test func originalsGraceBoundary() {
        // 恰好宽限边界 → keep（口径钉死：now - mtime > grace 才删）
        #expect(!MediaLifecycleRules.verdictOriginals(
            relativePath: "ab/\(sha).bin", mtime: now - grace,
            referencedSHAs: [], now: now, grace: grace).delete)
        #expect(MediaLifecycleRules.verdictOriginals(
            relativePath: "ab/\(sha).bin", mtime: now - grace - 0.001,
            referencedSHAs: [], now: now, grace: grace).delete)
    }

    @Test func originalsLegacyAndUnknownShapesKept() {
        // 旧布局 {patientId}/{uuid}.{ext} → keep（三组件/非 2-hex 首层/非 .bin）
        #expect(!MediaLifecycleRules.verdictOriginals(
            relativePath: "\(UUID().uuidString)/\(UUID().uuidString).jpg",
            mtime: now - grace * 100, referencedSHAs: [], now: now, grace: grace).delete)
        // 直接挂根 → keep
        #expect(!MediaLifecycleRules.verdictOriginals(
            relativePath: "\(sha).bin", mtime: now - grace * 100,
            referencedSHAs: [], now: now, grace: grace).delete)
        // 大写首层 → keep
        #expect(!MediaLifecycleRules.verdictOriginals(
            relativePath: "AB/\(sha).bin", mtime: now - grace * 100,
            referencedSHAs: [], now: now, grace: grace).delete)
    }

    // MARK: sensitive/ 判定

    @Test func sensitiveUnreferencedBeyondGraceDeleted() {
        let verdict = MediaLifecycleRules.verdictSensitive(
            fileName: "\(sha).bin", mtime: now - grace - 1,
            referencedSHAs: [], now: now, grace: grace)
        #expect(verdict.delete)
    }

    @Test func sensitiveReferencedKept() {
        #expect(!MediaLifecycleRules.verdictSensitive(
            fileName: "\(sha).bin", mtime: now - grace - 1,
            referencedSHAs: [sha], now: now, grace: grace).delete)
    }

    @Test func sensitivePhotoShapesKept() {
        // {assetId}.jpg / {assetId}.blur.jpg 由 F8 reconcile 按 asset 行管辖，本规则不越界
        #expect(!MediaLifecycleRules.verdictSensitive(
            fileName: "\(UUID().uuidString).jpg", mtime: now - grace * 100,
            referencedSHAs: [], now: now, grace: grace).delete)
        #expect(!MediaLifecycleRules.verdictSensitive(
            fileName: "\(UUID().uuidString).blur.jpg", mtime: now - grace * 100,
            referencedSHAs: [], now: now, grace: grace).delete)
    }

    // MARK: 处理版根 sha 白名单

    @Test func processedRootSHAsStripPrefixes() {
        let tokens = ["sha:\(sha)", "file:\(sha)", "pdf:\(sha)",
                      "sha:short", "plain-token", sha]
        let set = MediaLifecycleRules.processedRootSHAs(from: tokens)
        #expect(set == [sha])
    }
}
