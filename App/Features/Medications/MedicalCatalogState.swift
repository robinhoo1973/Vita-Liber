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
    let updates: MedicalCatalogUpdateCoordinator
    var matchByLineID: [UUID: MedicalCatalogMatch] = [:]

    /// 2026-09-27 委员会 P3a：接 Domain 端口而非具体 Infrastructure 类型（四规则第 1 条）。
    init(store: (any MedicalCatalogReading)?, updater: MedicalCatalogUpdateService? = nil, path: URL? = nil,
         checker: (any MedicalCatalogReleaseResolving)? = nil,
         opener: (any MedicalCatalogPackageOpening)? = nil) {
        self.store = store
        self.path = path
        self.updates = MedicalCatalogUpdateCoordinator(updater: updater, path: path,
                                                      checker: checker, opener: opener,
                                                      onInstalled: { [weak self] in
                                                          guard let self else { return false }
                                                          self.reloadStore()
                                                          return self.store != nil
                                                      })
    }

    var isAvailable: Bool { store != nil }

    // MARK: - 协调器转发面（视图/测试零变更）

    var remoteState: MedicalCatalogRemoteState { updates.remoteState }
    var localVersion: MedicalCatalogInstalledVersion? { updates.localVersion }
    var localUpdatedAt: Date? { updates.localUpdatedAt }
    var updateProgress: MedicalCatalogDownloadProgress? { updates.updateProgress }
    var updateError: MedicalCatalogDownloadError? { updates.updateError }
    var updateCompletedDataVersion: String? { updates.updateCompletedDataVersion }
    var isUpdating: Bool { updates.isUpdating }
    var canCancelUpdate: Bool { updates.canCancelUpdate }

    func check() { updates.check() }
    func cancelCheck() { updates.cancelCheck() }
    func applyUpdate() { updates.applyUpdate() }
    func cancelUpdate() { updates.cancelUpdate() }

    // MARK: - 读面

    /// 安装成功后由协调器回调：重开读面 store + 清匹配缓存。
    /// 复开失败=读面保持旧 inode 连接（下次启动收敛），返回 false 让协调器
    /// 走 activationFailed 语义（与拆分前行为逐路径等价）。
    private func reloadStore() {
        guard let path else { return }
        store = try? MedicalCatalogStore(path: path) // try?-ok: 复开失败=读面保持旧连接，协调器按失败语义呈现
        matchByLineID.removeAll()
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
}
