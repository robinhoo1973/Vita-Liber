import SwiftUI
import Domain
import Perception

/// SP-64 通告区（README VL-INDEX 二维码；委员会 P3 设计，2026-10-07）。
///
/// 呈现规则 R2.1–R2.9 逐条落地：封闭四态 + 未读态，**永不出现「已最新/无更新」**
/// （那只能由域链检查产出）；「未提及/不可用」各有独立文案；标题下固定「未在本机
/// 校验」标注（R2.7）；读取按钮在任何载荷态下可用（R2.6）；不展示数量结论（R2.8）。
struct UpdateAdviceSection: View {
    /// 可选注入：未注入（孤立预览）= 未读态、按钮不可用——不新增崩溃面。
    @Environment(UpdateAdviceState.self) private var adviceState: UpdateAdviceState?

    var body: some View {
        WithPerceptionTracking {
            Section {
                ForEach(UpdateAdviceDomain.allCases, id: \.rawValue) { domain in
                    LabeledContent(domainLabel(domain), value: rowText(adviceState?.rowState(domain)))
                        .accessibilityIdentifier("SP-64.resource.advice." + domain.rawValue)
                }
                Button {
                    guard let adviceState else { return }
                    Task { await adviceState.read() }
                } label: {
                    Label(L10n.updateAdviceRead, systemImage: "qrcode.viewfinder")
                }
                .disabled(adviceState == nil || adviceState?.isReading == true)
                .accessibilityIdentifier("SP-64.resource.advice.read")
            } header: {
                Text(L10n.updateAdviceTitle)
            } footer: {
                Text(L10n.updateAdviceNote)
            }
        }
    }

    private func domainLabel(_ domain: UpdateAdviceDomain) -> String {
        switch domain {
        case .asrModels: return L10n.updateAdviceDomainAsr
        case .medicalData: return L10n.updateAdviceDomainMedical
        }
    }

    private func rowText(_ state: UpdateAdviceRowState?) -> String {
        switch state {
        case .none: return L10n.updateAdviceRowIdle
        case .announced: return L10n.updateAdviceRowAnnounced
        case .notMentioned: return L10n.updateAdviceRowNotMentioned
        case .stale: return L10n.updateAdviceRowStale
        case .unavailable: return L10n.updateAdviceRowUnavailable
        }
    }
}
