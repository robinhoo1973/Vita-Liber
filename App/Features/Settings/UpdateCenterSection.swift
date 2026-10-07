import SwiftUI
import Domain
import Perception

/// 统一更新中心（页首 Section；委员会 2026-10-07 三席评审「形态 A」落地）。
///
/// 容器合并、语义分层：检查入口与状态语法跨域统一；**安装/更新动作留在域内**
/// （医疗更新闭环在本页「医疗数据目录」节、ASR 安装在各家族行）。主行只由域链态
/// 解析、通告只作次级注解（域链终态抑制，R2.2/R2.5）；任何通告态不改变按钮
/// 可用性（R2.6 的类型面在 Domain `UpdateCenterRules`——本视图零业务判定）。
struct UpdateCenterSection: View {
    @Environment(UpdateCenterState.self) private var center: UpdateCenterState?
    @Environment(ASRIndexCheckState.self) private var asrCheck: ASRIndexCheckState?
    @Environment(MedicalCatalogState.self) private var medical: MedicalCatalogState?

    var body: some View {
        WithPerceptionTracking {
            Section {
                domainRow(.asrModels, name: L10n.updateAdviceDomainAsr,
                          primary: asrPrimary, hint: asrHint)
                domainRow(.medicalData, name: L10n.updateAdviceDomainMedical,
                          primary: medicalPrimary, hint: medicalHint)
                checkAllRow
            } header: {
                Text(L10n.updateCenterTitle)
            } footer: {
                Text(L10n.updateAdviceNote)
            }
        }
    }

    // MARK: - 行渲染（状态来源只有域链/通告两轴，正交不合句）

    /// 单域行：域名 + 域链态文案 + 可选提示 + 通告注解（caption·tertiary）。
    /// 容器必须 `children: .contain`——L0 第 18 节掩蔽纪律（否则压盖子元素标识）。
    private func domainRow(_ domain: UpdateAdviceDomain, name: String,
                           primary: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.subheadline)
            Text(primary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("SP-64.updateCenter.hint." + domain.rawValue)
            }
            if let adviceText = adviceText(domain) {
                Text(adviceText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(L10n.updateCenterAdviceA11yPrefix + adviceText)
                    .accessibilityIdentifier("SP-64.updateCenter.advice." + domain.rawValue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SP-64.updateCenter.row." + domain.rawValue)
    }

    // MARK: - 文案映射

    private var asrPrimary: String {
        guard let asrCheck else { return L10n.updateCenterRowIdle }
        if asrCheck.installBusy { return L10n.updateCenterRowUpdating }
        switch asrCheck.state {
        case .idle: return L10n.updateCenterRowIdle
        case .checking: return L10n.updateCenterRowChecking
        case .upToDate: return L10n.asrModelCheckUpToDate
        case .updates(let count): return L10n.asrModelCheckUpdates(count)
        case .failed: return L10n.asrIndexFetchFailed
        }
    }

    private var asrHint: String? {
        guard let asrCheck else { return nil }
        if asrCheck.installBusy { return L10n.updateCenterAsrBusyHint }
        if case .updates = asrCheck.state { return L10n.updateCenterAsrUpdatesHint }
        return nil
    }

    private var medicalPrimary: String {
        guard let medical else { return L10n.resourceCatalogUnavailable }
        if medical.isUpdating { return L10n.updateCenterRowUpdating }
        switch medical.remoteState {
        case .idle: return L10n.updateCenterRowIdle
        case .checking: return L10n.resourceCatalogChecking
        case .upToDate: return L10n.resourceCatalogUpToDate
        case .updateAvailable(let candidate):
            return L10n.resourceCatalogUpdateAvailableFmt(candidate.catalogVersion)
        case .noInstallableAvailable: return L10n.resourceCatalogNoInstallable
        case .unavailable: return L10n.resourceCatalogUnavailable
        case .rateLimited(let retryAfter): return retryLimitedText(retryAfter)
        case .verificationFailed: return L10n.resourceCatalogVerificationFailed
        case .networkUnavailable: return L10n.resourceCatalogNetworkUnavailable
        }
    }

    private var medicalHint: String? {
        guard let medical, case .updateAvailable = medical.remoteState else { return nil }
        return L10n.updateCenterMedicalUpdatesHint
    }

    /// 通告注解：仅 `visible` 呈现（未读/被域链终态覆盖不占位）；文案键复用通告五态。
    private func adviceText(_ domain: UpdateAdviceDomain) -> String? {
        guard case .visible(let state)? = center?.presentation(for: domain).advice else { return nil }
        switch state {
        case .announced: return L10n.updateAdviceRowAnnounced
        case .notMentioned: return L10n.updateAdviceRowNotMentioned
        case .stale: return L10n.updateAdviceRowStale
        case .unavailable: return L10n.updateAdviceRowUnavailable
        }
    }

    /// 限流可重试时间（自 ResourceManagementView 迁入；该节不再渲染检查态）。
    private func retryLimitedText(_ retryAfter: Date?) -> String {
        guard let retryAfter, retryAfter > Date() else { return L10n.resourceCatalogRateLimited }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: L10n.bundleLanguage)
        let relative = formatter.localizedString(for: retryAfter, relativeTo: Date())
        return L10n.resourceCatalogRateLimitedFmt(relative)
    }

    // MARK: - 检查全部（唯一显式检查入口；禁用条件仅「批查在飞」，永不受通告态影响）

    @ViewBuilder
    private var checkAllRow: some View {
        if let center {
            HStack(spacing: 12) {
                Button {
                    center.checkAll()
                } label: {
                    HStack {
                        Label(L10n.updateCenterCheckAll, systemImage: "arrow.triangle.2.circlepath")
                        if center.isBusy { ProgressView().controlSize(.small) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(center.isBusy)
                .accessibilityHint(L10n.updateCenterCheckAllHint)
                .accessibilityIdentifier("SP-64.updateCenter.checkAll")

                if center.isBusy {
                    Button(L10n.commonCancel) { center.cancelAll() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("SP-64.updateCenter.cancel")
                }
            }
        }
    }
}
