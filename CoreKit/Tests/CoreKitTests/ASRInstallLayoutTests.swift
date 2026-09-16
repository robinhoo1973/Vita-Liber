import Testing
import Foundation
@testable import Domain

/// SU-M2-ASRDOWNLOAD 扩充（业主 2026-09-16 多档模型定案）：
/// ① 可同时下载多档；② 同一时刻只有一档生效；③ 可按档删除释放空间。
/// 本套件钉住①在**存储层**的实现——旧 `pruneOldVersions(keeping: [新目录, 旧激活目录])`
/// 会把另一档删掉，即「多档共存」当时被主动破坏。
@Suite("SU-M2-ASRDOWNLOAD · 安装目录布局与保留规则")
struct ASRInstallLayoutTests {

    private let uuid = "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"
    private let sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    @Test("目录名：有变体带 ~ 段；无变体退回历史布局（既有安装零迁移）")
    func 目录名两种形态() {
        let full = ASRInstallLayout.directoryName(variant: "full", version: "small-ctc-int8-2025-04-02",
                                                  sha256: sha, uuid: uuid)
        #expect(full.hasPrefix("full~"), "变体段必须在最前且用 ~ 分隔，实得 \(full)")

        let single = ASRInstallLayout.directoryName(variant: nil, version: "2023-02-20",
                                                    sha256: sha, uuid: uuid)
        #expect(!single.contains("~"), "单档家族不得出现变体段，实得 \(single)")
        // 与旧命名逐位一致：<version>-<sha12>-<uuid>
        #expect(single == "2023-02-20-0123456789ab-\(uuid)")
    }

    @Test("目录名可无歧义反解——版本号自身含 `-` 也不影响（这正是选 ~ 的原因）")
    func 解析无歧义() throws {
        let version = "small-ctc-int8-2025-04-02"      // 版本里 4 个连字符
        for variant in [nil, "full", "medium"] as [String?] {
            let name = ASRInstallLayout.directoryName(variant: variant, version: version,
                                                      sha256: sha, uuid: uuid)
            let parsed = try #require(ASRInstallLayout.parseDirectory(name), "应能反解 \(name)")
            #expect(parsed.variant == variant)
            #expect(parsed.version == version, "版本必须逐位还原，实得 \(parsed.version)")
        }
    }

    @Test("非本布局的目录名一律判否——调用方据此忽略，绝不误删")
    func 解析拒绝非布局() {
        for name in ["", "Documents", "active.json", "2023-02-20", "2023-02-20-0123456789ab",
                     "v1-notauuid-000000000000", "2023-02-20-0123456789ab-not-a-uuid"] {
            #expect(ASRInstallLayout.parseDirectory(name) == nil, "不应解析 \(name)")
        }
    }

    @Test("保留规则：每个变体各留最新一个——旧规则会删掉另一档")
    func 保留按变体分组() {
        let candidates: [(name: String, version: String, variant: String?)] = [
            ("full~v2-a1b2c3d4e5f6-\(uuid)",   "v2", "full"),
            ("full~v1-ffeeddccbbaa-\(uuid)",   "v1", "full"),     // 同变体旧版 → 该删
            ("small~v2-111122223333-\(uuid)",  "v2", "small"),    // 另一档 → 必须留
            ("v1-444455556666-\(uuid)",        "v1", nil),        // 单档家族 → 自成一档
        ]
        let keeping = ASRInstallLayout.keepingForPrune(
            candidates: candidates,
            newlyInstalled: "full~v2-a1b2c3d4e5f6-\(uuid)",
            activeName: "small~v2-111122223333-\(uuid)")

        #expect(keeping.contains("small~v2-111122223333-\(uuid)"),
                "另一档仍在保留集里——这是「多档共存」的核心断言")
        #expect(keeping.contains("v1-444455556666-\(uuid)"), "单档家族自成一档，不受影响")
        #expect(keeping.contains("full~v2-a1b2c3d4e5f6-\(uuid)"))
        #expect(!keeping.contains("full~v1-ffeeddccbbaa-\(uuid)"), "同变体旧版应被清理")
        #expect(keeping.count == 3, "实得 \(keeping.sorted())")
    }

    @Test("保留规则在单档家族下与旧行为等价（回归保护）")
    func 单档家族行为不变() {
        let candidates: [(name: String, version: String, variant: String?)] = [
            ("v3-aaaaaaaaaaaa-\(uuid)", "v3", nil),
            ("v2-bbbbbbbbbbbb-\(uuid)", "v2", nil),
        ]
        let keeping = ASRInstallLayout.keepingForPrune(
            candidates: candidates, newlyInstalled: "v3-aaaaaaaaaaaa-\(uuid)", activeName: nil)
        #expect(keeping == ["v3-aaaaaaaaaaaa-\(uuid)"], "单档应只留最新，实得 \(keeping)")
    }

    @Test("生效档不可删（引擎正加载它），其余可删")
    func 删除守卫() {
        #expect(!ASRInstallLayout.isDeletable(directoryName: "full~v2-aa-\(uuid)",
                                              activeName: "full~v2-aa-\(uuid)"))
        #expect(ASRInstallLayout.isDeletable(directoryName: "small~v1-bb-\(uuid)",
                                             activeName: "full~v2-aa-\(uuid)"))
        #expect(ASRInstallLayout.isDeletable(directoryName: "v1-cc-\(uuid)", activeName: nil),
                "无生效档时全部可删（全新装/已卸载）")
    }

    @Test("多档条目解码：无 variant 键的历史条目照常工作（向后兼容，无需 schema 变更）")
    func 历史条目兼容() throws {
        let legacy = #"{"id":"dolphin","version":"small-ctc-int8-2025-04-02","sha256":"\#(sha)","url":"x.zip","bytes":1}"#
        let decoded = try JSONDecoder().decode(ASRModelRelease.self, from: Data(legacy.utf8))
        #expect(decoded.variant == nil, "历史条目必须解码为 nil（单档）")

        let multi = #"{"id":"dolphin","version":"v2","sha256":"\#(sha)","url":"x.zip","bytes":1,"variant":"full"}"#
        let decodedFull = try JSONDecoder().decode(ASRModelRelease.self, from: Data(multi.utf8))
        #expect(decodedFull.variant == "full")
        #expect(decodedFull.id == "dolphin", "家族身份仍是 id，不新增枚举 case")
    }
}
