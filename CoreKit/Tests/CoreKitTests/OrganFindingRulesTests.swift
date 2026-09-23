import Foundation
import Testing
import Domain

/// SU-M2-ORGAN-FINDING：FR11.5 脏器陈述抽取（V4.05）。
/// 金样：器官命中（含多器官/繁体形）、原文保真、无命中不猜、日期与来源透传、去重。
@Suite("SU-M2-ORGAN-FINDING FR11.5 脏器陈述抽取")
struct OrganFindingRulesTests {

    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("肺部结节陈述 → 肺条目，原文保真、时间与来源透传")
    func lungNoduleBecomesLungDraft() {
        let statement = OrganFindingRules.FindingStatement(
            text: "右肺上叶见磨玻璃结节，直径约 6mm，边界清。",
            occurredAt: base, sourceKind: "examReport", sourceId: UUID())
        let drafts = OrganFindingRules.drafts(from: [statement])
        #expect(drafts.count == 1)
        #expect(drafts[0].organ == .lung)
        #expect(drafts[0].statement == "右肺上叶见磨玻璃结节，直径约 6mm，边界清。", "原文保真：不改写、不截断")
        #expect(drafts[0].occurredAt == base)
        #expect(drafts[0].sourceKind == "examReport")
        #expect(drafts[0].sourceId == statement.sourceId)
    }

    @Test("多器官同句 → 各成一草稿（肝脾）")
    func multiOrganStatementYieldsMultipleDrafts() {
        let drafts = OrganFindingRules.drafts(from: [
            .init(text: "肝脾未见异常", sourceKind: "examReport", sourceId: UUID())
        ])
        #expect(drafts.map(\.organ) == [.liver, .spleen], "目录序输出（肝在脾前）")
    }

    @Test("繁体形与复合词命中（甲狀腺 / 甲减）")
    func traditionalFormAndCompoundHit() {
        #expect(OrganFindingRules.organHits(in: "甲狀腺結節 TI-RADS 3 類") == [.thyroid])
        #expect(OrganFindingRules.organHits(in: "双肾结石") == [.kidney])
        #expect(OrganFindingRules.organHits(in: "腦梗死后改变") == [.brain])
    }

    @Test("无器官命中不猜、空陈述跳过")
    func noHitNoDraft() {
        #expect(OrganFindingRules.drafts(from: [
            .init(text: "嘱低盐低脂饮食，2 周后复查。", sourceKind: "diagnosis", sourceId: UUID())
        ]).isEmpty)
        #expect(OrganFindingRules.drafts(from: [
            .init(text: "   ", sourceKind: "diagnosis", sourceId: UUID())
        ]).isEmpty)
    }

    @Test("同源同文重复行去重；异源同文各保留")
    func dedupBySourceAndText() {
        let source = UUID()
        let duplicated = OrganFindingRules.FindingStatement(
            text: "甲状腺结节", occurredAt: nil, sourceKind: "diagnosis", sourceId: source)
        let other = OrganFindingRules.FindingStatement(
            text: "甲状腺结节", occurredAt: nil, sourceKind: "diagnosis", sourceId: UUID())
        let drafts = OrganFindingRules.drafts(from: [duplicated, duplicated, other])
        #expect(drafts.count == 2, "同源重复去除；异源同文各成一档（时间可不同）")
        #expect(drafts.allSatisfy { $0.organ == .thyroid })
        #expect(drafts.allSatisfy { $0.occurredAt == nil }, "日期缺失不猜")
    }
}
