import Testing
import Foundation
@testable import Domain

/// SU-CE-EXTRACT · 标签值域回归网（2026-09-16 实测污染修复）。
///
/// **为什么存在**：本机只读 harness 实测发现，业主报告的「字段没有被正确识别或填充」
/// 实际上是**值被污染**而非空缺——对 `日期：2026-09-12 科室：呼吸内科 医生：张三`：
///
/// | 字段 | 修复前的值 |
/// |---|---|
/// | `doctor` | `2026-09-12 科室：呼吸内科 医生：张三`（整段） |
/// | `department` | `呼吸内科 医生：张三` |
/// | `report_date` | 整行 |
/// | `hospital`（另一行 `北京协和医院 处方笺`） | `北京协和医院 处方笺` |
///
/// 机制：`guessFields` 的 `(.+)` 贪婪捕获 + `pageFields.append` 取「首个冒号之后的全部文本」，
/// 且该轨产物**不经 `ExtractionGrounding`**（grounding 只保护 NL 规格轨）→ 污染值原样进确认页。
/// 医疗记录里**错的字段值比空值更危险**（可能被一键确认升为 C 级事实），故逐条钉死。
///
/// 本套件是「把业主投诉变成 CI 红」的最小充分集：修复前必红，修复后必绿。
@Suite("SU-CE-EXTRACT · 标签值域与污染防护")
struct LabeledValueExtractionTests {

    private func value(_ key: String, in line: String) -> String? {
        DocumentTypeClassifierFallback.guessFields(line: line).first { $0.key == key }?.value
    }

    private func pageValue(_ key: String, lines: [String]) -> String? {
        DocumentTypeClassifierFallback.pageFields(lines: lines, understood: [], confidence: 0.6)
            .first { $0.key == key }?.value
    }

    // MARK: - 组合表头行：每个字段只取自己的值

    @Test("组合表头行：科室不吞掉医生标签，医生不吞掉日期")
    func 组合表头行各字段只取自己的值() throws {
        let line = "日期：2026-09-12 科室：呼吸内科 医生：张三"

        let dept = try #require(value("dept", in: line), "科室必须可抽")
        #expect(dept == "呼吸内科", "科室值曾为「呼吸内科 医生：张三」，实得 \(dept)")

        let doctor = try #require(pageValue("doctor", lines: [line]), "医生必须可抽")
        #expect(doctor == "张三", "医生值曾为整段（含日期与科室），实得 \(doctor)")
        #expect(!doctor.contains("科室"), "医生值不得含其它标签")
        #expect(!doctor.contains("2026"), "医生值不得含日期")
    }

    @Test("日期值是有界日期记号，不是整行")
    func 日期值为有界记号() throws {
        let line = "日期：2026-09-12 科室：呼吸内科 医生：张三"
        let date = try #require(pageValue("report_date", lines: [line]), "日期必须可抽")
        #expect(date == "2026-09-12", "日期值曾为整行，实得 \(date)")
        #expect(line.contains(date), "日期必须是原文精确子串")
    }

    @Test("机构名丢掉尾随文档类型词（后缀文法，非标签截断）")
    func 机构名去掉尾随文本() throws {
        let hospital = try #require(pageValue("hospital", lines: ["北京协和医院 处方笺"]))
        #expect(hospital == "北京协和医院", "医院值曾为「北京协和医院 处方笺」，实得 \(hospital)")
    }

    @Test("分行排版与组合行得到完全相同的值")
    func 分行与组合行一致() throws {
        let split = ["日期：2026-09-12", "科室：呼吸内科", "医生：张三"]
        #expect(pageValue("report_date", lines: split) == "2026-09-12")
        #expect(value("dept", in: split[1]) == "呼吸内科")
        #expect(pageValue("doctor", lines: split) == "张三")
    }

    // MARK: - 不变量

    @Test("不变量：每个产出值都是原文的精确子串（可定位、可显示原文）")
    func 产出值恒为原文子串() {
        let lines = [
            "日期：2026-09-12 科室：呼吸内科 医生：张三",
            "北京协和医院 处方笺",
            "主诉：反复咳嗽 3 周 诊断：支气管炎",
        ]
        for line in lines {
            let drafts = DocumentTypeClassifierFallback.guessFields(line: line)
                + DocumentTypeClassifierFallback.pageFields(lines: [line], understood: [], confidence: 0.6)
            for draft in drafts {
                #expect(line.contains(draft.value),
                        "值必须是原文精确子串：key=\(draft.key) value=\(draft.value) line=\(line)")
            }
        }
    }

    @Test("负例：原文没有该信息时不得凭空产出")
    func 负例不凭空产出() {
        let noDate = "阿莫西林胶囊 0.25g×24 每次1粒"
        #expect(pageValue("report_date", lines: [noDate]) == nil, "无日期行不得产出日期")
        #expect(pageValue("doctor", lines: [noDate]) == nil, "无医生行不得产出医生")
        #expect(pageValue("hospital", lines: [noDate]) == nil, "无医院行不得产出医院")
    }

    @Test("负例：截断后为空则丢弃（宁缺勿污染）")
    func 截断为空则丢弃() {
        // 「科室：」后紧跟另一个标签 → 科室无值，不得把下一个标签当值
        let line = "科室：医生：张三"
        let dept = value("dept", in: line)
        #expect(dept == nil || !(dept ?? "").contains("医生"),
                "截断后为空必须丢弃，实得 \(dept ?? "nil")")
    }

    // MARK: - 文法单测

    @Test("truncatingAtLabelBoundary：无标签时原样返回，截断为空返回 nil")
    func 边界截断语义() {
        #expect(ExtractionPatterns.truncatingAtLabelBoundary("呼吸内科") == "呼吸内科")
        #expect(ExtractionPatterns.truncatingAtLabelBoundary("呼吸内科 医生：张三") == "呼吸内科")
        #expect(ExtractionPatterns.truncatingAtLabelBoundary("医生：张三") == nil)
        #expect(ExtractionPatterns.truncatingAtLabelBoundary("  ") == nil)
    }

    @Test("valueSpan：取标签自己的值段，右界为下一个标签")
    func 值域提取语义() {
        let line = "日期：2026-09-12 科室：呼吸内科 医生：张三"
        #expect(ExtractionPatterns.valueSpan(afterLabel: "医生", in: line) == "张三")
        #expect(ExtractionPatterns.valueSpan(afterLabel: "科室", in: line) == "呼吸内科")
        #expect(ExtractionPatterns.valueSpan(afterLabel: "日期", in: line) == "2026-09-12")
        #expect(ExtractionPatterns.valueSpan(afterLabel: "护士", in: line) == nil)
    }

    @Test("dateToken：三种写法都能取出有界记号")
    func 日期记号三种写法() {
        #expect(ExtractionPatterns.dateToken(in: "就诊时间 2026-09-12 上午") == "2026-09-12")
        #expect(ExtractionPatterns.dateToken(in: "2026年9月12日 复查") == "2026年9月12日")
        #expect(ExtractionPatterns.dateToken(in: "报告日期：2026/9/12") == "2026/9/12")
        #expect(ExtractionPatterns.dateToken(in: "无日期") == nil)
    }

    // MARK: - 规格轨同族修复（OCRExtraction / RuleExtractor）

    @Test("规格轨：叙事标签行一行多标签时，值不吞掉后面的标签")
    func 规格轨值域界定() {
        let line = "诊断：支气管炎 处理：抗感染治疗"
        let value = OCRGrounding.labeledValue(line)
        #expect(value == "支气管炎", "曾把「处理：抗感染治疗」整段吞下，实得 \(value)")
    }

    @Test("关键安全属性：正文里出现标签词**不得**被截断（叙事值不被误伤）")
    func 叙事值不被误伤() {
        // 「诊断」在这里是正文词（前一字符是「往」，非标签位）——截断就会吃掉半句话
        let line = "现病史：患者既往诊断高血压 10 年，规律服药"
        let value = OCRGrounding.labeledValue(line)
        #expect(value == "患者既往诊断高血压 10 年，规律服药",
                "正文中的标签词不得触发截断，实得 \(value)")

        // 「处理」同样是正文词（前一字符是「续」，非标签位）
        let line2 = "现病史：门诊持续处理中"
        #expect(OCRGrounding.labeledValue(line2) == "门诊持续处理中")
    }

    @Test("标签位判据：行首/空白/分隔标点之后才算标签")
    func 标签位判据() {
        #expect(ExtractionPatterns.truncatingAtLabelBoundary("支气管炎 处理：抗感染") == "支气管炎")
        #expect(ExtractionPatterns.truncatingAtLabelBoundary("患者既往诊断高血压") == "患者既往诊断高血压")
        #expect(ExtractionPatterns.truncatingAtLabelBoundary("支气管炎，处理：抗感染") == "支气管炎，")
        #expect(ExtractionPatterns.truncatingAtLabelBoundary("诊断：支气管炎") == nil,
                "值以标签开头且处于标签位 → 截断为空 → 丢弃（宁缺勿污染）")
    }

    @Test("规格轨：cell 内一行多标签同样被界定；标签独占 cell 仍返回空串")
    func 规格轨cell界定() {
        let aliases = ["诊断", "主诉"]
        #expect(RuleExtractor.split(label: "诊断：支气管炎 主诉：咳嗽3天", aliases: aliases) == "支气管炎")
        #expect(RuleExtractor.split(label: "诊断", aliases: aliases) == "",
                "标签独占 cell → 空串（值在下一 cell），此语义不变")
        #expect(RuleExtractor.split(label: "诊断", aliases: ["现病史"]) == nil,
                "标签不匹配 → nil（此语义不变）")
    }

    @Test("规格轨：非已知标签行原样返回（不误删任意冒号内容）")
    func 未知标签原样返回() {
        // `温馨提示` 含子串「提示」（`提示` 确是 `impression` 的别名之一，见 ClinicalFieldLabels:44），
        // 但标签判定是**整段精确匹配**，故 `温馨提示：…` 不是字段行 → 原样返回。
        let line = "温馨提示：请于三日后复查"
        #expect(OCRGrounding.labeledValue(line) == line, "未知标签不得被当成字段标签删掉")
        // 反面：`提示` 单独出现时**是**已知标签 → 取值（防止把「精确匹配」写成「不匹配任何标签」）
        #expect(OCRGrounding.labeledValue("提示：请于三日后复查") == "请于三日后复查")
    }
}
