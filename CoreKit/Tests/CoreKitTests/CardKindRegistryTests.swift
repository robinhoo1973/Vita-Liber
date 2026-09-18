import Foundation
import Testing
@testable import Domain

// binds: SU-M2-PENDINGCARD
/// 子项目 D · D1-2：`CardKindRegistry` 为卡类 allowed 集/实体表/可选目录的单一事实源；
/// 处方/费用意图产出「表头 + 行」（不再把药品行折叠进 advice_text）；就诊草稿携带五叙事列；
/// 目录（可选键）与门槛（`CompletenessEvaluator.rules`）分离。纯 Domain，Linux 可跑。
@Suite("FR6.9 · 卡类注册表 = allowed 集单一事实源；处方行不再拼串")
struct CardKindRegistryTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    // MARK: - 注册表

    /// 原名：注册表覆盖六卡类且实体表首元素为表头
    @Test func registryCoversSixCardKindsWithHeaderTableFirst() {
        for kind in ["metric_sample", "encounter", "prescription", "claim_item", "medication", "immunization"] {
            let e = CardKindRegistry.entry(for: kind)
            #expect(e?.entityTables.first == kind, "\(kind)")
            #expect(e?.headerTable == kind, "\(kind)")
        }
        #expect(CardKindRegistry.entry(for: "prescription")?.entityTables == ["prescription", "prescription_line"])
        #expect(CardKindRegistry.entry(for: "claim_item")?.entityTables == ["claim_item", "claim_line"])
        #expect(CardKindRegistry.entry(for: "appointment") == nil, "无提取器卡类不登记")
        #expect(CardKindRegistry.entries.map(\.kind) == CardKindRegistry.entries.map(\.kind).uniqued(), "kind 唯一")
    }

    /// 原名：可选目录剔除已有键且不含必填
    @Test func optionalCatalogExcludesPresentAndRequiredKeys() {
        let catalog = CardKindRegistry.optionalCatalog(kind: "prescription", present: ["drug_name", "spec"], rowLevel: true)
        #expect(catalog.contains("medication_notes") && catalog.contains("drug_form") && !catalog.contains("spec") && !catalog.contains("drug_name"))
        #expect(catalog == catalog.sorted(), "目录稳定有序")
        #expect(CardKindRegistry.optionalCatalog(kind: "encounter", present: [], rowLevel: false).contains("past_history"))
        // 共享面目录只列表头键：行级键（dosage/medication_notes…）虽被共享面容忍（匹配器无法唯一归行时上浮），
        // 但补录入口在行内，不进表头「添加字段」菜单。
        let header = CardKindRegistry.optionalCatalog(kind: "prescription", present: ["hospital"], rowLevel: false)
        #expect(header.contains("prescription_no") && header.contains("department") && !header.contains("dosage") && !header.contains("hospital"))
        #expect(CardKindRegistry.optionalCatalog(kind: "unknown", present: [], rowLevel: false).isEmpty)
    }

    /// 原名：模板键集不越出注册表allowed集
    @Test func templateKeysStayWithinRegistryAllowedSets() throws {
        for template in CardTemplateMatcher.ocrTemplates {
            guard let entry = CardKindRegistry.entry(for: template.kind) else { continue }
            #expect(template.requiresDocumentType == entry.requiresDocumentType, "\(template.kind)")
            #expect(template.allowsEmptyRows == entry.allowsEmptyRows, "\(template.kind)")
            #expect(template.rowLevelKeys.isSubset(of: entry.rowAllowed), "\(template.kind)")
            // 检验卡 lab_item/reference_range 为匹配器拆分前的中间键，不进 allowed 集。
            let mapped = Set(template.mapping.values).subtracting(["lab_item", "reference_range"])
            #expect(mapped.isSubset(of: entry.sharedAllowed.union(entry.rowAllowed)), "\(template.kind): \(mapped.subtracting(entry.sharedAllowed.union(entry.rowAllowed)))")
        }
        #expect(CardKindRegistry.entry(for: "claim_item")?.allowsEmptyRows == true)
        #expect(CardKindRegistry.entry(for: "prescription")?.allowsEmptyRows == false)
    }

    // MARK: - 处方：表头 + 行

    /// 原名：处方意图产出行而非拼接医嘱
    @Test func prescriptionIntentProducesLinesInsteadOfFoldedAdvice() throws {
        var card = MatchedCard(kind: "prescription", pageIndex: 0, shared: [.init(key: "prescribed_at", value: "2020-01-02"), .init(key: "advice_text", value: "饭后服")],
            rows: [MatchedCardRow(fields: [.init(key: "drug_name", value: "阿莫西林"), .init(key: "dosage", value: "0.5", unit: "g"), .init(key: "days", value: "7")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete)
        card = card.fullyConfirmed()
        let intent = try #require(EntityCardProjection.prescriptionIntent(from: card))
        #expect(intent.adviceText == "饭后服")                                   // 不再折叠药品行
        #expect(intent.lines.count == 1 && intent.lines[0].line.printedName == "阿莫西林" && intent.lines[0].line.doseText == "0.5" && intent.lines[0].line.doseUnit == "g" && intent.lines[0].line.durationText == "7")
        #expect(intent.lines[0].rowId == card.rows[0].id)
        #expect(intent.lines[0].line.sourceRowId == card.rows[0].id && intent.lines[0].line.sourcePage == 0)
        #expect(intent.lines[0].line.confirmed == false, "BR-003：D 级草稿，confirmed 由 store 提交时置 1")
        #expect(intent.lines[0].line.prescriptionId == PrescriptionLine.unassignedId && intent.lines[0].line.patientId == PrescriptionLine.unassignedId)
    }

    /// 原名：处方无共享医嘱时adviceText为空串
    @Test func prescriptionWithoutSharedAdviceHasEmptyAdviceText() throws {
        let card = MatchedCard(kind: "prescription", pageIndex: 0, shared: [.init(key: "prescribed_at", value: "2020-01-02")],
            rows: [MatchedCardRow(fields: [.init(key: "drug_name", value: "A")]), MatchedCardRow(fields: [.init(key: "drug_name", value: "B")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).fullyConfirmed()
        let intent = try #require(EntityCardProjection.prescriptionIntent(from: card))
        #expect(intent.adviceText == "")
        #expect(intent.lines.map(\.line.printedName) == ["A", "B"])
        #expect(intent.lines.map(\.line.ordinal) == [0, 1])
    }

    /// 原名：处方表头七列与行文本单位原样
    @Test func prescriptionHeaderAndLineTextKeptVerbatim() throws {
        let card = MatchedCard(kind: "prescription", pageIndex: 3,
            shared: [.init(key: "prescribed_at", value: "2020-01-02"), .init(key: "department", value: "内科"), .init(key: "prescription_no", value: "RX-001"),
                     .init(key: "prescription_type", value: "tcm"), .init(key: "fee_type", value: "医保"), .init(key: "clinical_diagnosis", value: "上呼吸道感染"),
                     .init(key: "pharmacist_names", value: "李药师/王药师"), .init(key: "total_amount", value: "128.5")],
            rows: [MatchedCardRow(fields: [.init(key: "drug_name", value: "阿莫西林胶囊", rawText: "1 阿莫西林胶囊 0.25g×24 2盒"),
                                           .init(key: "spec", value: "0.25g×24", rawText: "1 阿莫西林胶囊 0.25g×24 2盒"),
                                           .init(key: "quantity", value: "2", unit: "盒", rawText: "1 阿莫西林胶囊 0.25g×24 2盒"),
                                           .init(key: "frequency", value: "每日三次", rawText: "用法：每日三次 口服"),
                                           .init(key: "route", value: "口服", rawText: "用法：每日三次 口服"),
                                           .init(key: "drug_form", value: "胶囊"), .init(key: "medication_notes", value: "贮藏：避光"),
                                           .init(key: "start_date", value: "2020-01-02"), .init(key: "unit_price", value: "12.5"), .init(key: "line_amount", value: "25")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).fullyConfirmed()
        let intent = try #require(EntityCardProjection.prescriptionIntent(from: card))
        #expect(intent.department == "内科" && intent.prescriptionNo == "RX-001" && intent.prescriptionType == "tcm" && intent.feeTypeText == "医保")
        #expect(intent.clinicalDiagnosis == "上呼吸道感染" && intent.pharmacistNames == "李药师/王药师" && intent.totalAmount == 128.5)
        let line = try #require(intent.lines.first?.line)
        #expect(line.spec == "0.25g×24" && line.quantityText == "2" && line.quantityUnit == "盒")
        #expect(line.frequencyText == "每日三次" && line.routeText == "口服" && line.drugForm == "胶囊" && line.medicationNotes == "贮藏：避光")
        #expect(line.doseText == nil && line.doseUnit == nil, "无剂量字段不补、不推算（BR-006）")
        // prescriptionIntent(from:) 签名不变：按本地公历零点解析（与 prescribedAt 同历）
        #expect(line.startDate == Calendar(identifier: .gregorian).date(from: DateComponents(year: 2020, month: 1, day: 2)) && line.endDate == nil)
        #expect(line.unitPrice == 12.5 && line.amount == 25)
        #expect(line.rawText == "1 阿莫西林胶囊 0.25g×24 2盒\n用法：每日三次 口服", "行原文按字段原文去重拼接")
        #expect(line.sourcePage == 3)
    }

    /// 原名：处方类型与金额日期键非法时判无效
    @Test func invalidPrescriptionTypeAmountAndDateKeysAreRejected() {
        func card(shared: [FieldDraft], row: [FieldDraft]) -> MatchedCard {
            MatchedCard(kind: "prescription", pageIndex: 0, shared: [FieldDraft(key: "prescribed_at", value: "2020-01-02")] + shared,
                        rows: [MatchedCardRow(fields: [FieldDraft(key: "drug_name", value: "A")] + row)],
                        allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).fullyConfirmed()
        }
        let badType = card(shared: [.init(key: "prescription_type", value: "中药")], row: [])
        #expect(EntityCardProjection.invalidFields(in: badType, row: badType.rows[0], calendar: utc) == ["prescription_type"])
        let badAmount = card(shared: [.init(key: "total_amount", value: "壹佰")], row: [.init(key: "unit_price", value: "12.5元")])
        #expect(EntityCardProjection.invalidFields(in: badAmount, row: badAmount.rows[0], calendar: utc) == ["total_amount", "unit_price"])
        let badDate = card(shared: [], row: [.init(key: "end_date", value: "三天后")])
        #expect(EntityCardProjection.invalidFields(in: badDate, row: badDate.rows[0], calendar: utc) == ["end_date"])
        let ok = card(shared: [.init(key: "prescription_type", value: "general"), .init(key: "total_amount", value: "99")], row: [.init(key: "line_amount", value: "-12.5")])
        #expect(EntityCardProjection.invalidFields(in: ok, row: ok.rows[0], calendar: utc).isEmpty)
    }

    /// 原名：处方行值类型Codable往返
    @Test func prescriptionLineValueTypeCodableRoundTrip() throws {
        let line = PrescriptionLine(id: UUID(), prescriptionId: UUID(), patientId: UUID(), ordinal: 2, printedName: "A",
                                    doseText: "0.5", doseUnit: "g", startDate: Date(timeIntervalSince1970: 86_400), unitPrice: 1.5,
                                    sourcePage: 1, sourceRowId: UUID(), confirmed: true,
                                    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
        let data = try JSONEncoder().encode(line)
        #expect(try JSONDecoder().decode(PrescriptionLine.self, from: data) == line)
    }

    // MARK: - 费用：表头 + 行

    /// 原名：费用意图票据页空行沿旧路径且清单页产行
    @Test func claimIntentKeepsEmptyInvoiceRowWhileItemizedPageYieldsLines() throws {
        let invoice = MatchedCard(kind: "claim_item", pageIndex: 0,
            shared: [.init(key: "amount", value: "128.5"), .init(key: "currency", value: "CNY"), .init(key: "date", value: "2020-01-02"), .init(key: "item_type", value: "invoice"),
                     .init(key: "merchant", value: "市一医院"), .init(key: "invoice_no", value: "No.0001"), .init(key: "insurance_type", value: "城镇职工"),
                     .init(key: "reimbursed_amount", value: "100"), .init(key: "out_of_pocket", value: "20.5"), .init(key: "personal_account_amount", value: "8")],
            rows: [MatchedCardRow(fields: [])], allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).fullyConfirmed()
        #expect(EntityCardProjection.invalidFields(in: invoice, row: invoice.rows[0], calendar: utc).isEmpty, "票据页空行仍有效（表头即实体）")
        let header = try #require(EntityCardProjection.claimIntent(from: invoice, calendar: utc))
        #expect(header.lines.isEmpty && header.amount == 128.5 && header.currency == "CNY" && header.itemType == "invoice" && header.merchant == "市一医院")
        #expect(header.invoiceNo == "No.0001" && header.insuranceTypeText == "城镇职工")
        #expect(header.reimbursedAmount == 100 && header.outOfPocket == 20.5 && header.personalAccountAmount == 8)
        #expect(header.date == utc.date(from: DateComponents(year: 2020, month: 1, day: 2)))

        let list = MatchedCard(kind: "claim_item", pageIndex: 1,
            shared: [.init(key: "amount", value: "30"), .init(key: "currency", value: "CNY"), .init(key: "date", value: "2020-01-02"), .init(key: "item_type", value: "fee")],
            rows: [MatchedCardRow(fields: [.init(key: "item_name", value: "血常规", rawText: "血常规 25.00 1 次 25.00"), .init(key: "unit_price", value: "25", rawText: "血常规 25.00 1 次 25.00"),
                                           .init(key: "item_quantity", value: "1", unit: "次", rawText: "血常规 25.00 1 次 25.00"), .init(key: "item_amount", value: "25", rawText: "血常规 25.00 1 次 25.00"),
                                           .init(key: "fee_category", value: "检验费"), .init(key: "executing_dept", value: "检验科"), .init(key: "self_pay_ratio", value: "10%"), .init(key: "fee_at", value: "2020-01-02")]),
                   MatchedCardRow(fields: [.init(key: "item_name", value: "退费"), .init(key: "item_amount", value: "-5")])],
            allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).fullyConfirmed()
        let intent = try #require(EntityCardProjection.claimIntent(from: list, calendar: utc))
        #expect(intent.lines.count == 2 && intent.lines[0].rowId == list.rows[0].id)
        let line = intent.lines[0]
        #expect(line.itemName == "血常规" && line.unitPrice == 25 && line.quantityText == "1" && line.quantityUnit == "次" && line.amount == 25)
        #expect(line.feeCategoryText == "检验费" && line.executingDept == "检验科" && line.selfPayRatioText == "10%")
        #expect(line.feeAt == utc.date(from: DateComponents(year: 2020, month: 1, day: 2)))
        #expect(line.rawText == "血常规 25.00 1 次 25.00")
        #expect(intent.lines[1].amount == -5, "退费行按票面负数原样")
    }

    /// 原名：费用行有字段即须item_name且金额可解析
    @Test func claimRowsWithFieldsRequireItemNameAndParsableAmount() {
        func card(_ row: [FieldDraft]) -> MatchedCard {
            MatchedCard(kind: "claim_item", pageIndex: 0,
                shared: [.init(key: "amount", value: "30"), .init(key: "currency", value: "CNY"), .init(key: "date", value: "2020-01-02"), .init(key: "item_type", value: "fee")],
                rows: [MatchedCardRow(fields: row)], allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).fullyConfirmed()
        }
        let noName = card([.init(key: "item_amount", value: "25")])
        #expect(EntityCardProjection.invalidFields(in: noName, row: noName.rows[0], calendar: utc) == ["item_name"])
        let badAmount = card([.init(key: "item_name", value: "A"), .init(key: "item_amount", value: "25元")])
        #expect(EntityCardProjection.invalidFields(in: badAmount, row: badAmount.rows[0], calendar: utc) == ["item_amount"])
        let badShared = MatchedCard(kind: "claim_item", pageIndex: 0,
            shared: [.init(key: "amount", value: "30"), .init(key: "currency", value: "CNY"), .init(key: "date", value: "2020-01-02"), .init(key: "item_type", value: "fee"),
                     .init(key: "personal_account_amount", value: "八元")],
            rows: [MatchedCardRow(fields: [])], allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).fullyConfirmed()
        #expect(EntityCardProjection.invalidFields(in: badShared, row: badShared.rows[0], calendar: utc) == ["personal_account_amount"])
        #expect(EntityCardProjection.claimIntent(from: badShared, calendar: utc) == nil)
    }

    // MARK: - 就诊叙事

    /// 原名：就诊草稿携带五叙事列且允许allergy_history
    @Test func encounterDraftCarriesFiveNarrativeColumnsAndAllowsAllergyHistory() {
        let card = MatchedCard(kind: "encounter", pageIndex: 0, shared: [.init(key: "date", value: "2020-01-02"), .init(key: "kind", value: "outpatient"), .init(key: "past_history", value: "高血压 10 年"), .init(key: "allergy_history", value: "青霉素")], rows: [MatchedCardRow(fields: [])], allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).fullyConfirmed()
        #expect(EntityCardProjection.invalidFields(in: card, row: card.rows[0], calendar: .init(identifier: .gregorian)).isEmpty)
        #expect(EntityCardProjection.encounterDraft(from: card, patientId: UUID(), calendar: .init(identifier: .gregorian))?.allergyHistory == "青霉素")
        let full = MatchedCard(kind: "encounter", pageIndex: 0,
            shared: [.init(key: "date", value: "2020-01-02"), .init(key: "kind", value: "outpatient"), .init(key: "present_illness", value: "咳嗽 3 天"),
                     .init(key: "visit_summary", value: "对症处理"), .init(key: "past_history", value: "高血压"), .init(key: "physical_exam", value: "T 36.8℃"), .init(key: "allergy_history", value: "无")],
            rows: [MatchedCardRow(fields: [])], allFieldCoverage: 1, requiredCoverage: 1, missingRequired: [], level: .complete).fullyConfirmed()
        let draft = EntityCardProjection.encounterDraft(from: full, patientId: UUID(), calendar: utc)
        #expect(draft?.presentIllness == "咳嗽 3 天" && draft?.visitSummary == "对症处理" && draft?.pastHistory == "高血压")
        #expect(draft?.physicalExam == "T 36.8℃" && draft?.allergyHistory == "无")
        let manual = EncounterDraft(patientId: UUID())
        #expect(manual.presentIllness == nil && manual.pastHistory == nil, "既有 init 调用点零改：五列默认 nil")
    }

    // MARK: - D1-5 处方行详情路由

    /// 原名：处方行详情路由可编解码且归档案Tab
    @Test func prescriptionLineRouteIsCodableAndBelongsToRecordsTab() throws {
        // §5.45 路由注册表：行详情深链（患者 + 行 id）Codable 往返（AppRouter 持久化 path / 通知 userInfo）；
        // 所属 Tab 与 .medicalCard 同为档案（records）。
        let route = AppRoute.prescriptionLine(patientId: UUID(), lineId: UUID())
        let data = try JSONEncoder().encode(route)
        #expect(try JSONDecoder().decode(AppRoute.self, from: data) == route)
        #expect(MainModuleID.tab(of: route) == .records)
        #expect(route != AppRoute.prescriptionLine(patientId: UUID(), lineId: UUID()), "不同行 id 为不同路由")
    }

    // MARK: - 目录与门槛分离

    /// 原名：可选目录不改变建卡门槛
    @Test func optionalCatalogDoesNotChangeCardThresholds() {
        // FR6.9 双阈值不变：规则表（分母）不登记任何新可选键；可选键只活在注册表目录。
        for kind in ["prescription", "encounter", "claim_item"] {
            let ruleKeys = Set(CompletenessEvaluator.rules(for: kind).map(\.key))
            let catalog = Set(CardKindRegistry.optionalCatalog(kind: kind, present: [], rowLevel: false) + CardKindRegistry.optionalCatalog(kind: kind, present: [], rowLevel: true))
            for key in ["past_history", "physical_exam", "allergy_history", "medication_notes", "drug_form", "prescription_no", "invoice_no", "item_name", "personal_account_amount"] where catalog.contains(key) {
                #expect(!ruleKeys.contains(key), "\(kind).\(key) 不进规则表")
            }
        }
        #expect(CompletenessEvaluator.rules(for: "prescription").count == 5)
        #expect(CompletenessEvaluator.rules(for: "encounter").count == 6)
        #expect(CompletenessEvaluator.rules(for: "claim_item").count == 8)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
