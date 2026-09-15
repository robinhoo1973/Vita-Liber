import Foundation

/// 抽取层的共享词表与文法单点（结构轮 2026-09-15）。
/// 收敛原则：只收「多份拷贝语义一致」的资产；捕获组语义不同的正则保持就地（无损优先）。
public enum ExtractionPatterns {

    /// 科室词表（最长优先匹配；处方/检验/病历/裸科室行全轨共享）。
    ///
    /// 此前 Domain（`ExtractionSpec.deptWords`，22 条）与 Infrastructure
    /// （`NLTextUnderstanding.deptWords`，36 条）各一份且已实证漂移：同一「裸科室行」
    /// 在规则轨与理解轨的命中面不同（缺项如「产科/心血管内科/肾内科」只在理解轨可配）。
    /// 本表取并集为单一事实源；新增科室 = 只加此处。
    public static let deptWords: [String] = [
        "内科", "外科", "儿科", "妇产科", "产科", "眼科", "耳鼻喉科", "口腔科",
        "皮肤科", "骨科", "泌尿外科", "神经内科", "消化内科", "呼吸内科",
        "心血管内科", "心内科", "内分泌科", "血液科", "肿瘤科", "感染科",
        "肾内科", "风湿免疫科", "老年科", "全科", "康复医学科", "康复科",
        "中医科", "针灸科", "急诊科", "重症医学科", "麻醉科", "放射科",
        "影像科", "超声科", "检验科", "病理科", "体检中心", "保健科",
    ]

    public static let deptWordSet: Set<String> = Set(deptWords)

    /// 最长优先（长词先匹配，避免「内科」截走「心血管内科」）。
    /// 预排序常量——此前调用点每行 `deptWords.sorted(by:)` 现算一次（30 行报告即 30 次排序）。
    public static let deptWordsByLength: [String] = deptWords.sorted { $0.count > $1.count }

    /// 参考范围边界解析：「3.5-9.5」「3.5～9.5」「3.5 ~ 9.5」→ (低, 高)；
    /// 解析失败 nil（不猜范围）。数值文法含正负号/小数/科学计数。
    /// （结构轮：自 `CardTemplateMatcher.referenceBounds` 迁入——该文法是检验行/表头/
    /// 分类器多轨共用的语法资产，不再挂在模板匹配器名下。）
    public static func referenceBounds(_ text: String) -> (low: String, high: String)? {
        let number = #"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: "^\\s*(\(number))\\s*[-–~～]\\s*(\(number))\\s*$"), // try?-ok: 静态数值文法字面量，构造不会失败
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let lowRange = Range(match.range(at: 1), in: text), let highRange = Range(match.range(at: 2), in: text) else { return nil }
        let low = String(text[lowRange]), high = String(text[highRange])
        guard let l = Double(low), let h = Double(high), l.isFinite, h.isFinite, l <= h else { return nil }
        return (low, high)
    }
}
