import Domain
import Foundation
import Testing

/// 启动自检切片策略金样（U-批 B1，2026-10-28；纯 Domain，Linux 真跑）。
///
/// 钉死三件事：
/// 1. required/optional/分母各有唯一语义（required 只控卡展开；分母含全部 kind）；
/// 2. 16 子集穷举：profile 装不装永不影响 `isStartupReady`；
/// 3. 字面量钉版：新增第 5 个 kind 时必须来此改期望（强迫重审策略语义）。
@Suite("SU-M2-SLICE-BOOT-POLICY · 启动必需集与分母策略")
struct CatalogSliceBootPolicyTests {

    private var allKinds: [CatalogSliceKind] { CatalogSliceKind.allCases }

    private func subsets<T>(_ items: [T]) -> [[T]] {
        var result: [[T]] = [[]]
        for item in items {
            result += result.map { $0 + [item] }
        }
        return result
    }

    @Test("字面量钉版：required={drug,facility,reference}、optional={profile}、互斥且并集=全集")
    func pinnedConstants() {
        #expect(CatalogSliceBootPolicy.startupRequiredKinds
                == [.drug, .facility, .reference])
        #expect(CatalogSliceBootPolicy.optionalKinds == [.profile])
        #expect(CatalogSliceBootPolicy.startupRequiredKinds
            .isDisjoint(with: CatalogSliceBootPolicy.optionalKinds))
        #expect(CatalogSliceBootPolicy.startupRequiredKinds
            .union(CatalogSliceBootPolicy.optionalKinds)
            == Set(CatalogSliceKind.allCases),
            "新增 kind 必须同步更新本策略并改测试期望")
        #expect(CatalogSliceBootPolicy.displayedSliceCount == CatalogSliceKind.allCases.count)
        #expect(CatalogSliceBootPolicy.displayedSliceCount == 4)
    }

    @Test("required 与 legacyReplacedKinds 语义分离（当前同集但必须是两个常量）")
    func requiredIsNotLegacyReplacementSet() {
        // 当前恰好同集；此测试钉的是「两处独立声明」——O4 改四片必需时
        // required 会变为 4 元而 legacyReplacedKinds 恒 3 元。
        #expect(Set(CatalogSliceKind.legacyReplacedKinds) == [.drug, .facility, .reference])
    }

    @Test("16 子集穷举：isStartupReady 只由 required 子集决定，profile 永不参与")
    func sixteenSubsetMatrix() {
        let subsets16 = subsets(allKinds)
        #expect(subsets16.count == 16)
        for installed in subsets16 {
            let installedSet = Set(installed)
            let expected = CatalogSliceBootPolicy.startupRequiredKinds.isSubset(of: installedSet)
            #expect(CatalogSliceBootPolicy.isStartupReady(installed: installedSet) == expected,
                    "installed=\(installed.map(\.rawValue)) 期望 \(expected)")
            #expect(CatalogSliceBootPolicy.missingRequired(installed: installedSet)
                    == CatalogSliceBootPolicy.startupRequiredKinds.subtracting(installedSet))
            // profile 装不装永不影响结论。
            let withoutProfile = installedSet.subtracting([.profile])
            let withProfile = installedSet.union([.profile])
            #expect(CatalogSliceBootPolicy.isStartupReady(installed: withoutProfile)
                    == CatalogSliceBootPolicy.isStartupReady(installed: withProfile))
        }
    }

    @Test("具体口径：三必需全装=ready（有无 profile 皆然）；缺任一必需=未就绪")
    func representativeCases() {
        #expect(CatalogSliceBootPolicy.isStartupReady(
            installed: [.drug, .facility, .reference]))
        #expect(CatalogSliceBootPolicy.isStartupReady(
            installed: [.drug, .facility, .reference, .profile]))
        #expect(!CatalogSliceBootPolicy.isStartupReady(
            installed: [.drug, .facility, .profile]))
        #expect(CatalogSliceBootPolicy.missingRequired(
            installed: [.drug, .facility, .profile]) == [.reference])
        #expect(!CatalogSliceBootPolicy.isStartupReady(installed: []))
        #expect(CatalogSliceBootPolicy.missingRequired(installed: [])
                == [.drug, .facility, .reference])
    }
}
