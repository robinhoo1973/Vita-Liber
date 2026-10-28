import Foundation
import Domain

/// 患者主库目录扫描（B0 转换登记表批，2026-10-29）。
///
/// Foundation-only（不依赖 GRDB），Linux 可跑；供启动门在 open 之前把
/// 「目录实况」变成 `DatabaseNameResolution`——路径解析必须先于建池/
/// 迁移（改名恒先于 open，见 DatabaseFileMigration 与转换登记表硬约束）。
public enum PatientDatabaseLocator {
    /// 实际存在、且 lowercased 命中注册名全集的**常规文件**名。
    /// 目录不可读按「无候选」处理：是否丢库由启动门原件证据另判，不在此抛错。
    public static func presentNames(in directory: URL,
                                    fileManager: FileManager = .default) -> [String] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] // try?-ok: 不可读=无候选，fresh/失败判定归启动门
        return names.filter { name in
            guard PatientDatabaseNames.isRegistered(name) else { return false }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.appendingPathComponent(name).path,
                                         isDirectory: &isDirectory) else { return false }
            return !isDirectory.boolValue
        }
    }

    /// 目录 → 解析结论（0 命中 missing / 1 命中 single / ≥2 命中 ambiguous）。
    public static func resolve(in directory: URL,
                               fileManager: FileManager = .default) -> DatabaseNameResolution {
        DatabaseNameResolution.decide(
            presentNames: presentNames(in: directory, fileManager: fileManager))
    }
}
