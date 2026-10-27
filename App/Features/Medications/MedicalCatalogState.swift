import Foundation
import Domain
import Infrastructure
import Perception

/// 药品目录 App 读面：匹配是建议/证据，不自动写处方行 medication_id。
/// SP-64 检查/更新状态机已出列至 `MedicalCatalogUpdateCoordinator`（2026-09-28
/// 拆分，业主组合纪律）——本类只余读面（匹配/详情查询）与协调器组合；
/// 转发面保持视图/测试零变更。
@MainActor
@Perceptible
final class MedicalCatalogState {
    private var store: (any MedicalCatalogReading)?
    private let path: URL?
    /// 检查/更新协调器（组合——状态机全部逻辑在此，见其头注）。
    /// private（2026-09-28 终轮评审）：转发面是唯一使用面（全仓零 `.updates.` 直穿），
    /// 私有化避免双路径 API 漂移。
    private let updates: MedicalCatalogUpdateCoordinator
    var matchByLineID: [UUID: MedicalCatalogMatch] = [:]
    private(set) var generation: UInt64

    /// 2026-09-27 委员会 P3a：接 Domain 端口而非具体 Infrastructure 类型（四规则第 1 条）。
    init(store: (any MedicalCatalogReading)?, updater: MedicalCatalogUpdateService? = nil, path: URL? = nil,
         checker: (any MedicalCatalogReleaseResolving)? = nil,
         opener: (any MedicalCatalogPackageOpening)? = nil) {
        self.store = store
        self.path = path
        self.generation = store?.catalogGeneration ?? 0
        // 两段式装配（CI 36347424569）：闭包捕获 self 先于 updates 赋值会被
        // definite-initialization 拒绝——先构造再回填回调。
        self.updates = MedicalCatalogUpdateCoordinator(updater: updater, path: path,
                                                      checker: checker, opener: opener,
                                                      installedVersion: (store as? MedicalCatalogReadAccess).map { access in
                                                          { access.installedVersion }
                                                      })
        self.updates.onInstalled = { [weak self] in
            self?.reloadStore() ?? false
        }
    }

    var isAvailable: Bool {
        if let access = store as? MedicalCatalogReadAccess { return access.isAvailable }
        return store != nil
    }

    // MARK: - 协调器转发面（视图/测试零变更）

    var remoteState: MedicalCatalogRemoteState { updates.remoteState }
    var localVersion: MedicalCatalogInstalledVersion? { updates.localVersion }
    var localUpdatedAt: Date? { updates.localUpdatedAt }
    var updateProgress: MedicalCatalogDownloadProgress? { updates.updateProgress }
    var updateError: MedicalCatalogDownloadError? { updates.updateError }
    var updateCompletedDataVersion: String? { updates.updateCompletedDataVersion }
    var isUpdating: Bool { updates.isUpdating }
    var canCancelUpdate: Bool { updates.canCancelUpdate }
    var canCheck: Bool { updates.canCheck }

    func check() { updates.check() }
    func cancelCheck() { updates.cancelCheck() }
    func applyUpdate() { updates.applyUpdate() }
    func cancelUpdate() { updates.cancelUpdate() }

    // MARK: - 读面

    /// 安装成功后由协调器回调：重开读面 store + 清匹配缓存。
    /// 复开失败=**旧 store 不动**（旧 GRDB 池继续读旧 inode，读面保持可用——
    /// 1-vote 验证修复：此前 try? 赋值会把复开失败置成 store=nil，读面全空态），
    /// 返回 false 让协调器走 activationFailed 语义（与拆分前行为逐路径等价）。
    private func reloadStore() -> Bool {
        if let access = store as? MedicalCatalogReadAccess {
            guard access.isAvailable else { return false }
            generation = access.catalogGeneration
        } else {
            guard let path, let reopened = try? MedicalCatalogReadAccess(path: path) else { return false } // try?-ok: 双读面准备失败时不改变现态
            store = reopened
            generation = reopened.catalogGeneration
        }
        matchByLineID.removeAll()
        return true
    }

    func match(_ line: PrescriptionLine) async -> MedicalCatalogMatch? {
        guard let store else { return nil }
        let started = readGeneration(of: store)
        do {
            let result = try await store.match(line: line)
            guard readGeneration(of: store) == started else { return nil }
            matchByLineID[line.id] = result
            return result
        } catch {
            _ = readGeneration(of: store)
            return nil
        }
    }

    func drug(id: Int) async -> MedicalCatalogDrug? {
        guard let store else { return nil }
        let started = readGeneration(of: store)
        let result = try? await store.drug(id: id) // try?-ok: 目录查询失败=详情空态
        return readGeneration(of: store) == started ? result : nil
    }

    func references(for drug: MedicalCatalogDrug) async -> [MedicalCatalogReference] {
        guard let store else { return [] }
        let started = readGeneration(of: store)
        let result = (try? await store.reference(for: drug)) ?? [] // try?-ok: 目录查询失败=无参考链接
        return readGeneration(of: store) == started ? result : []
    }

    func detail(for drug: MedicalCatalogDrug) async -> MedicalCatalogDrugDetail? {
        guard let store else { return nil }
        let started = readGeneration(of: store)
        let result = try? await store.detail(for: drug) // try?-ok: 目录详情缺失=只展示主记录
        return readGeneration(of: store) == started ? result : nil
    }

    private func readGeneration(of store: any MedicalCatalogReading) -> UInt64 {
        let current = store.catalogGeneration
        if generation != current {
            matchByLineID.removeAll()
            generation = current
        }
        return current
    }
}
