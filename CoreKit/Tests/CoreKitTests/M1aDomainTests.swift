import Foundation
import Testing
@testable import Domain

/// M1a 纵向切片 · Domain 层验收用例（dev-pm §3.2.1 退出准则的 U 半场）
///
/// V3.22 门禁改造：应用内 PIN 退役（PinLockTests 随 PinLock/PinHashScheme 删除）；
/// 门禁 = 系统设备所有者认证，节流/锁定由系统处理，Domain 侧无状态机可测——
/// 门禁行为断言迁至 App 层 XCTest（SU-M1a-BIO，注入 FakeGateUnlocker）。
@Suite("M1a · BR-003 确认状态机与时间轴投影")
struct OcrConfirmationTests {
    @Test func 未确认字段不得入正式时间轴() {
        var set = OcrConfirmationSet(fields: [
            CandidateField(key: "drug_name", displayLabel: "药名", rawText: "阿莫西林", confidence: 0.93),
            CandidateField(key: "dosage", displayLabel: "剂量", rawText: "0.25g", confidence: 0.88),
        ])
        #expect(!set.isUsableInTimeline)
        let entries = TimelineProjection.entries(from: [set], patientId: UUID(), occurredAt: 0)
        #expect(TimelineProjection.officialTimeline(from: entries).isEmpty)  // 正式区为空
        #expect(TimelineProjection.pendingQueue(from: entries).count == 1)   // 待确认队列可见
        set.confirm(field: set.fields[0].id)
        #expect(!set.isUsableInTimeline)             // 只确认一个字段仍不可入轴
        set.confirm(field: set.fields[1].id)
        #expect(set.isUsableInTimeline)
        let entries2 = TimelineProjection.entries(from: [set], patientId: UUID(), occurredAt: 0)
        #expect(TimelineProjection.officialTimeline(from: entries2).count == 1)
    }

    @Test func 确认后修订产生历史() {
        var f = CandidateField(key: "dosage", displayLabel: "剂量", rawText: "0.25g", confidence: 0.9)
        let confirmed = f.confirm()
        #expect(confirmed)
        let revised = f.revise(to: "0.5g")
        #expect(revised)
        // 修订历史（新→旧）：条目含旧值→新值 + 修订人 + ISO 时间戳
        #expect(f.revisionHistory.count == 1)
        #expect(f.revisionHistory[0].contains("0.25g"))
        #expect(f.revisionHistory[0].contains("0.5g"))
        #expect(f.value == "0.5g")
        let revisedAgain = f.revise(to: "0.5g")
        #expect(!revisedAgain)                        // 同值不产生历史
    }

    @Test func 已拒绝字段不得直接确认() {
        var f = CandidateField(key: "date", displayLabel: "日期", rawText: "2025-01-01", confidence: 0.4)
        f.reject()
        let confirmed = f.confirm()
        #expect(!confirmed)
    }
}

@Suite("M1a · 首启三卡与进度（FR21.9 切片）")
struct OwnerFlowTests {
    @Test func 三卡齐备且完成进度驱动() {
        #expect(DisclosureRegistry.l1Cards.count == 3)
        #expect(Set(DisclosureRegistry.l1Cards.map(\.kind)).count == 3)  // 三卡三类不重复
        var p = OnboardingProgress()
        p.complete(.disclosureL1)
        #expect(!p.finished)
        p.complete(.localOwner)
        p.complete(.selfProfile)
        #expect(p.finished)
    }

    @Test func 本人档案随本机所有者关联() {
        let owner = LocalOwner(displayName: "王女士")
        let profile = PatientProfile(displayName: owner.displayName, relation: "本人")
        var owner2 = owner
        owner2.selfPatientId = profile.id
        #expect(owner2.selfPatientId == profile.id)
    }
}
