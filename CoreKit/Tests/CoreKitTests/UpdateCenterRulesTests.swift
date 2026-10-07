import Domain
import Foundation
import Testing

/// 统一更新中心 · 呈现合并规则（纯 Foundation，Linux 可跑）。
/// 委员会 2026-10-07：INV-1（通告态变化不改主行/动作集）、INV-2（域链态永远决定主行）、
/// 覆盖规则（终态抑制通告）——全部在此穷举钉死。
/// binds: SU-M15-UPDATECENTER
@Suite("SU-M15-UPDATECENTER · 统一更新中心合并规则")
struct UpdateCenterRulesTests {
    private let allChains: [UpdateChainRowState] = [
        .notChecked, .checking, .updating, .upToDate, .updateAvailable,
        .noInstallableAvailable, .failed, .unavailable,
    ]
    private let allAdvice: [UpdateAdviceRowState?] = [
        nil, .announced, .notMentioned, .stale, .unavailable,
    ]
    private let terminalChains: [UpdateChainRowState] = [
        .upToDate, .updateAvailable, .noInstallableAvailable,
    ]

    @Test func medicalNineStatesMapToChainStates() {
        #expect(UpdateCenterRules.chainState(from: .idle) == .notChecked)
        #expect(UpdateCenterRules.chainState(from: .checking) == .checking)
        #expect(UpdateCenterRules.chainState(from: .upToDate) == .upToDate)
        #expect(UpdateCenterRules.chainState(from: .noInstallableAvailable) == .noInstallableAvailable)
        #expect(UpdateCenterRules.chainState(from: .unavailable) == .unavailable)
        #expect(UpdateCenterRules.chainState(from: .rateLimited(retryAfter: nil)) == .failed)
        #expect(UpdateCenterRules.chainState(from: .verificationFailed) == .failed)
        #expect(UpdateCenterRules.chainState(from: .networkUnavailable) == .failed)
        let candidate = MedicalCatalogUpdateCandidate(
            catalogVersion: 42, dataVersion: "d", schemaVersion: 2,
            packageSize: 1, expiresAt: Date(timeIntervalSince1970: 0))
        #expect(UpdateCenterRules.chainState(from: .updateAvailable(candidate)) == .updateAvailable)
    }

    /// INV-2：域链态永远决定主行；通告不可能把主行升级为结论（upToDate 只来自域链）。
    @Test func INV2_chainAlwaysDecidesPrimary() {
        for chain in allChains {
            for advice in allAdvice {
                let presentation = UpdateCenterRules.rowPresentation(chain: chain, advice: advice)
                #expect(presentation.status == chain)
                if presentation.status == .upToDate {
                    #expect(chain == .upToDate)
                }
            }
        }
    }

    /// INV-1：固定域链态时，通告态遍历不改变 status 与 showsVerifiedUpdate（动作集代理）。
    @Test func INV1_adviceNeverChangesStatusOrAction() {
        for chain in allChains {
            let baseline = UpdateCenterRules.rowPresentation(chain: chain, advice: nil)
            for advice in allAdvice {
                let presentation = UpdateCenterRules.rowPresentation(chain: chain, advice: advice)
                #expect(presentation.status == baseline.status)
                #expect(presentation.showsVerifiedUpdate == baseline.showsVerifiedUpdate)
            }
        }
    }

    /// 覆盖规则：终态抑制通告；其余态有则 visible、无则 notRead。
    @Test func coverageRule_matrix() {
        for chain in terminalChains {
            for advice in allAdvice {
                let presentation = UpdateCenterRules.rowPresentation(chain: chain, advice: advice)
                #expect(presentation.advice == .coveredByChainConclusion)
            }
        }
        let nonTerminal = allChains.filter { !terminalChains.contains($0) }
        for chain in nonTerminal {
            #expect(UpdateCenterRules.rowPresentation(chain: chain, advice: nil).advice == .notRead)
            for advice in [UpdateAdviceRowState.announced, .notMentioned, .stale, .unavailable] {
                #expect(UpdateCenterRules.rowPresentation(chain: chain, advice: advice).advice
                    == .visible(advice))
            }
        }
    }

    /// showsVerifiedUpdate 的充要条件（类型面：通告与 failed/unavailable 均不可能开更新口）。
    @Test func showsVerifiedUpdateIffUpdateAvailable() {
        for chain in allChains {
            for advice in allAdvice {
                let presentation = UpdateCenterRules.rowPresentation(chain: chain, advice: advice)
                #expect(presentation.showsVerifiedUpdate == (chain == .updateAvailable))
            }
        }
    }

    /// 医疗休眠（unavailable）× 通告 announced = 中心唯一活信号：主行不可用、通告可见。
    @Test func dormantMedicalWithAnnouncedKeepsAdviceVisible() {
        let presentation = UpdateCenterRules.rowPresentation(chain: .unavailable, advice: .announced)
        #expect(presentation.status == .unavailable)
        #expect(presentation.advice == .visible(.announced))
        #expect(!presentation.showsVerifiedUpdate)
    }
}
