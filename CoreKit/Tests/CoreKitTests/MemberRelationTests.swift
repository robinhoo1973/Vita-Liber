import Foundation
import Testing
@testable import Domain

/// FR3.1 成员关系词表单点（结构轮 2026-09-15）：rawValue 与既有落库值逐字一致
/// （零迁移），容错解析覆盖遗留细粒度值，粗粒度归并供筛选/分组。
@Suite("SU-FR3.1 · 成员关系词表单点（MemberRelation）")
struct MemberRelationTests {

    @Test("rawValue 与既有存储值逐字一致（零迁移）")
    func 存储兼容() {
        #expect(MemberRelation.selfMember.rawValue == "本人")
        #expect(MemberRelation.partner.rawValue == "配偶")
        #expect(MemberRelation.child.rawValue == "子女")
        #expect(MemberRelation.parent.rawValue == "父母")
        #expect(MemberRelation.grandparent.rawValue == "祖父母")
        #expect(MemberRelation.other.rawValue == "其他")
        // 与 PatientProfile.relation 默认值同源
        #expect(PatientProfile(id: UUID(), displayName: "A").relation == MemberRelation.selfMember.rawValue)
    }

    @Test("容错解析：已知值原样、同义归并、未知归 other 不丢内容")
    func 容错解析() {
        #expect(MemberRelation(tolerant: "配偶") == .partner)
        #expect(MemberRelation(tolerant: "父亲") == .father, "遗留细粒度值保留原 case")
        #expect(MemberRelation(tolerant: "妻子") == .partner, "常见同义归并")
        #expect(MemberRelation(tolerant: "舅舅") == .other, "未知值归 other")
        #expect(MemberRelation(tolerant: "") == .other)
    }

    @Test("粗粒度归并：父亲/母亲→父母，儿子/女儿→子女")
    func 粗粒度归并() {
        #expect(MemberRelation.father.coarse == .parent)
        #expect(MemberRelation.mother.coarse == .parent)
        #expect(MemberRelation.son.coarse == .child)
        #expect(MemberRelation.daughter.coarse == .child)
        #expect(MemberRelation.partner.coarse == .partner)
    }

    @Test("新建可选集 = 既有 sheet 目录（粗粒度，保序）")
    func 可选集() {
        #expect(MemberRelation.creatable == [.partner, .child, .parent, .grandparent, .other])
        #expect(!MemberRelation.creatable.contains(.selfMember), "本人不可新建（由 onboarding 创建）")
    }
}
