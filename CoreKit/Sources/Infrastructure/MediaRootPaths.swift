import Foundation

/// 媒体根路径解析（2026-10-27 存储边界委员会 P0：PHI 根迁出 Documents）。
///
/// canonical（权威二进制）根 = `Application Support/VitaLiber/Media/MedicalNotes`；
/// 旧布局 `Documents/MedicalNotes` 仅作迁移来源与丢失判据证据（只读容忍，
/// 双根并存时绝不合并/删除）。导出副本树是 Documents 下唯一的用户面内容
/// （镜像批次实现），canonical 私域永不再落 Documents。
/// 纯 Foundation、无平台守卫——Linux 可跑单测（路径全注入）。
public enum MediaRootPaths {
    public static let mediaDirectoryName = "Media"
    public static let medicalNotesDirectoryName = "MedicalNotes"
    public static let originalsDirectoryName = "originals"
    public static let sensitiveDirectoryName = "sensitive"

    /// meta_json / asset.relative_path 的相对前缀（相对 mediaBase）。
    public static let relativePrefix = "MedicalNotes"

    // MARK: - 基址

    public static func applicationSupportBase(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
    }

    public static func documentsBase(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
    }

    /// canonical 媒体基（相对路径锚）：`<AppSupport>/VitaLiber/Media`。
    public static func mediaBase(applicationSupportBase: URL) -> URL {
        applicationSupportBase.appendingPathComponent("VitaLiber/\(mediaDirectoryName)", isDirectory: true)
    }

    public static func mediaBase(fileManager: FileManager = .default) -> URL {
        mediaBase(applicationSupportBase: applicationSupportBase(fileManager: fileManager))
    }

    public static func canonicalMedicalNotesRoot(mediaBase: URL) -> URL {
        mediaBase.appendingPathComponent(medicalNotesDirectoryName, isDirectory: true)
    }

    public static func canonicalMedicalNotesRoot(fileManager: FileManager = .default) -> URL {
        canonicalMedicalNotesRoot(mediaBase: mediaBase(fileManager: fileManager))
    }

    public static func legacyMedicalNotesRoot(documentsBase: URL) -> URL {
        documentsBase.appendingPathComponent(medicalNotesDirectoryName, isDirectory: true)
    }

    public static func legacyMedicalNotesRoot(fileManager: FileManager = .default) -> URL {
        legacyMedicalNotesRoot(documentsBase: documentsBase(fileManager: fileManager))
    }

    // MARK: - 双形态解析

    /// meta_json `original_path`/`processed_path` 与 asset.relative_path 的统一解析：
    /// - 绝对路径（旧行；v49 迁移后应已改写）→ 原样使用（双形态读容忍回滚/异常）；
    /// - 相对路径（新写；如 `MedicalNotes/originals/…`）→ `mediaBase + path`；
    /// - 空白 → nil。
    public static func resolve(path: String, mediaBase: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed) }
        return mediaBase.appendingPathComponent(trimmed)
    }

    // MARK: - 旧根整目录迁移（v49）

    public enum LegacyMigration: Equatable, Sendable {
        case moved              // 本次完成搬移（同卷原子 rename）
        case alreadyCanonical   // 规范根已存在
        case bothPresent        // 双根并存：保留旧根待人工核对，绝不合并/删除
        case noSource           // 无旧根（新装机/已清理）
        case moveFailed(String)
    }

    /// 一次性把 `Documents/MedicalNotes` 搬到 canonical 根。
    /// 失败返回 `.moveFailed`（调用方回滚迁移步骤，下次启动重试）。
    public static func migrateLegacyRoot(legacy: URL, canonical: URL,
                                         fileManager: FileManager = .default) -> LegacyMigration {
        let legacyExists = fileManager.fileExists(atPath: legacy.path)
        let canonicalExists = fileManager.fileExists(atPath: canonical.path)
        if legacyExists && canonicalExists { return .bothPresent }
        if !legacyExists { return canonicalExists ? .alreadyCanonical : .noSource }
        do {
            try fileManager.createDirectory(at: canonical.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacy, to: canonical)
            return .moved
        } catch {
            return .moveFailed(String(describing: error))
        }
    }
}
