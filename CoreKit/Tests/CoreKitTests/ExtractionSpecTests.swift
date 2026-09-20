import Foundation
import Testing
@testable import Domain

/// 子项目 E2（2026-09-14 实施计划 Task E2 / design §4.2–§4.6）：`ExtractionSpec` 注册表、`ExtractedCard`、
/// 轨道无关 grounding、`PageLayout.extractionRegions`、`FieldDraftAdapter`。仅 `@testable import Domain`，
/// 本机 `refactor/scripts/run-domain-tests.sh` 直跑。

// MARK: - 区域切分

@Suite("SU-CE1 · PageLayout.extractionRegions —— 表头 / 合成表格 / 段落 / 结构化表格")
struct ExtractionRegionTests {
    private func b(_ lines: [String], _ i: Int, x: Double, y: Double, w: Double) -> TextBlock {
        TextBlock(text: lines[i], bbox: LayoutRect(x: x, y: y, width: w, height: 0.05), lineIndex: i, confidence: 0.9)
    }

    /// 原名：首个多列行前为表头且连续多列行合成表格
    @Test func firstMultiColumnRowBecomesHeaderAndConsecutiveRowsFormTable() {
        let lines = ["处方日期：2026-09-01", "阿莫西林胶囊", "每次1粒", "布洛芬缓释胶囊", "每次1粒"]
        let layout = PageLayout(blocks: [b(lines, 0, x: 0, y: 0, w: 0.6), b(lines, 1, x: 0, y: 0.2, w: 0.3), b(lines, 2, x: 0.5, y: 0.2, w: 0.2),
                                         b(lines, 3, x: 0, y: 0.3, w: 0.3), b(lines, 4, x: 0.5, y: 0.3, w: 0.2)])
        let regions = layout.extractionRegions(pageIndex: 0)
        #expect(regions.map(\.kind) == [.header, .table])
        #expect(regions[0].rows.count == 1 && regions[0].rows[0].text == "处方日期：2026-09-01")
        #expect(regions[1].rows.count == 2 && regions[1].columnHeader == nil)
        #expect(regions[1].rows[0].cells.map(\.text) == ["阿莫西林胶囊", "每次1粒"])
        #expect(regions[1].rows[0].cells.map(\.columnIndex) == [0, 1])
        #expect(regions[1].rows[1].lineIndices == [3, 4])
        #expect(regions.allSatisfy { $0.pageIndex == 0 })
        #expect(regions.map(\.id) == ["g0", "g1"], "几何区域 id 按产生顺序编号")
    }

    /// 原名：表格之后的单列行归段落
    @Test func singleColumnRowsAfterTableBecomeParagraph() {
        let lines = ["药品名称", "阿莫西林胶囊", "每次1粒", "医嘱：饭后服用", "复诊请携带本单"]
        let layout = PageLayout(blocks: [b(lines, 0, x: 0, y: 0, w: 0.3), b(lines, 1, x: 0, y: 0.2, w: 0.3), b(lines, 2, x: 0.5, y: 0.2, w: 0.2),
                                         b(lines, 3, x: 0, y: 0.4, w: 0.7), b(lines, 4, x: 0, y: 0.5, w: 0.7)])
        let regions = layout.extractionRegions(pageIndex: 2)
        #expect(regions.map(\.kind) == [.header, .table, .paragraph])
        #expect(regions[2].rows.map(\.text) == ["医嘱：饭后服用", "复诊请携带本单"])
        #expect(regions.allSatisfy { $0.pageIndex == 2 })
    }

    /// 原名：结构化表格直接成区域且覆盖行不再几何聚行
    @Test func structuredTableBecomesRegionAndCoveredRowsSkipGeometricGrouping() {
        let lines = ["检验报告单", "项目", "结果", "白细胞", "6.5", "报告医师：王五"]
        let cell = { (text: String, col: Int, line: Int) in
            TableCell(text: text, bbox: LayoutRect(x: Double(col) * 0.4, y: 0.2, width: 0.3, height: 0.05), columnIndex: col, lineIndices: [line])
        }
        let table = TableRegion(id: "t0", bbox: LayoutRect(x: 0, y: 0.15, width: 0.8, height: 0.2),
                                rows: [TableRow(cells: [cell("6.5", 1, 4), cell("白细胞", 0, 3)])],
                                header: TableRow(cells: [cell("项目", 0, 1), cell("结果", 1, 2)]))
        let layout = PageLayout(blocks: [b(lines, 0, x: 0, y: 0, w: 0.5), b(lines, 1, x: 0, y: 0.2, w: 0.3), b(lines, 2, x: 0.4, y: 0.2, w: 0.3),
                                         b(lines, 3, x: 0, y: 0.3, w: 0.3), b(lines, 4, x: 0.4, y: 0.3, w: 0.3), b(lines, 5, x: 0, y: 0.5, w: 0.6)],
                                tables: [table])
        let regions = layout.extractionRegions(pageIndex: 0)
        #expect(regions.map(\.kind) == [.header, .table, .paragraph])
        #expect(regions[1].id == "t0" && regions[1].columnHeader == ["项目", "结果"])
        #expect(regions[1].rows.map(\.id) == ["t0r0"])
        #expect(regions[1].rows[0].cells.map(\.text) == ["白细胞", "6.5"], "格按 columnIndex 排序")
        #expect(regions[1].rows[0].lineIndices == [3, 4])
        #expect(regions[2].rows.map(\.text) == ["报告医师：王五"])
        #expect(regions[0].rows.map(\.text) == ["检验报告单"], "表格覆盖的行（1–4）不再进入几何聚行")
    }

    /// 原名：仅行文本退化为单个表头区域每行一格
    @Test func linesOnlyDegradesToSingleHeaderRegionOneCellPerRow() {
        let regions = PageLayout.linesOnly(["处方笺", "阿莫西林胶囊 0.25g", "每日3次"]).extractionRegions(pageIndex: 1)
        #expect(regions.count == 1 && regions[0].kind == .header && regions[0].pageIndex == 1)
        #expect(regions[0].rows.map(\.text) == ["处方笺", "阿莫西林胶囊 0.25g", "每日3次"])
        #expect(regions[0].rows.allSatisfy { $0.cells.count == 1 })
        #expect(regions[0].rows.map(\.lineIndices) == [[0], [1], [2]])
        #expect(PageLayout(blocks: []).extractionRegions(pageIndex: 0).isEmpty)
    }
}

// MARK: - ExtractedCard 值对象

@Suite("SU-CE1 · ExtractedCard / GroundedValue —— Codable 快照往返与默认值")
struct ExtractedCardTests {
    /// 原名：卡片Codable往返保留锚点续行与诊断
    @Test func cardCodableRoundTripKeepsAnchorsContinuationsAndDiagnostics() throws {
        let anchor = TextAnchor(pageIndex: 0, lineIndex: 3, blockId: "b3", rowId: "r1", utf16Range: 2..<9)
        let value = GroundedValue(value: "阿莫西林胶囊", unit: nil, normalized: nil, anchor: anchor,
                                  continuation: [TextAnchor(pageIndex: 0, lineIndex: 4, blockId: nil, rowId: nil, utf16Range: 0..<3)], confidence: 0.6)
        var card = ExtractedCard(kind: "prescription", pageIndex: 0, shared: ["hospital": value], rows: [["drug_name": value]],
                                 provenance: ExtractionProvenance(track: .foundationModels, specVersion: 1, modelId: "apple-fm", durationMs: 42),
                                 diagnostics: ExtractionDiagnostics(track: .foundationModels))
        card.continuationHint["prescribed_at"] = value
        card.diagnostics.degradedReason = .lowGrounding
        card.diagnostics.mixedTracks = true
        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(ExtractedCard.self, from: data)
        #expect(decoded == card)
        #expect(decoded.rows[0]["drug_name"]?.anchor.utf16Range == 2..<9)
        #expect(decoded.continuationHint["prescribed_at"]?.continuation.count == 1)
    }

    /// 原名：诊断默认值为零且默认无降级
    @Test func diagnosticsDefaultToZeroAndNoDegradation() {
        let diagnostics = ExtractionDiagnostics(track: .rules)
        #expect(diagnostics.degradedReason == .none && diagnostics.droppedUngrounded == 0 && diagnostics.timedOutRegions == 0)
        #expect(diagnostics.retries == 0 && !diagnostics.mixedTracks)
        let card = ExtractedCard(kind: "encounter", pageIndex: 0, shared: [:], rows: [],
                                 provenance: ExtractionProvenance(track: .rules, specVersion: 1, modelId: nil, durationMs: 0), diagnostics: diagnostics)
        #expect(card.continuationHint.isEmpty)
        #expect(ExtractionTrack.allCases.map(\.rawValue) == ["foundationModels", "localLLM", "rules"])
    }
}

// MARK: - ExtractionSpec 注册表

@Suite("SU-CE1 · ExtractionSpec 注册表 —— 全卡类覆盖 / 键可达 / 必填不越界 / 枚举 canonical / 别名同源")
struct ExtractionSpecRegistryTests {
    /// 原名：注册表每个卡类均有spec且键集不越出卡类注册表
    @Test func everyCardKindHasSpecAndKeysStayWithinRegistryAllowedSets() throws {
        for entry in CardKindRegistry.entries {
            let spec = try #require(ExtractionSpecRegistry.spec(for: entry.kind), "\(entry.kind)")
            #expect(spec.requiredKeys.isSubset(of: entry.sharedRequired.union(entry.rowRequired)), "\(entry.kind) 必填 ⊆ 注册表必填")
            #expect(Set(spec.shared.map(\.key)).isSubset(of: entry.sharedAllowed), "\(entry.kind) 共享键 ⊆ sharedAllowed")
            // reference_range 由匹配器拆 ref_low/ref_high 后落库（旧路径 companionFields 同纪律），其余行键 ⊆ rowAllowed。
            #expect(Set(spec.row.map(\.key)).isSubset(of: entry.rowAllowed.union(["reference_range"])), "\(entry.kind) 行键 ⊆ rowAllowed")
            #expect(spec.shared.allSatisfy { $0.scope == .shared } && spec.row.allSatisfy { $0.scope == .row }, "\(entry.kind)")
            #expect(Set((spec.shared + spec.row).map(\.key)).count == spec.shared.count + spec.row.count, "\(entry.kind) 键不重复")
            #expect(spec.exemplars.count <= 2 && spec.version >= 1, "\(entry.kind)")
            if let anchor = spec.rowAnchor {
                #expect(entry.rowRequired.contains(anchor), "\(entry.kind) 行锚为注册表行必填")
                #expect(spec.row.first { $0.key == anchor }?.isRequired == true, "\(entry.kind) 行锚必填")
            } else {
                #expect(entry.rowRequired.isEmpty && spec.row.isEmpty, "\(entry.kind) 无行锚即无行字段")
            }
        }
        #expect(Set(ExtractionSpecRegistry.specs.map(\.kind)) == Set(CardKindRegistry.entries.map(\.kind)))
        #expect(ExtractionSpecRegistry.specs.count == CardKindRegistry.entries.count, "每卡类恰一份 spec")
        #expect(ExtractionSpecRegistry.spec(for: "appointment") == nil, "无注册表条目的模板不出 spec")
    }

    /// 原名：每份spec的键在模板可达且行锚是模板rowKey映射值
    @Test func everySpecKeyReachableInTemplateAndRowAnchorIsTemplateRowKeyValue() throws {
        for spec in ExtractionSpecRegistry.specs {
            let template = try #require(CardTemplateMatcher.ocrTemplates.first { $0.kind == spec.kind })
            let reachable = Set(template.mapping.values).union(template.rowLevelKeys)
            for field in spec.shared + spec.row { #expect(reachable.contains(field.key), "\(spec.kind).\(field.key)") }
            #expect((spec.rowAnchor == nil) == (template.rowKey == nil), "\(spec.kind)")                    // 行卡 ⇔ 模板有 rowKey
            if let anchor = spec.rowAnchor { #expect(template.rowLevelKeys.contains(anchor), "\(spec.kind)") }   // 锚为行级模板键
            #expect(CardKindRegistry.entry(for: spec.kind) != nil)
            for field in spec.shared + spec.row { if case .enumerated(let domain) = field.type {
                for value in domain { #expect(OCRGrounding.normalized(value, key: field.key) == value, "\(spec.kind).\(field.key)=\(value)") } } }
        }
        #expect(ExtractionSpecRegistry.candidates(documentTypeKeys: ["prescription"]).map(\.kind) == ["prescription"])
        #expect(ExtractionSpecRegistry.spec(for: "prescription")?.narrowed().exemplars.count ?? 9 <= 1)
    }

    /// 原名：枚举域与Domain单一事实源同源
    @Test func enumeratedDomainsShareSingleSourceWithDomain() throws {
        func domain(_ kind: String, _ key: String) throws -> [String] {
            let field = try #require(ExtractionSpecRegistry.spec(for: kind).flatMap { s in (s.shared + s.row).first { $0.key == key } })
            guard case .enumerated(let domain) = field.type else { Issue.record("\(kind).\(key) 非枚举"); return [] }
            return domain
        }
        #expect(try domain("diagnosis", "diagnosis_type") == Diagnosis.diagnosisTypes)
        #expect(try domain("exam_report", "report_type") == ExamReport.reportTypes)
        #expect(try domain("clinical_conclusion", "conclusion_type") == ClinicalConclusion.conclusionTypes)
        #expect(try domain("treatment_record", "treatment_type") == TreatmentRecord.treatmentTypes)
        #expect(Set(try domain("prescription", "prescription_type")).isSubset(of: EntityCardProjection.prescriptionTypes))
        #expect(try domain("claim_item", "currency") == ["CNY"] && (try domain("claim_item", "item_type")) == ["invoice", "fee", "receipt"])
        #expect(try domain("medication", "unit_kind") == ["tablet", "capsule", "patch", "vial"])
    }

    /// 原名：标签别名与否定守卫同源于Domain词表
    @Test func labelAliasesAndNegationGuardsStemFromDomainVocabulary() {
        let clinical = Dictionary(ClinicalFieldLabels.prefixAliases.map { ($0.key, Set($0.labels)) }, uniquingKeysWith: { a, _ in a })
        var checked = 0
        for spec in ExtractionSpecRegistry.specs {
            for field in spec.shared + spec.row {
                // 结论行 `content` 的标签是结论类型标签（conclusionTypeLabels），与治疗记录 `content`（治疗内容）同键异义——按卡类各取其一。
                if spec.kind == "clinical_conclusion", field.key == "content" {
                    #expect(Set(ClinicalFieldLabels.conclusionTypeLabels.flatMap(\.labels)).isSubset(of: Set(field.labelAliases)))
                    continue
                }
                guard let labels = clinical[field.key] else { continue }
                #expect(labels.isSubset(of: Set(field.labelAliases)), "\(spec.kind).\(field.key) 别名须包含 ClinicalFieldLabels 全部标签")
                checked += 1
            }
            #expect(spec.negativeGuards.isEmpty || spec.negativeGuards == OCRGrounding.negationGuards, "\(spec.kind)")
        }
        #expect(checked > 40, "住院/检查/检验/体检/手术/治疗键均走单一事实源（实测 \(checked)）")
        #expect(ExtractionSpecRegistry.spec(for: "prescription")?.negativeGuards == OCRGrounding.negationGuards)
        #expect(ExtractionSpecRegistry.spec(for: "medication")?.negativeGuards == OCRGrounding.negationGuards)
        #expect(ExtractionSpecRegistry.spec(for: "encounter")?.negativeGuards == [])
    }

    /// 原名：类型决定grounding规则
    @Test func fieldTypeDeterminesGroundingRule() {
        for spec in ExtractionSpecRegistry.specs {
            for field in spec.shared + spec.row {
                switch field.type {
                case .narrative: #expect(field.grounding == .labeledValue, "\(spec.kind).\(field.key)")
                case .number, .quantityWithUnit: #expect(field.grounding == .numericToken, "\(spec.kind).\(field.key)")
                case .enumerated: #expect(field.grounding == .enumNormalized, "\(spec.kind).\(field.key)")
                case .text, .date: #expect(field.grounding == .verbatim, "\(spec.kind).\(field.key)")
                }
                #expect(!field.promptHint.isEmpty, "\(spec.kind).\(field.key) 提示词非空")
            }
        }
    }

    /// 原名：共享日期兜底首日期而手术日期不猜
    @Test func sharedDateFallsBackToFirstDateButSurgeryDateIsNotGuessed() throws {
        let prescription = try #require(ExtractionSpecRegistry.spec(for: "prescription"))
        #expect(prescription.shared.first { $0.key == "prescribed_at" }?.fallback == .firstDateInRegion)
        #expect(prescription.shared.first { $0.key == "hospital" }?.fallback == .lineContaining(["医院", "醫院"]))
        #expect(prescription.rowMinFields == 1 && prescription.maxRowsPerRegion == 8 && prescription.rowAnchor == "drug_name")
        let surgery = try #require(ExtractionSpecRegistry.spec(for: "surgery"))
        #expect(surgery.shared.first { $0.key == "surgery_at" }?.fallback == nil, "出院小结多日期并存——只认显式标签")
        #expect(surgery.shared.first { $0.key == "ended_at" }?.fallback == nil)
        let treatment = try #require(ExtractionSpecRegistry.spec(for: "treatment_record"))
        #expect(treatment.shared.first { $0.key == "treated_at" }?.fallback == .firstDateInRegion, "单日期文书泛日期即治疗日期")
        let lab = try #require(ExtractionSpecRegistry.spec(for: "metric_sample"))
        #expect(lab.rowMinFields == 2 && lab.maxRowsPerRegion == 12 && lab.rowAnchor == "raw_label")
        #expect(ExtractionSpecRegistry.spec(for: "claim_item")?.rowMinFields == 2)
        #expect(ExtractionSpecRegistry.spec(for: "medication")?.rowMinFields == 2)
        #expect(ExtractionSpecRegistry.spec(for: "encounter")?.rowMinFields == 0)
    }

    /// 原名：candidates按文档类型键取目标卡类保持目录顺序去重
    @Test func candidatesByDocumentTypeKeyKeepCatalogOrderAndDedupe() {
        #expect(ExtractionSpecRegistry.candidates(documentTypeKeys: ["checkup_report", "lab_report"]).map(\.kind)
                == ["health_exam", "metric_sample", "exam_report", "clinical_conclusion"])
        #expect(ExtractionSpecRegistry.candidates(documentTypeKeys: ["discharge_summary"]).map(\.kind) == ["hospitalization", "diagnosis", "surgery"])
        #expect(ExtractionSpecRegistry.candidates(documentTypeKeys: ["medical_order", "bogus", "other"]).isEmpty)
        #expect(ExtractionSpecRegistry.candidates(documentTypeKeys: []).isEmpty)
    }

    /// 原名：narrowed去可选字段少样本至多一条并保留行锚
    @Test func narrowedDropsOptionalFieldsKeepsAtMostOneExemplarAndRowAnchor() throws {
        let spec = try #require(ExtractionSpecRegistry.spec(for: "prescription"))
        let narrowed = spec.narrowed()
        #expect(narrowed.shared.map(\.key) == ["prescribed_at"])
        #expect(narrowed.row.map(\.key) == ["drug_name"])
        #expect(narrowed.exemplars.count <= 1 && narrowed.kind == spec.kind && narrowed.version == spec.version)
        #expect(narrowed.rowAnchor == spec.rowAnchor)
        #expect(narrowed.negativeGuards == spec.negativeGuards)
        #expect(narrowed.rowMinFields == spec.rowMinFields)
        #expect(narrowed.requiredKeys == spec.requiredKeys)
        #expect(narrowed.outputTokenBudget < spec.outputTokenBudget)
        let lab = try #require(ExtractionSpecRegistry.spec(for: "metric_sample")).narrowed()
        #expect(lab.row.map(\.key) == ["raw_label", "value"], "必填行键保留")
    }

    /// 原名：outputTokenBudget按类型上限累加且不超1536
    @Test func outputTokenBudgetAccumulatesByTypeCappedAt1536() throws {
        func f(_ key: String, _ type: FieldType, _ scope: FieldSpec.Scope) -> FieldSpec {
            FieldSpec(key: key, type: type, scope: scope, isRequired: false, labelAliases: [], grounding: .verbatim, promptHint: key, fallback: nil)
        }
        let small = ExtractionSpec(kind: "x", version: 1, shared: [f("a", .text(maxChars: 40), .shared)],
                                   row: [f("b", .number(integer: true), .row), f("c", .date, .row)], rowAnchor: "b",
                                   maxRowsPerRegion: 2, exemplars: [], negativeGuards: [], rowMinFields: 1)
        let expectedSmall: Int = 16 + (4 + 24) + ((4 + 8) + (4 + 12)) * 2   // JSON 开销 + 共享 text + 行(number + date)×2
        #expect(small.outputTokenBudget == expectedSmall)
        let single = ExtractionSpec(kind: "y", version: 1, shared: [f("n", .narrative(maxChars: 400), .shared), f("e", .enumerated(domain: ["a"]), .shared),
                                                                     f("q", .quantityWithUnit, .shared)], row: [], rowAnchor: nil,
                                    maxRowsPerRegion: 0, exemplars: [], negativeGuards: [], rowMinFields: 0)
        let expectedSingle: Int = 16 + (4 + 96) + (4 + 6) + (4 + 12)           // narrative + enumerated + quantityWithUnit
        #expect(single.outputTokenBudget == expectedSingle)
        #expect(try #require(ExtractionSpecRegistry.spec(for: "prescription")).outputTokenBudget == 1_536, "处方 8 行满配封顶")
        #expect(ExtractionSpecRegistry.specs.allSatisfy { $0.outputTokenBudget <= 1_536 && $0.outputTokenBudget > 16 })
    }

    /// 原名：格式校验只查格式_日期可解析数字有限枚举canonical
    @Test func formatValidationOnlyChecksFormatDatesNumbersAndCanonicalEnums() {
        #expect(FieldType.date.acceptsFormat("2026-09-01") && FieldType.date.acceptsFormat("２０２６年９月１日") && FieldType.date.acceptsFormat("处方日期：2026/9/1 08:30"))
        #expect(!FieldType.date.acceptsFormat("无") && !FieldType.date.acceptsFormat("2026-13-01") && !FieldType.date.acceptsFormat("09/01/2026"))
        #expect(FieldType.number(integer: false).acceptsFormat("128.50") && FieldType.number(integer: false).acceptsFormat("１２８"))
        #expect(!FieldType.number(integer: false).acceptsFormat("1e999") && !FieldType.number(integer: false).acceptsFormat("一盒") && !FieldType.number(integer: false).acceptsFormat("nan"))
        #expect(FieldType.number(integer: true).acceptsFormat("7") && !FieldType.number(integer: true).acceptsFormat("7.5"))
        #expect(FieldType.enumerated(domain: ["CNY"]).acceptsFormat("CNY") && !FieldType.enumerated(domain: ["CNY"]).acceptsFormat("RMB"), "枚举校验只认 canonical；归一在 OCRGrounding.normalized 单出口")
        #expect(FieldType.quantityWithUnit.acceptsFormat("0.25g×24") && FieldType.quantityWithUnit.acceptsFormat("一盒"), "带单位量至少含一个数字（中文数字亦为数字）")
        #expect(!FieldType.quantityWithUnit.acceptsFormat("口服") && !FieldType.number(integer: true).acceptsFormat("七"), "number 须为可持久化的阿拉伯数字")
        #expect(FieldType.text(maxChars: 4).acceptsFormat("超过四个字的文本") && FieldType.narrative(maxChars: 4).acceptsFormat("未见异常，建议复查"), "maxChars 只作预算/文法上限，不截断不丢弃（BR-002）")
        #expect(!FieldType.text(maxChars: 4).acceptsFormat("  ") && !FieldType.date.acceptsFormat(""))
    }
}

// MARK: - 轨道无关 grounding

@Suite("SU-CE2 · ExtractionGrounding —— 值不在锚定行即丢弃 / 数字逐字 / 叙事整段 / 枚举单出口 / 续行")
struct ExtractionGroundingTests {
    private func anchor(_ line: Int, page: Int = 0) -> TextAnchor {
        TextAnchor(pageIndex: page, lineIndex: line, blockId: nil, rowId: nil, utf16Range: 0..<0)
    }
    private func gv(_ v: String, line: Int, unit: String? = nil, continuation: [Int] = []) -> GroundedValue {
        GroundedValue(value: v, unit: unit, anchor: anchor(line), continuation: continuation.map { anchor($0) }, confidence: 0.6)
    }
    private func card(_ kind: String, shared: [String: GroundedValue] = [:], rows: [[String: GroundedValue]] = []) -> ExtractedCard {
        ExtractedCard(kind: kind, pageIndex: 0, shared: shared, rows: rows,
                      provenance: .init(track: .rules, specVersion: 1, modelId: nil, durationMs: 0), diagnostics: .init(track: .rules))
    }

    /// 原名：值不在锚定行即丢弃且全角数字可定位
    @Test func valueNotOnAnchorLineIsDroppedAndFullWidthDigitsLocate() throws {
        let spec = try #require(ExtractionSpecRegistry.spec(for: "prescription"))
        let lines = ["处方日期：２０２６-09-01", "阿莫西林胶囊 0.25g 每次1粒 每日3次", "禁用：青霉素类"]
        let input = card("prescription",
                         shared: ["prescribed_at": gv("2026-09-01", line: 0), "hospital": gv("协和医院", line: 1)],
                         rows: [["drug_name": gv("阿莫西林胶囊", line: 1), "dosage": gv("1粒", line: 1), "days": gv("15", line: 1)],
                                ["drug_name": gv("青霉素", line: 2)]])
        let (out, dropped) = ExtractionGrounding.validate(input, spec: spec, lines: lines)
        #expect(out.shared["prescribed_at"]?.value == "2026-09-01" && out.shared["hospital"] == nil)   // 全角→半角可定位；凭空医院丢弃
        #expect(out.shared["prescribed_at"]?.anchor.utf16Range == 5..<15, "锚点回填原文 UTF-16 范围")
        #expect(out.rows.count == 1 && out.rows[0]["days"] == nil)                                     // 「15」非子串；否定守卫整行不出药名
        #expect(out.rows[0]["drug_name"]?.value == "阿莫西林胶囊" && out.rows[0]["dosage"]?.value == "1粒")
        #expect(dropped == 3 && out.diagnostics.droppedUngrounded == 3)
        #expect(ExtractionGrounding.locate("2026-09-01", in: "２０２６-09-01")?.lowerBound == "２０２６-09-01".startIndex)
        #expect(out.kind == "prescription" && out.pageIndex == 0 && out.provenance == input.provenance)
    }

    /// 原名：数字须逐字且带边界_格式不合法即丢弃
    @Test func numbersMustBeVerbatimAndBoundedInvalidFormatDropped() throws {
        let spec = try #require(ExtractionSpecRegistry.spec(for: "claim_item"))
        let lines = ["合计：128.50", "开票日期：2026-13-45", "个人支付 8 元", "血常规 5.00 5 25.00"]
        let input = card("claim_item",
                         shared: ["amount": gv("128.5", line: 0), "out_of_pocket": gv("8", line: 2), "date": gv("2026-13-45", line: 1)],
                         rows: [["item_name": gv("血常规", line: 3), "unit_price": gv("5.00", line: 3), "item_amount": gv("25.00", line: 3)]])
        let (out, dropped) = ExtractionGrounding.validate(input, spec: spec, lines: lines)
        #expect(out.shared["amount"] == nil, "128.5 是 128.50 的数字子串——不得截断小数")
        #expect(out.shared["out_of_pocket"]?.value == "8")
        #expect(out.shared["date"] == nil, "定位得到但不可解析的日期不进卡（只查格式，不猜日期）")
        #expect(out.rows.count == 1 && out.rows[0].count == 3)
        #expect(dropped == 2)
        let days = try #require(ExtractionSpecRegistry.spec(for: "prescription"))
        let fractional = card("prescription", rows: [["drug_name": gv("阿莫西林", line: 0), "days": gv("7.5", line: 0)]])
        let (kept, droppedDays) = ExtractionGrounding.validate(fractional, spec: days, lines: ["阿莫西林 7.5天"])
        #expect(kept.rows[0]["days"] == nil && kept.rows[0]["drug_name"] != nil && droppedDays == 1, "整数字段拒绝小数")
    }

    /// 原名：叙事只接受整行或spec别名剥标签且否定不可删
    @Test func narrativeAcceptsWholeLineOrSpecAliasAndNegationIsNotRemovable() throws {
        let spec = try #require(ExtractionSpecRegistry.spec(for: "encounter"))
        let lines = ["就诊日期：2026-09-01", "诊断：未诊断糖尿病", "Chief Complaint: cough 3 days", "既往史：高血压 10 年"]
        let input = card("encounter", shared: [
            "date": gv("2026-09-01", line: 0),
            "diagnosis_text": gv("糖尿病", line: 1),                 // 删除否定 → 丢弃
            "chief_complaint": gv("cough 3 days", line: 2),         // spec 别名「Chief Complaint」不在 OCRGrounding 内置标签表——经 extraLabels 剥离
            "past_history": gv("高血压", line: 3),                   // 截断 → 丢弃
            "visit_summary": gv("既往史：高血压 10 年", line: 3),      // 整行 → 接受
        ])
        let (out, dropped) = ExtractionGrounding.validate(input, spec: spec, lines: lines)
        #expect(out.shared["diagnosis_text"] == nil && out.shared["past_history"] == nil)
        #expect(out.shared["chief_complaint"]?.value == "cough 3 days")
        #expect(out.shared["visit_summary"]?.value == "既往史：高血压 10 年" && out.shared["date"]?.value == "2026-09-01")
        #expect(dropped == 2)
        let negated = card("encounter", shared: ["diagnosis_text": gv("未诊断糖尿病", line: 1)])
        #expect(ExtractionGrounding.validate(negated, spec: spec, lines: lines).card.shared["diagnosis_text"]?.value == "未诊断糖尿病")
    }

    /// 原名：枚举印刷原文留在value_canonical进normalized_不在域即丢弃
    @Test func enumPrintedTextStaysInValueCanonicalNormalizedOutOfDomainDropped() throws {
        let prescription = try #require(ExtractionSpecRegistry.spec(for: "prescription"))
        let lines = ["处方类型：普通处方", "处方类型：特殊", "币种：人民币", "票据类型：发票", "计量单位：粒"]
        let a = ExtractionGrounding.validate(card("prescription", shared: ["prescription_type": gv("普通处方", line: 0)]), spec: prescription, lines: lines).card
        #expect(a.shared["prescription_type"]?.value == "普通处方" && a.shared["prescription_type"]?.normalized == "general")
        let b = ExtractionGrounding.validate(card("prescription", shared: ["prescription_type": gv("特殊", line: 1)]), spec: prescription, lines: lines)
        #expect(b.card.shared["prescription_type"] == nil && b.dropped == 1, "别名表不命中即丢，不猜类型")
        let claim = try #require(ExtractionSpecRegistry.spec(for: "claim_item"))
        let c = ExtractionGrounding.validate(card("claim_item", shared: ["currency": gv("人民币", line: 2), "item_type": gv("发票", line: 3)]), spec: claim, lines: lines).card
        #expect(c.shared["currency"]?.normalized == "CNY" && c.shared["item_type"]?.normalized == "invoice")
        let medication = try #require(ExtractionSpecRegistry.spec(for: "medication"))
        let d = ExtractionGrounding.validate(card("medication", rows: [["generic_name": gv("计量单位", line: 4), "unit_kind": gv("粒", line: 4)]]), spec: medication, lines: lines).card
        #expect(d.rows.first?["unit_kind"]?.normalized == "capsule")
        #expect(a.shared["prescription_type"]?.normalized != nil && c.shared["currency"]?.value == "人民币", "非枚举字段 normalized 恒 nil")
        #expect(ExtractionGrounding.validate(card("prescription", shared: ["prescribed_at": gv("2026-09-01", line: 0)]), spec: prescription,
                                             lines: ["处方日期：2026-09-01"]).card.shared["prescribed_at"]?.normalized == nil)
    }

    /// 原名：续行分段须与锚点一一对应并逐段回填范围
    @Test func continuationSegmentsMustPairWithAnchorsAndBackfillRangesPerSegment() throws {
        let spec = try #require(ExtractionSpecRegistry.spec(for: "encounter"))
        let lines = ["现病史：咳嗽 3 天", "伴低热，无胸痛", "体格检查：T 36.8℃"]
        let two = card("encounter", shared: ["present_illness": gv("咳嗽 3 天\n伴低热，无胸痛", line: 0, continuation: [1])])
        let (out, dropped) = ExtractionGrounding.validate(two, spec: spec, lines: lines)
        let value = try #require(out.shared["present_illness"])
        #expect(dropped == 0 && value.value == "咳嗽 3 天\n伴低热，无胸痛")
        #expect(value.anchor.utf16Range == 4..<10 && value.continuation.count == 1 && value.continuation[0].utf16Range == 0..<7)
        let mismatch = card("encounter", shared: ["present_illness": gv("咳嗽 3 天\n伴低热，无胸痛", line: 0)])   // 两段一锚
        #expect(ExtractionGrounding.validate(mismatch, spec: spec, lines: lines).dropped == 1)
        let wrongLine = card("encounter", shared: ["present_illness": gv("咳嗽 3 天\n伴低热，无胸痛", line: 0, continuation: [2])])
        #expect(ExtractionGrounding.validate(wrongLine, spec: spec, lines: lines).card.shared["present_illness"] == nil)
        let outOfRange = card("encounter", shared: ["physical_exam": gv("T 36.8℃", line: 9)])
        #expect(ExtractionGrounding.validate(outOfRange, spec: spec, lines: lines).dropped == 1)
    }

    /// 原名：行锚未锚定整行不出且未知键丢弃
    @Test func rowWithoutAnchorProducesNoRowAndUnknownKeyDropped() throws {
        let spec = try #require(ExtractionSpecRegistry.spec(for: "metric_sample"))
        let lines = ["白细胞 6.5 10^9/L 3.5-9.5", "报告日期：2026-09-01"]
        let input = card("metric_sample",
                         shared: ["measured_at": gv("2026-09-01", line: 1), "bogus_key": gv("6.5", line: 0)],
                         rows: [["value": gv("6.5", line: 0), "unit": gv("10^9/L", line: 0)],                     // 无 raw_label → 整行不出
                                ["raw_label": gv("白细胞", line: 0), "value": gv("6.5", line: 0), "reference_range": gv("3.5-9.5", line: 0)]])
        let (out, dropped) = ExtractionGrounding.validate(input, spec: spec, lines: lines)
        #expect(out.rows.count == 1 && out.rows[0]["raw_label"]?.value == "白细胞" && out.rows[0]["reference_range"]?.value == "3.5-9.5")
        #expect(out.shared.keys.sorted() == ["measured_at"])
        #expect(dropped == 3, "未知键 1 + 无行锚行的两个已锚定值 2（均不进卡即计入）")
    }

    /// 原名：locate精确优先_NFKC与空白折叠回映原文范围_不做繁简
    @Test func locatePrefersExactNFKCAndWhitespaceFoldRangesWithoutScriptConversion() {
        let line = "处方日期：２０２６-09-01  每次 1 粒"
        #expect(ExtractionGrounding.locate("每次 1 粒", in: line).map { String(line[$0]) } == "每次 1 粒")
        #expect(ExtractionGrounding.locate("每次1粒", in: line).map { String(line[$0]) } == "每次 1 粒")
        #expect(ExtractionGrounding.locate("处方日期:2026-09-01", in: line).map { String(line[$0]) } == "处方日期：２０２６-09-01")
        #expect(ExtractionGrounding.locate("協和", in: "协和医院") == nil, "不做繁简转换——FR25.4 保真")
        #expect(ExtractionGrounding.locate("", in: line) == nil && ExtractionGrounding.locate("x", in: "") == nil)
        #expect(ExtractionGrounding.locate("mg", in: "剂量 0.25 ｍｇ").map { String(line[$0]) } != nil)
    }
}

// MARK: - GroundedValue → FieldDraft 适配

@Suite("SU-CE2 · FieldDraftAdapter —— GroundedValue → FieldDraft 恒 D 级，FR17.13 确认页零改")
struct FieldDraftAdapterTests {
    private let lines = ["处方日期：2026-09-01", "处方类型：普通处方", "阿莫西林胶囊 0.25g 每次1粒"]
    private func anchor(_ line: Int) -> TextAnchor { TextAnchor(pageIndex: 0, lineIndex: line, blockId: "b\(line)", rowId: nil, utf16Range: 0..<0) }

    /// 原名：草稿恒D级_置信取页置信与0_6之小者_原文行回填
    @Test func draftAlwaysGradeDConfidenceIsLesserOfPageAnd0_6RawLineBackfilled() {
        let v = GroundedValue(value: "2026-09-01", anchor: anchor(0), confidence: 0.6)
        let draft = FieldDraftAdapter.draft(key: "prescribed_at", v, lines: lines, pageConfidence: 0.9, track: .foundationModels)
        #expect(draft.key == "prescribed_at" && draft.value == "2026-09-01")
        #expect(draft.grade == .ocrUnconfirmed && !draft.isConfirmed)
        #expect(draft.confidence == 0.6 && draft.rawText == lines[0])
        #expect(draft.sourceLineIndex == 0 && draft.source == .foundationModels)
        let low = FieldDraftAdapter.draft(key: "prescribed_at", v, lines: lines, pageConfidence: 0.35, track: .rules)
        #expect(low.confidence == 0.35 && low.source == .heuristic)
        #expect(ConfidenceTier.tier(low.confidence) == .low, "低置信字段仍逐项复核（FR17.4）")
        let selfRated = GroundedValue(value: "2026-09-01", anchor: anchor(0), confidence: 0.99)
        #expect(FieldDraftAdapter.draft(key: "prescribed_at", selfRated, lines: lines, pageConfidence: 1, track: .foundationModels).confidence == 0.6,
                "模型自评分不作准确率——上限 0.6（BR-003）")
    }

    /// 原名：枚举取canonical为值_原文留rawText_单位随行_越界锚点回落值
    @Test func enumUsesCanonicalAsValueKeepsRawTextUnitInlineOutOfRangeAnchorFallsBack() {
        let e = GroundedValue(value: "普通处方", normalized: "general", anchor: anchor(1), confidence: 0.6)
        let draft = FieldDraftAdapter.draft(key: "prescription_type", e, lines: lines, pageConfidence: 0.9, track: .localLLM)
        #expect(draft.value == "general" && draft.rawText == "处方类型：普通处方" && draft.source == .localLLM)
        let unit = GroundedValue(value: "6.5", unit: "10^9/L", anchor: anchor(7), confidence: 0.6)
        let d2 = FieldDraftAdapter.draft(key: "value", unit, lines: lines, pageConfidence: 0.9, track: .rules)
        #expect(d2.unit == "10^9/L" && d2.rawText == "6.5" && d2.sourceLineIndex == 7)
    }

    /// round4 D-2（SU-OCRA-LAYOUT）：`continuation` 自 E2 起存在、适配器从未消费——多行叙事确认页「原文」只显首行、
    /// `value` 却三行，用户无法核对后两行出处（BR-002 出处完整）。rawText = 主锚行 + 全部续行（`\n` 连接，与 value 分段同源）。
    @Test func rawTextCoversAnchorAndContinuationLines() {
        let gv = GroundedValue(value: "普通处方\n阿莫西林胶囊 0.25g 每次1粒", anchor: anchor(1), continuation: [anchor(2)], confidence: 0.9)
        let draft = FieldDraftAdapter.draft(key: "advice_text", gv, lines: lines, pageConfidence: 0.9, track: .rules)
        #expect(draft.rawText == lines[1] + "\n" + lines[2])
        #expect(draft.sourceLineIndex == 1)
        // 续行越界：不猜、不拼半截——只保留可定位的行（fail-closed）
        let partial = GroundedValue(value: "a\nb", anchor: anchor(2), continuation: [anchor(9)], confidence: 0.9)
        #expect(FieldDraftAdapter.draft(key: "advice_text", partial, lines: lines, pageConfidence: 0.9, track: .rules).rawText == lines[2])
    }

    /// 原名：轨道到来源映射穷尽
    @Test func trackToSourceMappingIsExhaustive() {
        #expect(FieldDraftAdapter.source(.foundationModels) == .foundationModels)
        #expect(FieldDraftAdapter.source(.localLLM) == .localLLM)
        #expect(FieldDraftAdapter.source(.rules) == .heuristic)
        #expect(UnderstandingSource.localLLM.rawValue == "localLLM")
    }

    /// 原名：整卡按spec字段序映射为共享与行草稿
    @Test func wholeCardMapsToSharedAndRowDraftsInSpecFieldOrder() throws {
        let spec = try #require(ExtractionSpecRegistry.spec(for: "prescription"))
        let card = ExtractedCard(kind: "prescription", pageIndex: 0,
                                 shared: ["prescription_type": GroundedValue(value: "普通处方", normalized: "general", anchor: anchor(1), confidence: 0.6),
                                          "prescribed_at": GroundedValue(value: "2026-09-01", anchor: anchor(0), confidence: 0.6)],
                                 rows: [["dosage": GroundedValue(value: "1粒", anchor: anchor(2), confidence: 0.6),
                                         "drug_name": GroundedValue(value: "阿莫西林胶囊", anchor: anchor(2), confidence: 0.6),
                                         "zz_unknown": GroundedValue(value: "0.25g", anchor: anchor(2), confidence: 0.6)]],
                                 provenance: .init(track: .rules, specVersion: 1, modelId: nil, durationMs: 0), diagnostics: .init(track: .rules))
        let drafts = FieldDraftAdapter.drafts(card, spec: spec, lines: lines, pageConfidence: 0.8)
        #expect(drafts.shared.map(\.key) == ["prescribed_at", "prescription_type"], "spec 共享字段序")
        #expect(drafts.rows.count == 1 && drafts.rows[0].map(\.key) == ["drug_name", "dosage", "zz_unknown"], "spec 行字段序，未登记键按键名尾随")
        #expect(drafts.shared[1].value == "general" && drafts.rows[0][0].rawText == lines[2])
        #expect((drafts.shared + drafts.rows[0]).allSatisfy { $0.grade == .ocrUnconfirmed && $0.confidence == 0.6 && $0.source == .heuristic })
    }
}
