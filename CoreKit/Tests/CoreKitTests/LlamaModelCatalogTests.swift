import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

/// 本机 LLM 模型管理合同（2026-10-09 下载化重写；2026-09-21「共存」裁决的
/// 多条目/id 寻址语义保留在 Domain 目录解析层）。
///
/// 覆盖的**单一来源**纪律：目录（信任锚）× 指针（就绪权威）× 磁盘字节 三重一致；
/// Bundle 查询分支不存在（L0 [20] 断言钉死源码形态），此处以「无安装位即不就绪」
/// 的语义面做行为断言。Linux 可跑（安装根以测试缝指向临时目录）。
// binds: SU-M2-LLMMODEL —— 2026-10-09 换型+下载化批（test-plan V2.56 注册）
@Suite("SU-M2-LLMMODEL · 本机 LLM 模型管理（单一来源合同）", .serialized)
struct LlamaModelCatalogTests {

    private static let shaA = String(repeating: "a", count: 64)
    private static let shaB = String(repeating: "b", count: 64)

    private func makeTempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-manager-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)   // try?-ok: 测试临时目录
        return url
    }

    private func entry(id: String, bytes: Int64, sha: String,
                       role: LLMModelCatalog.Role = .general) -> LLMModelCatalog.Entry {
        LLMModelCatalog.Entry(
            id: id, role: role, fileName: "\(id).gguf", bytes: bytes, sha256: sha,
            url: URL(string: "https://cnb.cool/robinhoo1973/Resources/-/releases/download/llama-models/\(id).gguf")!,
            version: "1", license: "Apache-2.0", frame: .chatML)
    }

    private func install(root: URL, id: String, entry: LLMModelCatalog.Entry, fileBytes: Int64) throws {
        let directory = root.appendingPathComponent(id, isDirectory: true)
        let versionDirectory = directory.appendingPathComponent(
            LLMModelInstallLayout.versionDirectoryName(version: entry.version, sha256: entry.sha256),
            isDirectory: true)
        try FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0x7f, count: Int(fileBytes)).write(to: versionDirectory.appendingPathComponent(entry.fileName))
        try LlamaModelManager.writePointer(
            LlamaModelManager.InstallPointer(version: entry.version, fileName: entry.fileName,
                                             bytes: entry.bytes, sha256: entry.sha256), id: id)
    }

    @Test func absentCatalogAndInstallMeansNotReady() {
        LlamaModelManager.catalogOverride = nil
        LlamaModelManager.installRootOverride = makeTempRoot()
        defer { LlamaModelManager.installRootOverride = nil }
        // 测试宿主无随包目录 → 一切不就绪、没有激活模型（绝不假装可用）
        #expect(LlamaModelManager.catalogDocument() == nil)
        #expect(!LlamaModelManager.isModelReady(id: "no-such-model"))
        #expect(LlamaModelManager.activeModel() == nil)
        #expect(LlamaModelManager.modelSize(id: "no-such-model") == 0)
    }

    @Test func readyRequiresCatalogPointerAndExactBytes() throws {
        let root = makeTempRoot()
        defer { LlamaModelManager.installRootOverride = nil; LlamaModelManager.catalogOverride = nil }
        let entry = entry(id: "llm-general-test-0.6b-q4-k-m", bytes: 1_024, sha: Self.shaA)
        LlamaModelManager.installRootOverride = root
        LlamaModelManager.catalogOverride = LLMModelCatalog.Document(entries: [entry], preference: [entry.id])

        #expect(!LlamaModelManager.isModelReady(id: entry.id), "只有目录、没装文件 → 不就绪")

        try install(root: root, id: entry.id, entry: entry, fileBytes: 1_024)
        #expect(LlamaModelManager.isModelReady(id: entry.id))
        #expect(LlamaModelManager.modelSize(id: entry.id) == 1_024)
        let active = try #require(LlamaModelManager.activeModel())
        #expect(active.id == entry.id)
        #expect(active.frame == .chatML)
    }

    @Test func truncatedFileIsNotReady() throws {
        let root = makeTempRoot()
        defer { LlamaModelManager.installRootOverride = nil; LlamaModelManager.catalogOverride = nil }
        let entry = entry(id: "m1", bytes: 2_048, sha: Self.shaA)
        LlamaModelManager.installRootOverride = root
        LlamaModelManager.catalogOverride = LLMModelCatalog.Document(entries: [entry], preference: [entry.id])
        try install(root: root, id: entry.id, entry: entry, fileBytes: 1_000)   // 截断（与 pointer/目录钉版不符）
        #expect(!LlamaModelManager.isModelReady(id: entry.id), "字节不符 → 不就绪（截断包体不得进入加载路径）")
    }

    @Test func pointerCatalogMismatchIsNotReady() throws {
        let root = makeTempRoot()
        defer { LlamaModelManager.installRootOverride = nil; LlamaModelManager.catalogOverride = nil }
        let entry = entry(id: "m2", bytes: 1_024, sha: Self.shaA)
        LlamaModelManager.installRootOverride = root
        LlamaModelManager.catalogOverride = LLMModelCatalog.Document(entries: [entry], preference: [entry.id])
        try install(root: root, id: entry.id, entry: entry, fileBytes: 1_024)
        // 指针被改钉到另一 sha（模拟换版残留/篡改）→ 与目录条目不再同钉 → 不就绪
        try LlamaModelManager.writePointer(
            LlamaModelManager.InstallPointer(version: "1", fileName: entry.fileName,
                                             bytes: entry.bytes, sha256: Self.shaB), id: entry.id)
        #expect(!LlamaModelManager.isModelReady(id: entry.id))
    }

    @Test func preferenceOrderPicksFirstReadyEntry() throws {
        let root = makeTempRoot()
        defer { LlamaModelManager.installRootOverride = nil; LlamaModelManager.catalogOverride = nil }
        let primary = entry(id: "primary", bytes: 512, sha: Self.shaA)
        let legacy = entry(id: "legacy", bytes: 256, sha: Self.shaB)
        LlamaModelManager.installRootOverride = root
        // preference 序 = [primary, legacy]；只装 legacy → 缺 primary 不失能，回落 legacy
        LlamaModelManager.catalogOverride = LLMModelCatalog.Document(entries: [primary, legacy],
                                                                     preference: [primary.id, legacy.id])
        try install(root: root, id: legacy.id, entry: legacy, fileBytes: 256)
        #expect(LlamaModelManager.activeModel()?.id == "legacy")
        // 装上 primary → 优先序生效
        try install(root: root, id: primary.id, entry: primary, fileBytes: 512)
        #expect(LlamaModelManager.activeModel()?.id == "primary")
    }
}
