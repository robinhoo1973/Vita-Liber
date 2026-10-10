import Foundation
import Domain
import Infrastructure
import Perception

/// T2 本机 LLM 模型安装中心（2026-10-09 换型+下载化批）：
/// 模型不随包（单独编译 + 运行时自 CNB 下载）——本中心持有全部安装态，
/// 供「模型与数据资源」页与（后续批）首页下载卡消费。
///
/// 与 ASR 安装中心同纪律（2026-09-16 教训逐条继承）：
/// - 状态上提到 App 层（跨页 ± 切后台存活；离开设置页不丢进度）；
/// - 高频进度放独立 `ProgressBox` 观察域（数组/复合写入会令全量观察视图
///   每次进度回调重渲染——ASR 中心当初「进度条卡住」的根因）；
/// - 完成广播 `assetsChanged()`（引擎可用性/资源行据其重算）。
///
/// 首启下载语义（ADR-030 口径：唯一获准下载面 = 用户显式发起）：
/// 采用「**一次显式同意 + 之后自动续传/重试**」——同意卡（资源页入口，后续批补首页卡）
/// 记 `llm.model.consent.v1`；此后每次启动 `autoInstallIfEligible()` 幂等补齐，
/// 不做静默联网（未同意 = 只呈现入口，绝不自动发请求）。
@MainActor
@Perceptible
final class LLMModelInstallCenter {

    /// 安装状态机（低频；进度在 `ProgressBox`）。
    enum State: Equatable {
        case notInstalled
        case downloading
        case verifying
        case activating
        case installed
        case failed(FailureKind)

        var isBusy: Bool {
            switch self {
            case .downloading, .verifying, .activating: return true
            default: return false
            }
        }
    }

    enum FailureKind: Equatable {
        case needSpace
        case verify
        case network
        case other
    }

    /// 高频进度独立观察域（0.5s 级回调只令进度条自身重渲染）。
    @MainActor
    @Perceptible
    final class ProgressBox {
        var fraction: Double?
        var receivedBytes: Int64 = 0
        var totalBytes: Int64 = 0
    }

    private let dataChange: AppDataChangeCenter
    private(set) var state: State = .notInstalled
    let progress = ProgressBox()
    private var installTask: Task<Void, Never>?

    /// 一次显式同意标记（同意后自动续传/重试不再逐次询问；拉黑语义 = 删键）。
    private static let consentKey = "llm.model.consent.v1"

    init(dataChange: AppDataChangeCenter) {
        self.dataChange = dataChange
        refresh()
    }

    // MARK: - 解析面

    /// 目录首选条目（随签名二进制发布 = 信任锚；条目缺席 = 本次构建未配置模型）。
    var entry: LLMModelCatalog.Entry? {
        LlamaModelManager.catalogDocument()?.preferred.first
    }

    /// 已安装版本（未安装 → nil）。
    var installedVersion: String? {
        guard let entry else { return nil }
        return LlamaModelManager.installedVersion(id: entry.id)
    }

    /// 手动更新判定：目录版本 ≠ 已安装版本（目录随 App 版本更新；
    /// 网络侧"最新模型"发现需签名索引，登记为后续批——见批报告 D 项）。
    var updateAvailable: Bool {
        guard let entry, let installed = installedVersion else { return false }
        return installed != entry.version
    }

    var installedBytes: Int64 {
        guard let entry else { return 0 }
        return LlamaModelManager.modelSize(id: entry.id)
    }

    var consentGranted: Bool {
        UserDefaults.standard.bool(forKey: Self.consentKey)
    }

    // MARK: - 动作面

    func refresh() {
        guard installTask == nil else { return }
        state = LlamaModelManager.activeModel() != nil ? .installed : .notInstalled
    }

    /// 一次显式同意（同意即安装）。
    func grantConsentAndInstall() {
        UserDefaults.standard.set(true, forKey: Self.consentKey)
        startInstall()
    }

    /// 首启/回前台的幂等自动安装：已就绪不动；未同意绝不自作主张；
    /// 低电量模式不自动发起（呈现入口由 UI 负责）。
    func autoInstallIfEligible() {
        guard installTask == nil,
              LlamaModelManager.activeModel() == nil,
              consentGranted,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        startInstall()
    }

    func startInstall() {
        guard installTask == nil, let entry else { return }
        state = .downloading
        progress.fraction = 0
        progress.receivedBytes = 0
        progress.totalBytes = entry.bytes
        installTask = Task { [weak self] in
            do {
                _ = try await LLMModelDownloadService.shared.install(
                    entry,
                    progress: { update in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.progress.fraction = update.fraction
                            self.progress.receivedBytes = update.receivedBytes
                            self.progress.totalBytes = update.totalBytes
                        }
                    },
                    onPhase: { phase in
                        Task { @MainActor [weak self] in
                            self?.apply(phase)
                        }
                    })
                self?.finish(with: .installed)
            } catch is CancellationError {
                self?.finish(with: .notInstalled)
            } catch {
                self?.finish(with: .failed(Self.kind(of: error)))
            }
        }
    }

    func cancel() {
        installTask?.cancel()
    }

    func remove() {
        guard let entry else { return }
        // S-3（第九轮审查 P7#1，权重重判定案）：删除 = **吊销同意**——类文档
        // 自述「拉黑语义 = 删键」，但此前 remove() 从不删键：用户为腾空间删除
        // 后，下一次冷启动 autoInstallIfEligible()（同意仍为 true、模型已缺）
        // 会静默重新下载 ~396MB。现在删除即清 consent key：自动补齐不再触发，
        // 重装必须再经用户显式同意（grantConsentAndInstall）。
        UserDefaults.standard.removeObject(forKey: Self.consentKey)
        Task { [weak self] in
            try? await LLMModelDownloadService.shared.remove(id: entry.id)   // try?-ok: 删除失败按幂等处理，refresh 会校正呈现
            await MainActor.run { [weak self] in
                self?.state = .notInstalled
                self?.dataChange.assetsChanged()
            }
        }
    }

    // MARK: - 私有

    private func apply(_ phase: LLMModelDownloadService.Phase) {
        switch phase {
        case .downloading: state = .downloading
        case .verifying: state = .verifying
        case .activating: state = .activating
        }
    }

    private func finish(with terminal: State) {
        state = terminal
        installTask = nil
        progress.fraction = nil
        dataChange.assetsChanged()
    }

    private static func kind(of error: Error) -> FailureKind {
        guard let failure = error as? ASRDownloadFailure else { return .other }
        switch failure {
        case .insufficientStorage: return .needSpace
        case .checksumMismatch, .sizeMismatch: return .verify
        case .badAddress, .badResponse: return .network
        default: return .other
        }
    }
}
