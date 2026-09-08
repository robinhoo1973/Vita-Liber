import Foundation
import Testing
@testable import Domain

// binds: SU-M2-UNDERSTANDING
/// FR17.18/FR17.19 共享文本理解层期一（兜底轨）金样与契约断言——
/// coreml-minilm-spec §8.6 四条必测断言的可执行面：
/// ① 低置信类型不落 doc_type（分类器侧=零命中不产出 suggestedTarget）；
/// ② 拒绝字段不进投影（确认集映射保真 rawText/suggestedLabel/codeResolution）；
/// ③ 编辑后旧编码不复用（F25 惰性解析无命中保留原值）；
/// ④ 重跑保留留痕（ocr_result 只增不改——App 层断言，本套件钉分类幂等）。
@Suite("SU-M2-UNDERSTANDING · 共享文本理解层期一")
struct M2UnderstandingTests {

    // MARK: - 文档类型兜底分类（FR5.5/FR6.2 后置判定）

    @Test("处方单命中主类")
    func 处方单分类() {
        let lines = ["阿莫西林胶囊 0.25g", "每日三次 每次两粒", "××市第一医院"]
        let (target, confidence, secondary) = DocumentTypeClassifierFallback.classify(lines: lines)
        #expect(target == "prescription")
        #expect(confidence >= 0.75)   // 2 行命中 → 0.75
        #expect(secondary.count <= 4) // 次级候选最多为其余有分类型
    }

    @Test("检验单命中主类并产生次级候选")
    func 检验单分类与次级候选() {
        // 检验证据 3 行（主类）+ 病历证据 1 行（次级候选，不夺主类）
        let lines = ["血常规检验报告", "血红蛋白 150 g/L", "参考范围 130-175",
                     "标本：静脉血", "诊断：缺铁性贫血"]
        let (target, confidence, secondary) = DocumentTypeClassifierFallback.classify(lines: lines)
        #expect(target == "lab_report")
        #expect(confidence == 0.9)    // ≥3 行命中
        #expect(secondary.contains { $0.key == "outpatient_record" })
    }

    @Test("零命中返回 nil 引导选择（§8.6 断言④低置信不落 doc_type）")
    func 零命中引导选择() {
        let (target, confidence, _) = DocumentTypeClassifierFallback.classify(lines: ["您好", "谢谢"])
        #expect(target == nil)
        #expect(confidence == 0)
    }

    @Test("单行命中置信度 0.6 中档需复核")
    func 单行命中低置信() {
        let (_, confidence, _) = DocumentTypeClassifierFallback.classify(lines: ["处方笺"])
        #expect(confidence == 0.6)
    }

    @Test("检验字段启发式：科室/日期/项目行")
    func 检验字段启发式() {
        let dept = DocumentTypeClassifierFallback.guessFields(line: "科室：消化内科")
        #expect(dept.first?.key == "dept")
        #expect(dept.first?.value == "消化内科")

        let date = DocumentTypeClassifierFallback.guessFields(line: "检查日期：2026-09-01")
        #expect(date.first?.key == "report_date")
        #expect(date.first?.value == "2026-09-01")

        let item = DocumentTypeClassifierFallback.guessFields(line: "血红蛋白 150 g/L")
        #expect(item.first?.key == "lab_item")
        #expect(item.first?.value.contains("血红蛋白") == true)
        #expect(item.first?.unit == "g/L")
        #expect(item.first?.rawText == "血红蛋白 150 g/L")   // BR-002 原文保留
        #expect(item.first?.source == .heuristic)
    }

    @Test("无角色命中行返回空（调用方 line_N 兜底）")
    func 无角色行() {
        #expect(DocumentTypeClassifierFallback.guessFields(line: "备注：请于明日复诊前空腹").isEmpty)
        // 「备注」非角色词；但「复诊」不属任何 role——确认启发式不越权
    }

    @Test("病历类判定（FR11.4 懒创建触发）")
    func 病历类判定() {
        #expect(DocumentTypeClassifierFallback.isClinicalType("outpatient_record"))
        #expect(DocumentTypeClassifierFallback.isClinicalType("diagnosis_certificate"))
        #expect(!DocumentTypeClassifierFallback.isClinicalType("prescription"))
    }

    // MARK: - 语音意图目录（FR17.19 兜底轨）

    @Test("指标意图自动分类（文法首命中）")
    func 指标意图分类() {
        let result = VoiceIntentCatalog.classify("血压 120 80", confidence: 0.92)
        #expect(result.suggestedTarget == VoiceIntentKey.recordMetric.rawValue)
        #expect(!result.fields.isEmpty)
        #expect(result.fields.allSatisfy { $0.source == .regex })
    }

    @Test("提醒意图自动分类")
    func 提醒意图分类() {
        let result = VoiceIntentCatalog.classify("明天下午3点提醒我复查", confidence: 0.9)
        #expect(result.suggestedTarget == VoiceIntentKey.createReminder.rawValue)
        #expect(result.fields.contains { $0.key == "hour" })
    }

    @Test("unknown 兜底：整句原文进速记（FR17.19 绝不静默丢弃）")
    func unknown兜底() {
        let result = VoiceIntentCatalog.classify("今天天气不错", confidence: 0.95)
        #expect(result.suggestedTarget == VoiceIntentKey.unknown.rawValue)
        #expect(result.fields.first?.value == "今天天气不错")
        #expect(result.fields.first?.key == "note")
    }

    @Test("显式改类抽取：期一无文法意图回落原文草稿")
    func 显式改类抽取() {
        let drafts = VoiceIntentCatalog.extract(for: .recordObservation, text: "记录一下今天头疼",
                                                confidence: 0.9)
        #expect(drafts.first?.key == "note")
        #expect(drafts.first?.value == "记录一下今天头疼")

        let metric = VoiceIntentCatalog.extract(for: .recordMetric, text: "血糖 5.6", confidence: 0.9)
        #expect(!metric.isEmpty)
    }

    @Test("目录单一事实源：十意图全覆盖、未知居末")
    func 目录完整() {
        #expect(VoiceIntentCatalog.entries.count == 10)
        #expect(VoiceIntentCatalog.entries.map(\.key) == VoiceIntentKey.allCases)
        #expect(VoiceIntentCatalog.entries.last?.key == .unknown)
    }

    // MARK: - 映射保真（coreml §8.6.2 唯一映射点）

    @Test("确认集映射保真 rawText/suggestedLabel/codeResolution（断言②）")
    func 确认集映射保真() {
        var draft = FieldDraft(key: "lab_item", value: "血红蛋白 150", unit: "g/L",
                               confidence: 0.6, rawText: "血红蛋白 150 g/L",
                               suggestedLabel: "oc.confirm.label.labItem",
                               source: .heuristic)
        draft.codeResolution = CodeResolution(conceptId: "loinc-718-7", canonicalCode: "718-7",
                                              codingSystem: .loinc, displayZhHans: "血红蛋白",
                                              displayEn: "Hemoglobin", kind: .metric,
                                              canonicalUnit: "g/L", matchedVia: .curated,
                                              confidence: 0.95)
        let set = VoiceInputTemplate.confirmationSet(drafts: [draft])
        let field = set.fields.first
        #expect(field?.displayLabel == "oc.confirm.label.labItem")   // suggestedLabel → displayLabel
        #expect(field?.rawText == "血红蛋白 150 g/L")                 // 原文保留（BR-002）
        #expect(field?.codeResolution?.conceptId == "loinc-718-7")    // codeResolution 透传
        #expect(field?.grade == .ocrUnconfirmed)                      // 全 D 级（BR-003）
    }

    @Test("旧字段兼容：扩展字段默认 nil 不破坏既有调用")
    func 旧字段兼容() {
        let legacy = FieldDraft(key: "hour", value: "15", unit: nil, confidence: 0.8)
        #expect(legacy.rawText == nil)
        #expect(legacy.suggestedLabel == nil)
        #expect(legacy.source == nil)
        #expect(legacy.codeResolution == nil)
    }

    // MARK: - F25 惰性接线（断言③：绝不猜码、无命中保留原值）

    @Test("F25 无命中保留原值不猜码")
    func f25无命中保留原值() async {
        let fields = [
            FieldDraft(key: "lab_item", value: "血红蛋白", unit: "g/L", confidence: 0.6),
            FieldDraft(key: "note", value: "普通文本", confidence: 0.9),   // 非医疗槽位不引码
        ]
        let resolved = await UnderstandingCodeResolution.resolve(
            fields, locale: Locale(identifier: "zh_Hans"),
            index: EmptyCodeIndex(), units: EmptyUnitIndex())
        #expect(resolved.count == 2)
        #expect(resolved[0].codeResolution == nil)   // 无命中 → nil，保留原值
        #expect(resolved[1].codeResolution == nil)   // note 键不引码（FR25.12 负清单）
    }
}

// MARK: - 测试桩（CodeIndex/UnitIndex 空实现）

private actor EmptyCodeIndex: CodeIndex {
    func overrideHit(_ raw: String) async throws -> AliasHit? { nil }
    func resolveAlias(_ raw: String, locale: Locale) async throws -> [AliasHit] { [] }
    func concept(_ id: String) async throws -> CodeResolution? { nil }
    func unitSpecificConcept(conceptId: String, unit: String) async throws -> CodeResolution? { nil }
}

private actor EmptyUnitIndex: UnitIndex {
    func unit(_ code: String) async throws -> UcumUnit? { nil }
    func molarBridge(from: String, to: String, conceptId: String) async throws -> UcumMolarBridge? { nil }
}
