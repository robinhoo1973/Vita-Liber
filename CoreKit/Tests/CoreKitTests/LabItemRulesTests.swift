import Foundation
import Testing
@testable import Domain

/// 检测/检查项分类（业主 2026-09-17 定：酶类检测与检查项配象征图标）。
@Suite("SU-FR6.9 · 检测检查项分类（酶类/检查项/常规）")
struct LabItemRulesTests {

    @Test("酶类优先：以「酶」结尾的检验项目归 enzyme（含心肌酶谱等复合名）")
    func 酶类() {
        for label in ["谷丙转氨酶", "碱性磷酸酶", "肌酸激酶", "心肌酶谱", "淀粉酶"] {
            #expect(LabItemRules.classify(label: label) == .enzyme, "\(label) → enzyme")
        }
    }

    @Test("检查项：影像/功能检查关键词归 exam；其余检验项归 routine")
    func 检查项与常规() {
        for label in ["腹部超声", "彩超", "B超", "X光片", "CT平扫", "磁共振", "胃镜", "肠镜", "冠脉造影", "心电图", "肺功能"] {
            #expect(LabItemRules.classify(label: label) == .exam, "\(label) → exam")
        }
        for label in ["血红蛋白", "白细胞计数", "血糖", "总胆固醇", "尿蛋白", "镜检"] {
            #expect(LabItemRules.classify(label: label) == .routine, "\(label) → routine（镜检是检验项，不误分类）")
        }
    }
}
