import Foundation

/// 统一更新中心 · 域链 × 通告面的呈现合并规则（纯 Foundation，Linux 可测）。
///
/// 委员会裁决（2026-10-07 三席评审，`refactor/discussions/2026-10-07-unified-update-center-round1.md`）：
/// 「容器合并、语义分层」——**检查入口**跨域统一，**安装动作**永不合并；
/// **域链结论永远是主行来源**（R2.2/R2.5 的呈现层实现），通告只可能出现在
/// 副行注解位、且域链给出终态结论后被抑制（coveredByChainConclusion）。
/// 本文件是唯一业务判定点：视图只消费本层输出，零二次判定。

/// 域链面行态（每域一条链；「已是最新」只能由域链产生——R2.2 的类型面延续）。
public enum UpdateChainRowState: Sendable, Equatable {
    /// 本会话尚未检查。
    case notChecked
    /// 检查中（含索引/指针拉取，不下载包体）。
    case checking
    /// 更新/安装进行中（进度面细项在域内资源行呈现）。
    case updating
    /// 域链验证：本机已是最新（唯一可以产出此态的链）。
    case upToDate
    /// 域链验证：存在可安装更新（唯一可驱动动作的终态；`showsVerifiedUpdate` 的充要条件）。
    case updateAvailable
    /// 链可达但无完整可安装项（终态，与 upToDate 语义不同，绝不折叠）。
    case noInstallableAvailable
    /// 检查失败（限流/校验失败/网络不可用——细分文案保留在域内资源行）。
    case failed
    /// 链未装配/暂不可用（fail-closed；含「无 driver」的域）。
    case unavailable
}

/// 通告副面三值注记——显式区分「未读」「可见」「被域链终态覆盖（抑制）」，
/// 使 R2.2/R2.5 的覆盖规则可穷举断言。
public enum UpdateCenterAdviceNote: Sendable, Equatable {
    /// 通告尚未读取。
    case notRead
    /// 呈现通告提示（未被域链结论覆盖；文案键由通告五态自身决定）。
    case visible(UpdateAdviceRowState)
    /// 域链终态结论已覆盖，通告不呈现（R2.2/R2.5 核心）。
    case coveredByChainConclusion
}

/// 单域呈现输出：主行只由域链态解析，副行只由通告注记解析——两轴正交、永不合句。
public struct UpdateCenterRowPresentation: Sendable, Equatable {
    public let status: UpdateChainRowState
    public let advice: UpdateCenterAdviceNote

    /// 类型面保证「通告不得驱动动作」：唯一允许开启更新入口的域链终态。
    public var showsVerifiedUpdate: Bool { status == .updateAvailable }

    public init(status: UpdateChainRowState, advice: UpdateCenterAdviceNote) {
        self.status = status
        self.advice = advice
    }
}

/// 纯规则出口（无状态、无框架）。
public enum UpdateCenterRules {
    /// 医疗九态 → 域链面露态。rateLimited/verificationFailed/networkUnavailable 归 `.failed`
    /// （细分文案由域内资源行按原医疗态呈现）；noInstallableAvailable 保持独立。
    public static func chainState(from remote: MedicalCatalogRemoteState) -> UpdateChainRowState {
        switch remote {
        case .idle: return .notChecked
        case .checking: return .checking
        case .upToDate: return .upToDate
        case .updateAvailable: return .updateAvailable
        case .noInstallableAvailable: return .noInstallableAvailable
        case .unavailable: return .unavailable
        case .rateLimited, .verificationFailed, .networkUnavailable: return .failed
        }
    }

    /// 域 × (通告, 域链) → 呈现（覆盖规则唯一判定点）。
    ///
    /// 终态裁决集 {upToDate, updateAvailable, noInstallableAvailable} ⇒ 通告抑制；
    /// 其余（未决/进行中/失败/不可用）⇒ 有则 `.visible`、无则 `.notRead`。
    public static func rowPresentation(chain: UpdateChainRowState,
                                       advice: UpdateAdviceRowState?) -> UpdateCenterRowPresentation {
        let note: UpdateCenterAdviceNote
        switch chain {
        case .upToDate, .updateAvailable, .noInstallableAvailable:
            note = .coveredByChainConclusion
        case .notChecked, .checking, .updating, .failed, .unavailable:
            note = advice.map(UpdateCenterAdviceNote.visible) ?? .notRead
        }
        return UpdateCenterRowPresentation(status: chain, advice: note)
    }
}
