import XCTest
import Domain

/// 说明书检索意图闸门（BR-006）：原文引用放行，个人化剂量/停药/合用/选药一律拒识。
// binds: SU-M1b-REGESSION（FR12 / BR-006）
final class MedicalQuestionIntentRulesTests: XCTestCase {
    func test_leafletQuoteQuestionsPass() {
        XCTAssertEqual(MedicalQuestionIntentRules.classify("说明书里用法用量怎么写的"), .none)
        XCTAssertEqual(MedicalQuestionIntentRules.classify("这个药的适应症原文是什么"), .none)
        XCTAssertEqual(MedicalQuestionIntentRules.classify("不良反应有哪些"), .none)
    }

    func test_personalDosageRefused() {
        XCTAssertEqual(MedicalQuestionIntentRules.classify("这个药我该吃几片"), .personalDosage)
        XCTAssertEqual(MedicalQuestionIntentRules.classify("一次吃多少"), .personalDosage)
        XCTAssertEqual(MedicalQuestionIntentRules.classify("可以加量吗"), .personalDosage)
    }

    func test_stopSwitchInteractionComparisonRefused() {
        XCTAssertEqual(MedicalQuestionIntentRules.classify("症状好了能停药吗"), .stopOrSwitch)
        XCTAssertEqual(MedicalQuestionIntentRules.classify("换成另一种可以吗"), .stopOrSwitch)
        XCTAssertEqual(MedicalQuestionIntentRules.classify("这两种药能一起吃吗"), .interaction)
        XCTAssertEqual(MedicalQuestionIntentRules.classify("哪个药更好"), .comparison)
        XCTAssertEqual(MedicalQuestionIntentRules.classify("这个药比那个更好吗"), .comparison)
    }

    func test_comparisonKeywordDoesNotSwallowFieldQuestions() {
        XCTAssertEqual(MedicalQuestionIntentRules.classify("哪个药的不良反应有哪些"), .none)
    }

    func test_widthAndSpaceFolding() {
        XCTAssertEqual(MedicalQuestionIntentRules.classify("可以 加量 吗"), .personalDosage)
    }
}
