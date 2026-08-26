import Foundation
import Testing
@testable import Domain

/// M1a 纵向切片 · Domain 层验收用例（dev-pm §3.2.1 退出准则的 U 半场）
@Suite("M1a · 门禁锁定阶梯（§5.32/FR1.3）")
struct PinLockTests {
    /// 可注入时钟：测试控制「现在」
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        init(_ start: Date) { _now = start }
        func advance(_ s: TimeInterval) { lock.lock(); defer { lock.unlock() }; _now = _now.addingTimeInterval(s) }
        var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    }

    @Test func 五次失败锁定30秒且计数打满复位() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 0))
        let m = try await PinLockStateMachine(storage: InMemoryPinLockStore(), now: { clock.now })
        var lockout: TimeInterval = 0
        for _ in 0..<5 { lockout = try await m.recordFailure() }
        #expect(lockout == 30)
        #expect(await m.isLocked)
        #expect(await m.remainingLockSeconds == 30)
        #expect(await m.consecutiveFailures == 0)   // 打满后计数复位（下一阶梯重新累计）
    }

    @Test func 再满一轮升阶至2分钟() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 0))
        let m = try await PinLockStateMachine(storage: InMemoryPinLockStore(), now: { clock.now })
        var lockout: TimeInterval = 0
        for _ in 0..<5 { lockout = try await m.recordFailure() }
        #expect(lockout == 30)
        clock.advance(31)                              // 锁定自然过期
        for _ in 0..<5 { lockout = try await m.recordFailure() }
        #expect(lockout == 120)                        // 阶梯升阶
    }

    @Test func 成功复位计数与阶梯() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 0))
        let store = InMemoryPinLockStore()
        let m = try await PinLockStateMachine(storage: store, now: { clock.now })
        for _ in 0..<4 { _ = try await m.recordFailure() }
        #expect(await m.consecutiveFailures == 4)
        try await m.recordSuccess()
        #expect(await m.consecutiveFailures == 0)
        #expect(await m.isLocked == false)
    }

    @Test func 锁定跨重启保持() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 0))
        let store = InMemoryPinLockStore()
        let m1 = try await PinLockStateMachine(storage: store, now: { clock.now })
        for _ in 0..<5 { _ = try await m1.recordFailure() }
        #expect(await m1.isLocked)
        let m2 = try await PinLockStateMachine(storage: store, now: { clock.now })  // 重启=同存储重建
        #expect(await m2.isLocked)                   // 锁定跨重启保持（FR1.3 用例）
        clock.advance(31)
        #expect(await m2.isLocked == false)          // 过期自然解除
    }
}

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
        #expect(f.revisionHistory == ["0.25g"])       // 旧值入历史（新→旧）
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
