import Foundation
import Testing
@testable import Domain

/// 跨卡共用信息池（业主 2026-09-17 裁定）：入池规则 A∨B、同键同值归并、出池回填、离场闸门。
@Suite("SU-FR6.9 · 共用信息池（跨卡字段的汇集与回填）")
struct SharedFieldPoolTests {

    private func field(_ key: String, _ value: String, confidence: Double = 0.9,
                       grade: SourceGrade = .ocrUnconfirmed, unit: String? = nil,
                       rawText: String? = nil) -> FieldDraft {
        FieldDraft(key: key, value: value, unit: unit, confidence: confidence, rawText: rawText, grade: grade)
    }

    private func card(_ kind: String, shared: [FieldDraft], rows: [MatchedCardRow] = [MatchedCardRow(fields: [])],
                      hub: RecordHub? = nil, draftFields: [FieldDraft] = []) -> MatchedCard {
        let association: EncounterAssociation = hub.map {
            .newHub(HubDraft(hub: $0, fields: draftFields, evidence: "hospital"))
        } ?? .unselected
        return MatchedCard(kind: kind, pageIndex: 0, shared: shared, rows: rows,
                           allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete,
                           encounterAssociation: association)
    }

    @Test("A 跨卡重复同值 → 归并一行，承载方齐全（同一医院两卡只确认一次）")
    func 跨卡同值归并() {
        let prescription = card("prescription", shared: [field("hospital", "市一院")])
        let claim = card("claim_item", shared: [field("hospital", "市一院")])
        let rows = SharedFieldPool.rows(cards: [prescription, claim])
        let hospital = rows.filter { $0.key == "hospital" }
        #expect(hospital.count == 1, "同值归并成一行；实得 \(rows.map(\.key))")
        #expect(hospital.first?.carriers.count == 2, "两个承载方")
        #expect(hospital.first?.repeatedAcrossCards == true, "入池原因 = 跨卡重复")
    }

    @Test("同键不同值 → 各成一行，不强行合并（两卡的医院真不一样）")
    func 同键不同值不合并() {
        let a = card("prescription", shared: [field("hospital", "市一院")])
        let b = card("claim_item", shared: [field("hospital", "市二院")])
        let rows = SharedFieldPool.rows(cards: [a, b])
        let hospital = rows.filter { $0.key == "hospital" }
        #expect(hospital.count == 2, "同键不同值各成一行；实得 \(hospital.map(\.value))")
        #expect(hospital.allSatisfy { $0.carriers.count == 1 }, "各自只挂自己的卡")
    }

    @Test("单卡且全高置信 → 不入池（共用页不出现）")
    func 单卡零入池() {
        let single = card("encounter", shared: [field("date", "2026-09-16"), field("kind", "outpatient"),
                                                field("hospital", "市一院")])
        #expect(SharedFieldPool.rows(cards: [single]).isEmpty, "无重复、无低置信必填 → 池为空")
    }

    @Test("单卡缺必填 → 不入池（保持卡内「缺少 X，点此填写」原路；多卡才上公用页）")
    func 单卡缺失不入池() {
        let single = card("encounter", shared: [field("kind", "outpatient", confidence: 1)])
        #expect(SharedFieldPool.rows(cards: [single]).isEmpty, "单卡不因缺失必填而多开一页")
    }

    @Test("单卡必填但值为空 → 也不入池（「单卡的卡内操作」；低置信才入）")
    func 单卡空值不入池() {
        let emptied = card("encounter", shared: [field("kind", "", confidence: 1),
                                                 field("date", "2026-09-16", confidence: 1)])
        #expect(SharedFieldPool.rows(cards: [emptied]).isEmpty, "空值（非低置信）留卡内；实得 \(SharedFieldPool.rows(cards: [emptied]).map(\.key))")
        let lowConfidence = card("encounter", shared: [field("kind", "", confidence: 0.3),
                                                       field("date", "2026-09-16", confidence: 1)])
        #expect(SharedFieldPool.rows(cards: [lowConfidence]).map(\.key) == ["kind"], "低置信的必填（哪怕空值）入池")
    }

    @Test("B 只被一张卡携带：高置信可选不入池；必填低置信入池（critical）")
    func 单卡入池规则() {
        // doctor 可选高置信（0.9）→ 不入池；date 必填低置信（0.4）→ 入池
        let single = card("encounter", shared: [field("doctor", "张三"), field("kind", "outpatient"),
                                                field("date", "2026-09-16", confidence: 0.4)])
        let rows = SharedFieldPool.rows(cards: [single])
        #expect(rows.map(\.key) == ["date"], "只有必填低置信的 date 入池；实得 \(rows.map(\.key))")
        #expect(rows[0].criticalLowConfidence && !rows[0].repeatedAcrossCards, "原因如实标注")
    }

    @Test("B 共享面缺席的必填键 → 空值入池，且「未处理完」闸门如实拦住")
    func 缺席必填入池() {
        // 两张卡都缺 date（多卡才上公用页；单卡见「单卡缺失不入池」）
        let a = card("encounter", shared: [field("kind", "outpatient", confidence: 1)])
        let b = card("encounter", shared: [field("kind", "outpatient", confidence: 1)])
        let rows = SharedFieldPool.rows(cards: [a, b])
        guard let date = rows.first(where: { $0.key == "date" }) else {
            Issue.record("缺席的必填 date 应入池；实得 \(rows.map(\.key))"); return
        }
        #expect(date.value.isEmpty && date.required, "空值 + 必填")
        #expect(date.carriers.count == 2, "两张卡同缺 → 归并一行两承载方")
        #expect(!SharedFieldPool.isSettled(rows), "空值无法确认 → 未处理完（离场只能是稍后处理）")
        #expect(SharedFieldPool.awaitingCount(rows) >= 1)
    }

    @Test("多卡同缺同一关键字段 → 归并一行、多承载方；补填一次即同时补进每张卡")
    func 多卡同缺归并() {
        // 两张就诊卡都没识别出 date（缺失的必填键），一张有 kind 一张没有
        let a = card("encounter", shared: [field("kind", "outpatient", confidence: 1)])
        let b = card("encounter", shared: [field("doctor", "张三")])
        var rows = SharedFieldPool.rows(cards: [a, b])
        let dateRows = rows.filter { $0.key == "date" }
        #expect(dateRows.count == 1, "同缺的 date 归并成一行；实得 \(dateRows.count) 行")
        #expect(dateRows[0].carriers.count == 2, "两个承载方同在一行")
        #expect(dateRows[0].value.isEmpty && dateRows[0].required, "空值 + 必填；kind 亦然")

        // 用户在公用页补填一次并确认 → 两张卡同时拿到
        for index in rows.indices where rows[index].key == "date" {
            _ = rows[index].field.fillByUser("2026-09-16")
        }
        let projected = SharedFieldPool.project(rows, into: [a, b])
        #expect(projected[0].shared.first { $0.key == "date" }?.isConfirmed == true, "A 卡补上")
        #expect(projected[1].shared.first { $0.key == "date" }?.isConfirmed == true, "B 卡补上（一次填写，两张生效）")
    }

    @Test("出池回填：确认后的值写回承载方，且不动承载方自己的来源（rawText/锚定）")
    func 回填全承载方() {
        // A 有低置信的 kind（必填、带来源）；B 缺 kind（→ 空值入池）；两张卡都缺 date
        let a = card("encounter", shared: [field("kind", "outpatient", confidence: 0.4, rawText: "门诊 门诊病历")])
        let b = card("encounter", shared: [field("doctor", "李四")])
        var rows = SharedFieldPool.rows(cards: [a, b])

        guard let aKind = rows.firstIndex(where: { $0.key == "kind" && $0.carriers.contains { $0.cardId == a.id } }),
              let bKind = rows.firstIndex(where: { $0.key == "kind" && $0.carriers.contains { $0.cardId == b.id } }),
              let dateIndex = rows.firstIndex(where: { $0.key == "date" }) else {
            Issue.record("kind 两行 + date 一行应在池中；实得 \(rows.map { "\($0.key)=\($0.value)" })"); return
        }
        #expect(aKind != bKind, "同键不同值不合并：A 有值、B 缺失各成一行")
        _ = rows[aKind].field.confirm()                  // A：认下识别值（低置信也须显式）
        _ = rows[bKind].field.fillByUser("outpatient")   // B：手填即确认
        _ = rows[dateIndex].field.fillByUser("2026-09-16")
        #expect(SharedFieldPool.isSettled(rows), "全部处理完才可离场")

        let projected = SharedFieldPool.project(rows, into: [a, b])
        #expect(projected[0].shared.first { $0.key == "kind" }?.isConfirmed == true, "承载方 A 拿到确认态")
        #expect(projected[0].shared.first { $0.key == "kind" }?.rawText == "门诊 门诊病历",
                "承载方自己的来源（rawText/锚定）不被合并行覆盖")
        #expect(projected[1].shared.first { $0.key == "kind" }?.value == "outpatient", "B 的缺失键被补建")
        #expect(projected[1].shared.first { $0.key == "date" }?.isConfirmed == true, "B 的 date 补上")
        #expect(projected[0].shared.first { $0.key == "date" }?.isConfirmed == true, "A 的 date 也补上——一次填写两卡生效")
        #expect(projected[0].shared.contains { $0.key == "doctor" } == false, "A 不是 doctor 的承载方，不被写入")
    }

    @Test("票据卡：多个必填键缺失时一次补齐（金额/币种/类型都在公用页）")
    func 票据卡多键补缺() {
        let claim = card("claim_item", shared: [field("date", "2026-09-16", confidence: 1)])
        let other = card("prescription", shared: [field("prescribed_at", "2026-09-16", confidence: 1)])
        var rows = SharedFieldPool.rows(cards: [claim, other])
        let claimMissing = Set(rows.filter { $0.value.isEmpty && $0.required }.map(\.key))
        #expect(claimMissing.isSuperset(of: ["amount", "currency", "item_type"]),
                "票据卡的三个必填缺失键都上公用页；实得 \(rows.filter { $0.value.isEmpty }.map(\.key))")
        #expect(!SharedFieldPool.isSettled(rows), "未补齐 → 未处理完")
        for i in rows.indices where rows[i].value.isEmpty { _ = rows[i].field.fillByUser("占位值") }
        #expect(SharedFieldPool.isSettled(rows), "逐项补齐后可离场")
    }

    @Test("行级与主卡草稿同样是承载方（低置信的检验值 / 草稿日期）")
    func 行级与草稿承载方() {
        let labRow = MatchedCardRow(fields: [field("raw_label", "血红蛋白"), field("value", "150", confidence: 0.3)])
        let lab = card("metric_sample", shared: [field("measured_at", "2026-09-16", confidence: 1)], rows: [labRow])
        let draft = card("prescription", shared: [field("prescribed_at", "2026-09-16", confidence: 1)],
                         hub: .encounter, draftFields: [field("date", "2026-09-16", confidence: 0.3),
                                                        field("kind", "outpatient", confidence: 1)])
        let rows = SharedFieldPool.rows(cards: [lab, draft])
        #expect(rows.contains { $0.key == "value" && $0.carriers.first?.face != nil }, "低置信行级必填值入池")
        let draftRows = rows.filter { $0.carriers.contains { $0.face == .hubDraft } }
        #expect(draftRows.map(\.key) == ["date"], "草稿的必填低置信日期入池；实得 \(draftRows.map(\.key))")

        var mutableRows = rows
        for index in mutableRows.indices where mutableRows[index].key == "date" { _ = mutableRows[index].field.confirm() }
        let projected = SharedFieldPool.project(mutableRows, into: [lab, draft])
        guard case .newHub(let outDraft) = projected[1].encounterAssociation else {
            Issue.record("草稿应保留"); return
        }
        #expect(outDraft.fields.first { $0.key == "date" }?.isConfirmed == true, "草稿日期拿到确认态 → isComplete 不再被它挡住")
    }

    @Test("拒绝字段不入池（拒绝是已裁决，不是待办）")
    func 拒绝不入池() {
        var rejected = field("hospital", "市一院")
        rejected.reject()
        let a = card("prescription", shared: [rejected, field("prescribed_at", "2026-09-16", confidence: 1)])
        let b = card("claim_item", shared: [field("prescribed_at", "2026-09-16", confidence: 1)])
        let rows = SharedFieldPool.rows(cards: [a, b])
        #expect(!rows.contains { $0.key == "hospital" }, "被拒绝的 hospital 不入池；实得 \(rows.map(\.key))")
    }
}
