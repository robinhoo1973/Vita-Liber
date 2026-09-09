import Foundation
import Testing
@testable import Domain
@testable import Protocols
@testable import Infrastructure

// binds: SU-M15-VOICE (FR17.9/FR17.18 LLM 修正版安全合同)
/// 端侧润色双版本（V3.61 实装，iOS 26 Foundation Models 门控）：润色**永不覆盖**原文；
/// 数值、单位、日期、药名、人名、否定词逐 token 校验，任一改变即拒绝回原文（BR-003/BR-006）。
@Suite("SU-M15-VOICE · 润色受保护 token 校验与不可用回落")
struct TranscriptRefinerTests {
    @Test func 仅标点断句的润色被接受() {
        let original = "今天头疼吃了两片布洛芬血压130 80"
        let suggested = "今天头疼，吃了两片布洛芬。血压 130/80。"
        #expect(ProtectedTokenValidator.validate(original: original, suggested: suggested, drugNames: ["布洛芬"]) == .accepted)
    }

    @Test func 改数字拒绝() {
        #expect(ProtectedTokenValidator.validate(original: "血压 120 80", suggested: "血压 130 80") == .rejected)
        #expect(ProtectedTokenValidator.validate(original: "吃了2片", suggested: "吃了 3 片") == .rejected)
    }

    @Test func 改单位或日期拒绝() {
        #expect(ProtectedTokenValidator.validate(original: "血糖 5.6 mmol/L", suggested: "血糖 5.6 mg/dL") == .rejected)
        #expect(ProtectedTokenValidator.validate(original: "2026年9月1日复诊", suggested: "2026年9月2日复诊") == .rejected)
    }

    @Test func 改否定词拒绝() {
        #expect(ProtectedTokenValidator.validate(original: "没有发烧", suggested: "有发烧") == .rejected)
        #expect(ProtectedTokenValidator.validate(original: "不头疼了", suggested: "头疼了") == .rejected)
        #expect(ProtectedTokenValidator.validate(original: "没有发烧", suggested: "没有发烧。") == .accepted)
    }

    @Test func 药名人名缺失或改写拒绝() {
        #expect(ProtectedTokenValidator.validate(original: "吃了布洛芬", suggested: "吃了止痛药", drugNames: ["布洛芬"]) == .rejected)
        #expect(ProtectedTokenValidator.validate(original: "张医生说没事", suggested: "医生说没事", personNames: ["张医生"]) == .rejected)
    }

    @Test func 受保护token抽取覆盖数字单位日期否定词() {
        let tokens = ProtectedTokenValidator.protectedTokens(in: "2026-09-01 血压 130/80 mmHg 没有头疼 布洛芬 2 片", drugNames: ["布洛芬"])
        #expect(tokens.contains("2026-09-01"))
        #expect(tokens.contains("130"))
        #expect(tokens.contains("80"))
        #expect(tokens.contains("mmHg"))
        #expect(tokens.contains("没有"))
        #expect(tokens.contains("布洛芬"))
    }

    @Test func 修订值对象_拒绝与不可用均以原文生效() {
        let rejected = TranscriptRevision(original: "a 1", suggested: "a 2", safety: .rejected)
        #expect(rejected.effective == "a 1")
        let unavailable = TranscriptRevision.unavailable("原文")
        #expect(unavailable.effective == "原文" && unavailable.safety == .unavailable)
        let accepted = TranscriptRevision(original: "a", suggested: "a。", safety: .accepted)
        #expect(accepted.effective == "a。")
    }

    @Test func 不可用替身返回原文且不声称可用() async {
        let refiner = UnavailableTextRefiner()
        #expect(await refiner.isAvailable == false)
        let revision = await refiner.refine("血压 130", localeIdentifier: "zh-Hans-CN", drugNames: [])
        #expect(revision.effective == "血压 130")
        #expect(revision.safety == .unavailable)
    }

    @Test func 第九工厂注册于引擎注册表() {
        let registry = EngineRegistry()
        registry.registerDefaultEngines()
        #expect(registry.isRegistered(TextRefinerFactory.self))
        guard case .success = registry.assertOfflineOnly() else {
            #expect(Bool(false), "润色引擎必须端侧/零网络"); return
        }
    }
}
