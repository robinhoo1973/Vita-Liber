import Foundation
import Testing
@testable import Domain

/// 本机 LLM 安装位布局合同（纯函数；2026-10-09 换型+下载化批）。
@Suite("LLM 模型安装位布局（Domain）")
struct LLMModelInstallLayoutTests {

    @Test func versionDirectoryCarriesShortSHA() {
        let name = LLMModelInstallLayout.versionDirectoryName(version: "1",
                                                              sha256: "ac2d9771deadbeef")
        #expect(name == "1-ac2d9771dead")
    }

    @Test func stagingNameIsContentAddressedForResume() {
        // 2026-10-29 评审修复：暂存位按 version+sha 内容寻址（跨尝试稳定才能续传）；
        // 不同内容绝不共用一个 .part（旧前缀 + 新内容 = 白下 + 校验必红）。
        let name = LLMModelInstallLayout.stagingDirectoryName(version: "1",
                                                             sha256: "ac2d9771deadbeef")
        #expect(name == ".staging-1-ac2d9771dead")
        #expect(LLMModelInstallLayout.stagingDirectoryName(version: "2",
                                                           sha256: "ac2d9771deadbeef") != name)
    }

    @Test func resumeOffsetMatrix() {
        // 正常半程 → 续传
        #expect(LLMModelInstallLayout.resumeOffset(partialBytes: 100, expectedBytes: 1000) == 100)
        // 无部分文件 / 空文件 / 达到或超过钉版体积 → 从头
        #expect(LLMModelInstallLayout.resumeOffset(partialBytes: nil, expectedBytes: 1000) == 0)
        #expect(LLMModelInstallLayout.resumeOffset(partialBytes: 0, expectedBytes: 1000) == 0)
        #expect(LLMModelInstallLayout.resumeOffset(partialBytes: 1000, expectedBytes: 1000) == 0)
        #expect(LLMModelInstallLayout.resumeOffset(partialBytes: 1001, expectedBytes: 1000) == 0)
    }

    @Test func cleanupKeepsOnlyActiveVersion() {
        let plan = LLMModelInstallLayout.cleanupPlan(
            installed: ["2-bbbbbbbbbbbb", "1-aaaaaaaaaaaa", ".staging-x"], active: "2-bbbbbbbbbbbb")
        #expect(plan == [".staging-x", "1-aaaaaaaaaaaa"], "active 之外全部进入清扫（确定性排序）")
        #expect(LLMModelInstallLayout.cleanupPlan(installed: ["1-a"], active: "1-a").isEmpty)
    }

    @Test func readinessRequiresPointerNameAndExactBytes() {
        let onDisk: [String: Int64] = ["q.gguf": 396_705_472]
        #expect(LLMModelInstallLayout.isReady(pointerFileName: "q.gguf", onDisk: onDisk,
                                              expectedFileName: "q.gguf", expectedBytes: 396_705_472))
        #expect(!LLMModelInstallLayout.isReady(pointerFileName: "q.gguf", onDisk: onDisk,
                                               expectedFileName: "q.gguf", expectedBytes: 1),
                "字节不符 → 不就绪（截断包体不得进入加载路径）")
        #expect(!LLMModelInstallLayout.isReady(pointerFileName: "other.gguf", onDisk: onDisk,
                                               expectedFileName: "q.gguf", expectedBytes: 396_705_472),
                "指针文件名与目录条目不一致 → 不就绪")
        #expect(!LLMModelInstallLayout.isReady(pointerFileName: "q.gguf", onDisk: [:],
                                               expectedFileName: "q.gguf", expectedBytes: 396_705_472))
    }
}
