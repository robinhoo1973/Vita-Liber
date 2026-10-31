import Foundation
import Domain
import Infrastructure
import Perception

/// 三切片目录 App 状态（2026-10-28 切片-only 批次）：
/// SP-64 医疗数据节 / 首启卡 / 更新中心医疗链的**唯一数据源**。
///
/// 只消费 Domain 检查结果（`CatalogSliceCheckOutcome`）与 Infrastructure 密封候选
/// （`CatalogSliceCheckEnvelope` 内部携带）+ 安装器；视图零 Infrastructure 决策。
/// 每片独立状态；聚合（已装 N/3 · M 个可更新等）在本层派生——语义不落数据层。
/// 零隐式联网：`check()`/`install*()` 只由用户显式动作调用（FR25.13/ADR-030）。
@MainActor
@Perceptible
final class CatalogSlicesState {
    /// 聚合态（SP-64 摘要 / 首启卡 C0–C9 / 更新中心主行共用）。
    enum Aggregate: Equatable {
        case notChecked
        case checking
        case updating
        case allCurrent
        case updatesAvailable
        case partialFailure
        case allFailed
        case appUpdateRequired
        /// 部分/全部片在发布源缺失（不删除本地，不回落他片）。
        case sourcePartial
        case unavailable
    }

    private let facade: CatalogSliceReadFacade
    private let checker: (any CatalogSliceReleaseResolving)?
    private let updater: (any CatalogSliceInstalling)?
    private let receiptDirectory: URL
    /// 仅 `updateAvailable` 时存在（密封候选，安装链唯一入口）。
    private var verified: [CatalogSliceKind: VerifiedCatalogSliceCandidate] = [:]
    private var checkTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    /// 本次安装开始时的已装片数（mock 1:1：`mandatory()` 的「本机 0 片」
    /// 在一次安装会话内必须冻结——逐片完成不得把强制卡中途翻成可选）。
    private(set) var installedCountAtUpdateStart: Int?

    private(set) var remote: [CatalogSliceKind: CatalogSliceRemoteState] = [:]
    private(set) var progress: [CatalogSliceKind: MedicalCatalogDownloadProgress] = [:]
    private(set) var errors: [CatalogSliceKind: MedicalCatalogDownloadError] = [:]
    /// 一次性成功事件（「已更新至 vN」只在成功后呈现一次）。
    private(set) var completedVersions: [CatalogSliceKind: Int64] = [:]
    private(set) var receipts: [CatalogSliceKind: CatalogSliceReceipt] = [:]
    /// 已激活但回执缺失（回执写失败/待下次启动 journal 重建）——SP-64 行需如实
    /// 显示「已安装 · 版本记录待恢复」，不得回落「未安装」（TD-SLICE-RECEIPT-01）。
    private(set) var receiptPendingKinds: Set<CatalogSliceKind> = []
    /// 处方行匹配缓存（generation 变化即失效；视图观察此表渲染建议）。
    var matchByLineID: [UUID: MedicalCatalogMatch] = [:]
    private var observedGeneration: UInt64 = 0
    /// 是否发生过显式检查尝试（FR25.13：checker 缺失时初始仍显示「检查更新」——
    /// 「暂不可用」只有在用户点按检查后才成立）。
    private var didAttemptCheck = false

    init(facade: CatalogSliceReadFacade,
         checker: (any CatalogSliceReleaseResolving)?,
         updater: (any CatalogSliceInstalling)?,
         receiptDirectory: URL) {
        self.facade = facade
        self.checker = checker
        self.updater = updater
        self.receiptDirectory = receiptDirectory
        self.observedGeneration = facade.catalogGeneration
        for kind in CatalogSliceKind.allCases {
            remote[kind] = .idle
            receipts[kind] = CatalogSliceReceipt.read(kind: kind, directory: receiptDirectory)
            if receipts[kind] == nil, Self.isInstalled(kind, facade: facade) {
                receiptPendingKinds.insert(kind)
            }
        }
    }

    // MARK: - 基础查询

    /// 全局 epoch（任一片 commit 递增）——`\.medicalCatalogGeneration` 环境键复用。
    var generation: UInt64 { facade.catalogGeneration }
    var isAvailable: Bool { checker != nil || updater != nil }

    func isInstalled(_ kind: CatalogSliceKind) -> Bool {
        Self.isInstalled(kind, facade: facade)
    }

    private static func isInstalled(_ kind: CatalogSliceKind,
                                    facade: CatalogSliceReadFacade) -> Bool {
        switch kind {
        case .drug: return facade.isDrugAvailable
        case .facility: return facade.isFacilityAvailable
        case .reference: return facade.isExamAvailable
        case .profile: return facade.isProfileAvailable
        }
    }

    var installedCount: Int { CatalogSliceKind.allCases.filter(isInstalled).count }

    func remoteState(_ kind: CatalogSliceKind) -> CatalogSliceRemoteState { remote[kind] ?? .idle }
    func candidate(_ kind: CatalogSliceKind) -> CatalogSliceCheckCandidate? {
        if case .updateAvailable(let candidate) = remoteState(kind) { return candidate }
        return nil
    }
    func localVersion(_ kind: CatalogSliceKind) -> Int64? { receipts[kind]?.catalogVersion }
    func localUpdatedAt(_ kind: CatalogSliceKind) -> Date? { receipts[kind]?.installedAt }

    var candidates: [CatalogSliceCheckCandidate] {
        CatalogSliceKind.allCases.compactMap(candidate)
    }

    var hasCandidate: Bool { !candidates.isEmpty }
    var totalDownloadBytes: Int64 { candidates.reduce(0) { $0 + $1.packageSize } }

    /// 只由完成事件驱动（首启卡「完成 → 自动进入」判据）。
    var hasCompletedAnyUpdate: Bool { !completedVersions.isEmpty }

    var canCheck: Bool { checkTask == nil && updateTask == nil }
    var canUpdate: Bool { updater != nil && !verified.isEmpty && updateTask == nil && checkTask == nil }
    var isUpdating: Bool { updateTask != nil }
    func isUpdating(_ kind: CatalogSliceKind) -> Bool { progress[kind] != nil }

    func canCancelUpdate(_ kind: CatalogSliceKind) -> Bool {
        guard let progress = progress[kind] else { return false }
        if case .activating = progress { return false }   // journal 契约：切换阶段不可取消
        return true
    }

    // MARK: - 读面（药品切片；缺片=查询空态，患者流零提示）

    /// 处方行匹配（建议/证据，不自动写 medication_id；BR-003/004）。
    func match(_ line: PrescriptionLine) async -> MedicalCatalogMatch? {
        let started = readGeneration()
        do {
            let result = try await facade.match(line: line)
            guard readGeneration() == started else { return nil }
            matchByLineID[line.id] = result
            return result
        } catch {
            _ = readGeneration()
            return nil
        }
    }

    func drug(id: Int) async -> MedicalCatalogDrug? {
        let started = readGeneration()
        let value = try? await facade.drug(id: id)   // try?-ok: 缺片/查询失败=详情空态
        return readGeneration() == started ? value : nil
    }

    func references(for drug: MedicalCatalogDrug) async -> [MedicalCatalogReference] {
        let started = readGeneration()
        let value = (try? await facade.reference(for: drug)) ?? []   // try?-ok: 缺片/查询失败=无参考链接
        return readGeneration() == started ? value : []
    }

    func detail(for drug: MedicalCatalogDrug) async -> MedicalCatalogDrugDetail? {
        let started = readGeneration()
        let value = try? await facade.detail(for: drug)   // try?-ok: 缺片/查询失败=只展示主记录
        return readGeneration() == started ? value : nil
    }

    /// 说明书分节结果：未收录 / 旧目录 / 读失败 三态必须分开，不能压成「没有」。
    enum LeafletResult: Sendable, Equatable {
        case unavailable
        case legacySchema
        case failed
        case loaded([MedicalCatalogLeafletBundle])
    }

    struct MedicalCatalogLeafletBundle: Sendable, Equatable, Identifiable {
        var id: String { leaflet.sourceID }
        let leaflet: MedicalCatalogLeaflet
        let sections: [MedicalCatalogLeafletSection]
        let text: String
    }

    func leaflets(for drug: MedicalCatalogDrug) async -> LeafletResult {
        let started = readGeneration()
        do {
            let sources = try await facade.leafletSources(forDrugID: drug.id)
            guard readGeneration() == started else { return .failed }
            if sources.isEmpty { return .loaded([]) }
            var bundles: [MedicalCatalogLeafletBundle] = []
            for leaflet in sources {
                let sections = try await facade.leafletSections(docSHA256: leaflet.docSHA256)
                let text = try await facade.leafletText(docSHA256: leaflet.docSHA256)
                bundles.append(MedicalCatalogLeafletBundle(leaflet: leaflet, sections: sections, text: text))
            }
            guard readGeneration() == started else { return .failed }
            return .loaded(bundles)
        } catch let error as CatalogSliceLeafletFailure {
            switch error {
            case .legacySchema: return .legacySchema
            case .unavailable: return .unavailable
            case .corruptText: return .failed
            }
        } catch {
            return .failed
        }
    }

    private func readGeneration() -> UInt64 {
        let current = facade.catalogGeneration
        if observedGeneration != current {
            matchByLineID.removeAll()
            observedGeneration = current
        }
        return current
    }

    // MARK: - 检查（一次显式点击扇出三片；单飞）

    func check() {
        guard checkTask == nil, updateTask == nil else { return }
        didAttemptCheck = true
        guard let checker else {
            for kind in CatalogSliceKind.allCases { remote[kind] = .unavailable }
            return
        }
        for kind in CatalogSliceKind.allCases {
            remote[kind] = .checking
            errors[kind] = nil
            completedVersions[kind] = nil
        }
        checkTask = Task { [weak self] in
            guard let self else { return }
            let envelope: CatalogSliceCheckEnvelope
            do {
                envelope = try await checker.check()
            } catch is CancellationError {
                self.finishCheck(Self.uniformOutcome(.idle, receipts: self.receipts))
                return
            } catch {
                self.finishCheck(Self.uniformOutcome(.networkUnavailable, receipts: self.receipts))
                return
            }
            guard !Task.isCancelled else {
                self.finishCheck(Self.uniformOutcome(.idle, receipts: self.receipts))
                return
            }
            self.finishCheck(envelope)
        }
    }

    func cancelCheck() {
        checkTask?.cancel()
    }

    private func finishCheck(_ envelope: CatalogSliceCheckEnvelope) {
        verified = [:]
        for kind in CatalogSliceKind.allCases { errors[kind] = nil }
        for result in envelope.outcome.results {
            remote[result.kind] = result.state
            if case .updateAvailable = result.state,
               let candidate = envelope.candidate(result.kind) {
                verified[result.kind] = candidate
            }
        }
        checkTask = nil
    }

    private func finishCheck(_ outcome: CatalogSliceCheckOutcome) {
        finishCheck(CatalogSliceCheckEnvelope(outcome: outcome, verified: [:]))
    }

    private static func uniformOutcome(_ state: CatalogSliceRemoteState,
                                       receipts: [CatalogSliceKind: CatalogSliceReceipt])
        -> CatalogSliceCheckOutcome {
        CatalogSliceCheckOutcome(results: CatalogSliceKind.allCases.map {
            CatalogSliceCheckResult(kind: $0, state: state,
                                    localCatalogVersion: receipts[$0]?.catalogVersion)
        })
    }

    // MARK: - 安装（用户第二次显式动作；全局串行按片排队，小片先行）

    func install(_ kind: CatalogSliceKind) {
        guard verified[kind] != nil else { return }
        startUpdate(kinds: [kind])
    }

    func installAll() {
        let pending = CatalogSliceKind.allCases
            .filter { verified[$0] != nil }
            .sorted { lhs, rhs in
                (verified[lhs]?.packageSize ?? .max) < (verified[rhs]?.packageSize ?? .max)
            }
        startUpdate(kinds: pending)
    }

    func cancelUpdate() {
        updateTask?.cancel()
    }

    private func startUpdate(kinds: [CatalogSliceKind]) {
        guard updateTask == nil, checkTask == nil, !kinds.isEmpty else { return }
        guard let updater else {
            for kind in kinds { errors[kind] = .catalogNotConfigured }
            return
        }
        for kind in kinds {
            errors[kind] = nil
            completedVersions[kind] = nil
        }
        installedCountAtUpdateStart = installedCount
        updateTask = Task { [weak self] in
            guard let self else { return }
            for kind in kinds {
                guard let candidate = self.verified[kind] else { continue }
                if Task.isCancelled { break }
                self.progress[kind] = .downloading(receivedBytes: 0, totalBytes: candidate.packageSize)
                do {
                    try await updater.update(candidate) { [weak self] progress in
                        Task { @MainActor in self?.progress[kind] = progress }
                    }
                    self.finishInstall(kind, fallbackVersion: candidate.catalogVersion)
                } catch let error as MedicalCatalogDownloadError {
                    self.errors[kind] = error
                    self.progress[kind] = nil
                } catch {
                    self.errors[kind] = .activationFailed
                    self.progress[kind] = nil
                }
            }
            self.updateTask = nil
            self.installedCountAtUpdateStart = nil
        }
    }

    /// 装后收口：刷新回执 + 重开该片读面 store（失败保留旧读面，不回滚已激活）。
    /// 回执缺失但已激活：保留版本事件真值（candidate），并标记待恢复供行内提示
    /// （TD-SLICE-RECEIPT-01；journal 在下一次启动重建回执）。
    private func finishInstall(_ kind: CatalogSliceKind, fallbackVersion: Int64) {
        receipts[kind] = CatalogSliceReceipt.read(kind: kind, directory: receiptDirectory)
        reopenStore(kind)
        progress[kind] = nil
        verified[kind] = nil
        let version = receipts[kind]?.catalogVersion ?? fallbackVersion
        completedVersions[kind] = version
        // 回执缺失时保留 nil（UI 走「版本记录待恢复」），不得用 candidate 版本
        // 冒充回执真值；completedVersions 仍记 candidate 版本供一次性完成事件。
        remote[kind] = .upToDate(catalogVersion: receipts[kind]?.catalogVersion)
        if receipts[kind] == nil, isInstalled(kind) {
            receiptPendingKinds.insert(kind)
        } else {
            receiptPendingKinds.remove(kind)
        }
    }

    private func reopenStore(_ kind: CatalogSliceKind) {
        let url = CatalogSliceUpdateService.activeURL(kind, directory: receiptDirectory)
        switch kind {
        case .drug:
            if let store = try? CatalogSliceDrugStore(path: url) { facade.commitDrug(store) }   // try?-ok: 复开失败保留旧读面
        case .facility:
            if let store = try? CatalogSliceFacilityStore(path: url) { facade.commitFacility(store) }   // try?-ok: 同上
        case .reference:
            if let store = try? CatalogSliceExamStore(path: url) { facade.commitExam(store) }   // try?-ok: 同上
        case .profile:
            if let store = try? CatalogSliceProfileStore(path: url) { facade.commitProfile(store) }   // try?-ok: 同上
        }
    }

    // MARK: - 聚合

    var aggregate: Aggregate {
        if updateTask != nil { return .updating }
        if checkTask != nil { return .checking }
        // FR25.13 零隐式判定（2026-10-28 B2 回归修复，CI 40618700435）：checker 缺失
        // 本身不等于「暂不可用」——用户还没点过检查时保持 .notChecked（按钮「检查更新」），
        // 点按后 check() 已把全片置 .unavailable（按钮才变「重新检查」）。
        guard checker != nil else { return didAttemptCheck ? .unavailable : .notChecked }
        let states = CatalogSliceKind.allCases.map(remoteState)
        func isFailure(_ state: CatalogSliceRemoteState) -> Bool {
            switch state {
            case .rateLimited, .networkUnavailable, .verificationFailed: return true
            default: return false
            }
        }
        func isTerminalOk(_ state: CatalogSliceRemoteState) -> Bool {
            switch state {
            case .upToDate, .sourceNotProvided, .removedFromSource: return true
            default: return false
            }
        }
        func isSourceGap(_ state: CatalogSliceRemoteState) -> Bool {
            switch state {
            case .sourceNotProvided, .removedFromSource: return true
            default: return false
            }
        }
        if states.allSatisfy({ if case .idle = $0 { return true }; return false }) {
            return .notChecked
        }
        let failures = states.filter(isFailure).count
        let hasUpdate = states.contains { if case .updateAvailable = $0 { return true }; return false }
        let hasAppGate = states.contains { if case .appUpdateRequired = $0 { return true }; return false }
        if hasUpdate { return failures > 0 ? .partialFailure : .updatesAvailable }
        if hasAppGate { return .appUpdateRequired }
        if failures == states.count { return .allFailed }
        if failures > 0 { return .partialFailure }
        if states.allSatisfy(isTerminalOk) {
            return states.contains(where: isSourceGap) ? .sourcePartial : .allCurrent
        }
        return .notChecked
    }
}

// MARK: - 更新中心链驱动

extension CatalogSlicesState: UpdateChainDriving {
    var chainSummary: UpdateChainRowState {
        if isUpdating { return .updating }
        switch aggregate {
        case .notChecked: return .notChecked
        case .checking: return .checking
        case .updating: return .updating
        case .allCurrent, .sourcePartial: return .upToDate
        case .updatesAvailable, .partialFailure: return .updateAvailable
        case .allFailed: return .failed
        case .appUpdateRequired: return .noInstallableAvailable
        case .unavailable: return .unavailable
        }
    }
    // check() / cancelCheck() 已是同名公开方法（协议成员自动满足）。
}
