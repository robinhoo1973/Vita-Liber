import Foundation
import Domain
import Infrastructure
import Perception

/// 药品目录 App 读面：匹配是建议/证据，不自动写处方行 medication_id。
/// SP-64（2026-09-27）：承载检查/更新状态机——本地状态与远端检查态分离、
/// 检查与更新单飞、失败/取消保留 last-good（安装器契约保证，状态面只如实呈现）。
@MainActor
@Perceptible
final class MedicalCatalogState {
    private var store: (any MedicalCatalogReading)?
    private let updater: MedicalCatalogUpdateService?
    private let path: URL?
    private let checker: (any MedicalCatalogReleaseResolving)?
    private let opener: (any MedicalCatalogPackageOpening)?
    var matchByLineID: [UUID: MedicalCatalogMatch] = [:]

    /// 远端检查态（Domain 类型：视图不 import Infrastructure，委员会 P3c 纪律）。
    var remoteState: MedicalCatalogRemoteState = .idle
    /// 本机已激活目录身份（启动时读取；更新成功后刷新）。
    private(set) var localVersion: MedicalCatalogInstalledVersion?
    /// 本机目录文件激活时间（目录文件 mtime = 原子替换时刻；启动时读取，更新后刷新）。
    private(set) var localUpdatedAt: Date?
    /// 更新进度（五阶段，Domain 类型）。
    private(set) var updateProgress: MedicalCatalogDownloadProgress?
    /// 更新失败词汇（失败/取消后本机 last-good 仍可用）。
    private(set) var updateError: MedicalCatalogDownloadError?
    /// 一次性成功事件（§5.12.4「成功才展示更新完成及新本地版本」）：成功后设置、
    /// 下一次检查/更新开始时清除——成功是事件不是状态，不能由 upToDate 推断。
    private(set) var updateCompletedDataVersion: String?
    /// 仅验签候选可进入安装：resolver 产出后由本状态持有，视图只有 Domain 摘要。
    private var verifiedCandidate: VerifiedMedicalCatalogCandidate?
    private var checkTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?

    /// 2026-09-27 委员会 P3a：接 Domain 端口而非具体 Infrastructure 类型（四规则第 1 条；
    /// updater 仍为具体类型——其更新/解密职责尚无 Domain 端口，属下一轮架构收敛，
    /// 已登记 P3 台账）。
    /// checker/opener 为 SP-64 新增（2026-09-27）：由组装根注入，缺省 nil =
    /// 未配置/未 provisioning，检查 fail-closed 呈「暂不可用」。
    init(store: (any MedicalCatalogReading)?, updater: MedicalCatalogUpdateService? = nil, path: URL? = nil,
         checker: (any MedicalCatalogReleaseResolving)? = nil,
         opener: (any MedicalCatalogPackageOpening)? = nil) {
        self.store = store
        self.updater = updater
        self.path = path
        self.checker = checker
        self.opener = opener
        if let path {
            localVersion = try? MedicalCatalogStore.installedVersion(path: path) // try?-ok: 目录缺失/损坏=无本地版本，检查仍可用（目录功能降级纪律）
            localUpdatedAt = Self.fileModificationDate(path)
        }
    }

    var isAvailable: Bool { store != nil }

    var isUpdating: Bool { updateTask != nil }

    /// 目录文件 mtime（原子替换时刻）；读不到按「未知」处理（UI 隐藏时间行）。
    private static func fileModificationDate(_ path: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path.path) // try?-ok: 读取失败=无本地更新时间，不影响其它状态
        return (attributes?[.modificationDate] as? Date)
    }

    func match(_ line: PrescriptionLine) async -> MedicalCatalogMatch? {
        guard let store else { return nil }
        do {
            let result = try await store.match(line: line)
            matchByLineID[line.id] = result
            return result
        } catch {
            return nil
        }
    }

    func drug(id: Int) async -> MedicalCatalogDrug? {
        guard let store else { return nil }
        return try? await store.drug(id: id) // try?-ok: 目录查询失败=详情空态（ProgressView 降级，不崩）
    }

    func references(for drug: MedicalCatalogDrug) async -> [MedicalCatalogReference] {
        guard let store else { return [] }
        return (try? await store.reference(for: drug)) ?? [] // try?-ok: 目录查询失败=无参考链接（降级不崩）
    }

    func detail(for drug: MedicalCatalogDrug) async -> MedicalCatalogDrugDetail? {
        guard let store else { return nil }
        return try? await store.detail(for: drug) // try?-ok: 目录详情缺失=只展示主记录
    }

    // MARK: - SP-64 检查/更新状态机

    /// 显式「检查更新」：resolver 单飞；取消/网络失败回到可重试状态。
    /// 只有用户点按钮才发起网络（FR25.13 零隐式联网——启动/页面出现均不调用本方法）。
    func check() {
        guard checkTask == nil, updateTask == nil else { return }
        remoteState = .checking
        updateError = nil
        updateCompletedDataVersion = nil
        checkTask = Task { [weak self] in
            guard let self else { return }
            let outcome: MedicalCatalogCheckOutcome
            do {
                guard let checker = self.checker else {
                    self.finishCheck(state: .unavailable)
                    return
                }
                outcome = try await checker.check()
            } catch is CancellationError {
                self.finishCheck(state: .idle)
                return
            } catch {
                self.finishCheck(state: .networkUnavailable)
                return
            }
            guard !Task.isCancelled else {
                self.finishCheck(state: .idle)
                return
            }
            self.verifiedCandidate = outcome.candidate
            self.finishCheck(state: outcome.state)
        }
    }

    private func finishCheck(state: MedicalCatalogRemoteState) {
        remoteState = state
        checkTask = nil
    }

    /// 取消检查：resolver 在 await 边界响应取消，状态回「未检查」。
    func cancelCheck() {
        checkTask?.cancel()
    }

    /// 显式「更新」：下载/校验/原子替换全链由安装器执行（五阶段进度）。
    /// 失败/取消保留本机 last-good（安装器契约），状态面只如实呈现错误。
    func applyUpdate() {
        guard let candidate = verifiedCandidate, let updater, let path,
              updateTask == nil, checkTask == nil else { return }
        updateError = nil
        updateCompletedDataVersion = nil
        // expiry 前置（与安装器入口 guard 同源，2026-09-27 评审修复）：候选可在
        // 页面上停留数日，过期即拒——「expiry 约束安装新鲜度」不只在检查时刻生效。
        guard candidate.expiresAt > Date() else {
            updateError = .catalogNotInstallable
            return
        }
        // 占位进度：取消按钮从更新一开始即可用（评审修复：此前首个进度事件到达前
        // canCancelUpdate == false，取消按钮不渲染，弱网下用户无法中止下载）。
        updateProgress = .downloading(receivedBytes: 0, totalBytes: candidate.packageSize)
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let opener = self.opener else {
                    self.updateError = .packageInvalid
                    self.updateTask = nil
                    self.updateProgress = nil
                    return
                }
                try await updater.update(candidate: candidate, opener: opener) { [weak self] progress in
                    // 进度回调在下载/校验后台线程：hop 回主 actor 更新可感知状态。
                    Task { @MainActor in self?.updateProgress = progress }
                }
                self.store = try MedicalCatalogStore(path: path)
                self.localVersion = try? MedicalCatalogStore.installedVersion(path: path) // try?-ok: 复开成功即已确认，读版本失败不影响使用
                self.localUpdatedAt = Self.fileModificationDate(path)
                self.matchByLineID.removeAll()
                self.verifiedCandidate = nil
                self.updateProgress = nil
                self.remoteState = .upToDate
                self.updateCompletedDataVersion = candidate.dataVersion
            } catch let error as MedicalCatalogDownloadError {
                self.updateError = error
                self.updateProgress = nil
            } catch {
                // 复开失败等非词汇错误：激活可能已完成（journal.complete），尽力刷新
                // 本地版本/时间呈现，避免 UI 与磁盘事实长期分歧（下次启动收敛）。
                self.updateError = .activationFailed
                self.updateProgress = nil
                self.localVersion = try? MedicalCatalogStore.installedVersion(path: path) // try?-ok: 尽力刷新，读不到保持旧值
                self.localUpdatedAt = Self.fileModificationDate(path)
            }
            self.updateTask = nil
        }
    }

    /// 取消更新：切换阶段（.activating）开始后安装器不再响应取消（journal 契约），
    /// UI 依 `canCancelUpdate` 隐藏取消按钮。
    func cancelUpdate() {
        updateTask?.cancel()
    }

    var canCancelUpdate: Bool {
        guard let progress = updateProgress else { return false }
        if case .activating = progress { return false }
        return true
    }
}
