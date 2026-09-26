#if os(iOS) || os(macOS)
import Testing
@testable import Domain

/// 术语词典(FR12.4)+ 四域覆盖层的行为钉。
@Suite("术语词典与覆盖层")
struct MedicalTerminologyOverlayTests {

    @Test func staticStoreExplainsNewDiseaseAndLabTerms() {
        #expect(TerminologyStore.shared.explain("高血压") != nil)
        #expect(TerminologyStore.shared.explain("血常规") != nil)
        #expect(TerminologyStore.shared.explain("不存在的术语") == nil)
    }

    @Test func staticExplanationsCarryNoNumericThresholds() {
        // BR-006/FR12.4 分离纪律:解释纯描述,零数字(阈值属 GuidelineSource)。
        let batch = ["高血压", "高脂血症", "糖尿病", "冠心病", "脑卒中", "肺炎", "支气管炎",
                     "哮喘", "贫血", "胃炎", "消化性溃疡", "脂肪肝", "胆囊结石", "甲状腺功能亢进",
                     "甲状腺功能减退", "骨质疏松", "类风湿关节炎", "痛风", "荨麻疹", "湿疹",
                     "血常规", "尿常规", "肝功能检查", "肾功能检查", "血脂四项", "糖化血红蛋白",
                     "电解质", "凝血功能", "甲状腺功能检查", "肿瘤标志物", "心电图", "胸部X线",
                     "超声检查", "CT", "磁共振成像", "白细胞计数", "血红蛋白", "血小板计数", "C反应蛋白"]
        for term in batch {
            guard let explanation = TerminologyStore.shared.explain(term) else {
                Issue.record("缺解释: \(term)")
                continue
            }
            #expect(!explanation.contains(where: { $0.isNumber }), "\(term) 解释含数字阈值: \(explanation)")
        }
    }

    @Test func overlayResolvesAliasThenExplainsCanonical() async {
        let overlay = MedicalTerminologyOverlay.shared
        await overlay.install(names: ["急性心梗": "急性心肌梗死", "急性心肌梗死": "急性心肌梗死"])
        #expect(await overlay.canonicalName(for: "急性心梗") == "急性心肌梗死")
        #expect(await overlay.canonicalName(for: "未知词") == "未知词")
        // 静态词典未收「急性心肌梗死」→ 解释为 nil(覆盖层不编造解释)
        #expect(await overlay.explain("急性心梗") == nil)
        // 已收词原词命中
        #expect(await overlay.explain("高血压") != nil)
        await overlay.install(names: [:])
        #expect(await overlay.canonicalName(for: "急性心梗") == "急性心梗")
    }
}
#endif
