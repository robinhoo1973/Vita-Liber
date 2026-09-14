import Foundation
import Testing
@testable import Domain

// binds: SU-M1c-TIMELINE
/// 子项目 J · J2（round1 §E.3 / §E.7 V4–V6）：主卡分组、子卡排序、多重归属、筛选与展开集——纯函数，不触库。
/// 旧平铺投影（`TimelineEntry` / `TimelineProjectionRules`）语义不变，本套件只覆盖新增的层级规则。
@Suite("FR11 时间轴主从分组规则")
struct TimelineHierarchyRulesTests {
    let member = UUID(), enc = UUID(), exam = UUID(), rx = UUID(), lab = UUID(), obs = UUID(), apt = UUID()
    func entry(_ kind: TimelineEntryKind, _ id: UUID, day: Int) -> TimelineEntry {
        TimelineEntry(kind: kind, date: Date(timeIntervalSince1970: Double(day) * 86_400), title: kind.rawValue, summary: nil, refID: id, memberId: member)
    }

    @Test func 子卡挂到主卡并计数_叶子独立_多重归属两处都出现() {
        let rows = [TimelineHubRow(entry: entry(.encounter, enc, day: 10), hub: .encounter),
                    TimelineHubRow(entry: entry(.observation, obs, day: 9), hub: nil),
                    TimelineHubRow(entry: entry(.healthExam, exam, day: 8), hub: .healthExam)]
        let children = [TimelineChildRow(hubId: enc, entry: entry(.prescription, rx, day: 10)),
                        TimelineChildRow(hubId: enc, entry: entry(.labReport, lab, day: 10)),
                        TimelineChildRow(hubId: exam, entry: entry(.labReport, lab, day: 8)),      // 同一表头两处归属
                        TimelineChildRow(hubId: enc, entry: entry(.appointment, apt, day: 24))]    // 复诊预约在未来，不影响主卡位置
        let grouped = TimelineHierarchyRules.group(rows: rows, children: children)
        #expect(grouped.map(\.entry.refID) == [enc, obs, exam], "主卡/叶子顺序 = 输入顺序（游标序），子卡日期不改主卡位置")
        #expect(grouped[0].children.map(\.kind) == [.appointment, .prescription, .labReport], "日期倒序 → 类型序（处方先于检验）")
        #expect(grouped[0].counts == [.appointment: 1, .prescription: 1, .labReport: 1])
        #expect(grouped[1].children.isEmpty && grouped[1].hub == nil)
        #expect(grouped[2].children.map(\.refID) == [lab], "多重归属：检验表头在体检主卡下再次出现")
        #expect(grouped.map(\.isHub) == [true, false, true])
        #expect(grouped[0].id == "encounter-" + grouped[0].entry.id && grouped[1].id == "leaf-" + grouped[1].entry.id && grouped[2].id.hasPrefix("health_exam-"),
                "展开记忆键 = <hub|leaf>-<kind>-<refID>")
    }

    @Test func 同主卡内重复子卡只出现一次_同刻同类按refID倒序_未登记类型排末() {
        let a = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!, b = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!
        let rows = [TimelineHubRow(entry: entry(.encounter, enc, day: 10), hub: .encounter)]
        let children = [TimelineChildRow(hubId: enc, entry: entry(.diagnosis, a, day: 10)),
                        TimelineChildRow(hubId: enc, entry: entry(.diagnosis, a, day: 10)),          // 两条来源查询命中同一行
                        TimelineChildRow(hubId: enc, entry: entry(.diagnosis, b, day: 10)),
                        TimelineChildRow(hubId: enc, entry: entry(.observation, obs, day: 10)),      // 非子卡类型：排到类型序末尾
                        TimelineChildRow(hubId: UUID(), entry: entry(.prescription, rx, day: 10))]   // 孤儿：主卡不在本页 → 丢弃
        let grouped = TimelineHierarchyRules.group(rows: rows, children: children)
        #expect(grouped[0].children.map(\.refID) == [b, a, obs])
        #expect(grouped[0].counts == [.diagnosis: 2, .observation: 1], "计数 = 去重后的子卡数（只数传入的已确认行）")
        #expect(TimelineHierarchyRules.childKindOrder.first == .hospitalization && TimelineHierarchyRules.childKindOrder.last == .document)
        #expect(Set(RecordChildKind.allCases.map(\.timelineKind)).isSubset(of: Set(TimelineHierarchyRules.childKindOrder)), "每个子卡类都有稳定序位")
    }

    @Test func 筛选命中子卡保留其主卡并只留命中项_叶子按自身类型() {
        let grouped = TimelineHierarchyRules.group(
            rows: [TimelineHubRow(entry: entry(.encounter, enc, day: 10), hub: .encounter), TimelineHubRow(entry: entry(.observation, obs, day: 9), hub: nil)],
            children: [TimelineChildRow(hubId: enc, entry: entry(.prescription, rx, day: 10)), TimelineChildRow(hubId: enc, entry: entry(.labReport, lab, day: 10))])
        let visible = TimelineHierarchyRules.visible(grouped, filter: .kinds([.prescription]))
        #expect(visible.count == 1 && visible[0].children.map(\.kind) == [.prescription])
        #expect(visible[0].counts == [.prescription: 1], "计数徽章随筛选收窄")
        #expect(TimelineHierarchyRules.visible(grouped, filter: .kinds([.observation])).map(\.entry.kind) == [.observation])
        #expect(TimelineHierarchyRules.visible(grouped, filter: .kinds([.encounter])).map(\.children.count) == [2], "主卡类型命中 → 整卡保留")
        #expect(TimelineHierarchyRules.visible(grouped, filter: .kinds([.vaccination])).isEmpty)
        #expect(TimelineHierarchyRules.visible(grouped, filter: .all).count == 2)
    }

    @Test func 展开集_默认最新一条_记忆优先_筛选时命中主卡全展开() {
        let a = TimelineHubEntry(hub: .encounter, entry: entry(.encounter, enc, day: 10), children: [entry(.prescription, rx, day: 10)], counts: [.prescription: 1])
        let b = TimelineHubEntry(hub: .healthExam, entry: entry(.healthExam, exam, day: 8), children: [entry(.labReport, lab, day: 8)], counts: [.labReport: 1])
        let leaf = TimelineHubEntry(hub: nil, entry: entry(.observation, obs, day: 9), children: [], counts: [:])
        #expect(TimelineHierarchyRules.expanded([a, b], filter: .all, remembered: { _ in nil }) == [a.id], "无记忆：仅最新主卡展开")
        #expect(TimelineHierarchyRules.expanded([leaf, a, b], filter: .all, remembered: { _ in nil }) == [a.id], "叶子不参与「最新主卡」判定")
        #expect(TimelineHierarchyRules.expanded([a, b], filter: .all, remembered: { $0 == a.id ? false : nil }) == [], "记忆折叠优先于默认展开")
        #expect(TimelineHierarchyRules.expanded([a, b], filter: .all, remembered: { $0 == b.id ? true : nil }) == [a.id, b.id], "记忆展开叠加默认展开")
        #expect(TimelineHierarchyRules.expanded([a, b], filter: .kinds([.labReport]), remembered: { _ in false }) == [b.id], "筛选：命中子卡的主卡瞬态展开、不写记忆")
        let narrowed = TimelineHierarchyRules.visible([a, b], filter: .kinds([.labReport]))
        #expect(TimelineHierarchyRules.expanded(narrowed, filter: .kinds([.labReport]), remembered: { _ in false }) == [b.id])
    }

    @Test func 子卡类到时间轴类型与卡类字符串映射_预约提醒原件无卡类() {
        #expect(RecordChildKind.immunization.timelineKind == .vaccination && RecordChildKind.labReport.timelineKind == .labReport)
        #expect(RecordChildKind.treatmentRecord.cardKind == "treatment_record" && RecordChildKind.claim.cardKind == "claim_item" && RecordChildKind.labReport.cardKind == "lab_report")
        #expect(RecordChildKind.appointment.cardKind == nil && RecordChildKind.reminder.cardKind == nil && RecordChildKind.document.cardKind == nil)
        #expect(RecordHub.healthExam.rawValue == "health_exam" && RecordHub.allCases.count == 3)
        #expect(TimelineEntryKind.allCases.count == 22, "十类既有 + 十二类子卡/主卡（J3 SQL kind 字面量与 J4 L10n 键随 rawValue）")
        for raw in ["hospitalization", "healthExam", "diagnosis", "prescription", "labReport", "examReport", "claim", "surgery", "treatmentRecord", "appointment", "reminder", "clinicalConclusion"] {
            #expect(TimelineEntryKind(rawValue: raw) != nil, "\(raw)")
        }
        let page = TimelineHubPage(entries: [], nextCursor: TimelineCursor(date: Date(timeIntervalSince1970: 1), refID: enc))
        #expect(page.entries.isEmpty && page.nextCursor?.refID == enc)
    }
}
