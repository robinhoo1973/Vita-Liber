import Foundation
import Domain
import os

/// v4 目录残留自动清理（2026-10-28 切片-only B2-4：自动更新/迁移「前一数据库」）。
///
/// 触发条件（两轮委员会裁决一致）：**三切片全部就绪**（启动期自洽探测 ready=3）
/// 才清理 v4 遗留；三片未替换前绝不删除（旧版仍是可用数据）。清理在启动门
/// `prepareSync` 内、UI 之前执行；幂等、失败只记日志；路径全部为固定常量
/// （目录白名单 = `AppSupport/VitaLiber/MedicalCatalog`，不接受任何外部输入）。
enum LegacyCatalogResidue {
    /// v4 单包与配套状态件（固定名；journal 名取自 v4 生产装配常量 @ ea2eda60）。
    static let fileNames = [
        "medical-catalog.sqlite",
        "medical-catalog.sqlite-wal",
        "medical-catalog.sqlite-shm",
        "medical-catalog.sqlite.last-good",
        "medical-catalog-trust.json",
        "medical-catalog-activation.journal.json",
    ]
    /// v4 只读快照目录（旧 ReadAccess 钉住的临时库，`MedicalCatalogSnapshotFile`）。
    static let snapshotDirectoryName = ".medical-catalog-read-snapshots"

    private static let logger = Logger(subsystem: "com.vitaliber", category: "catalog-legacy")

    /// 返回 true = 满足条件并已执行清理（幂等空跑也返回 true）；未满足条件返回 false。
    @discardableResult
    static func cleanIfEligible(sliceReadyCount: Int, fileManager: FileManager = .default) -> Bool {
        guard sliceReadyCount == CatalogSliceKind.allCases.count else { return false }
        let support = URL(fileURLWithPath: AppContainer.defaultMedicalCatalogPath())
            .deletingLastPathComponent()
        for name in fileNames {
            let url = support.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                logger.error("v4 残留清理失败(\(name, privacy: .public)): \(String(describing: error), privacy: .public)")
            }
        }
        let snapshots = support.appendingPathComponent(snapshotDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: snapshots.path) {
            do {
                try fileManager.removeItem(at: snapshots)
            } catch {
                logger.error("v4 快照目录清理失败: \(String(describing: error), privacy: .public)")
            }
        }
        return true
    }
}
