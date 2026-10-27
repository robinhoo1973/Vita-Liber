#if os(iOS) || os(macOS)
// linux-blind: FileManager 文件协调/Files 面语义在 macOS CI 真跑；Linux 编译空单元
import Foundation
import Domain

/// 导出副本镜像（2026-10-27 存储边界委员会 D1/D7/D8/E1/E2）。
///
/// 职责边界：
/// - **写副本**：把 canonical 原件字节复制到 `Documents/<会话目录>/<显示名>`，
///   记账 `document_user_export`。副本是独立文件（BR-002：权威原件在 App，
///   副本可被用户在文件 App 改名/删除/移动——App 不回读、不自动重建）。
/// - **对账**：核对 active 行——缺文件/尺寸或时间漂移 → `missing` tombstone
///   （用户改名/移走无法可靠跟随，交由 UI 提供 [重新导出]/[移除跟踪]）；
///   **绝不回删 canonical**。
/// - **敏感策略（E1）**：自动镜像只有非敏感件；敏感件仅当调用方显式
///   `allowSensitive: true`（逐项同意后的显式导出）才允许——绝无会话级常开。
/// - 备份：会话目录与副本置 `isExcludedFromBackup`（副本可重建，ADR-034 矩阵）；
///   保护：副本 `.completeFileProtection`。
public actor DocumentExportMirror {
    public struct ExportJob: Sendable {
        public var documentID: UUID
        public var conversationID: UUID?
        /// 已冻结的会话目录名（Domain `DocumentExportNaming.directoryName` 产出）。
        public var directoryName: String
        /// 命名请求（App 层组装：已确认字段/标题/日期/ID/扩展名）。
        public var nameRequest: DocumentExportNaming.Request
        /// meta 原件的双形态路径（相对=originalsDir 锚；绝对=旧行）。
        public var sourcePath: String
        public var isSensitive: Bool

        public init(documentID: UUID, conversationID: UUID?, directoryName: String,
                    nameRequest: DocumentExportNaming.Request,
                    sourcePath: String, isSensitive: Bool) {
            self.documentID = documentID
            self.conversationID = conversationID
            self.directoryName = directoryName
            self.nameRequest = nameRequest
            self.sourcePath = sourcePath
            self.isSensitive = isSensitive
        }
    }

    public enum MirrorError: Error, Equatable {
        case sensitiveRequiresExplicitOptIn
        case sourceUnreadable(String)
        case writeFailed(String)
    }

    public struct Outcome: Sendable, Equatable {
        public var relativePath: String
        public var displayName: String
        public var created: Bool
    }

    private let ledger: DocumentExportStore
    private let exportsBase: URL      // Documents 基（Files 可见树根）
    private let originalsDir: URL     // canonical MedicalNotes 根（meta 相对锚）
    private let fileManager: FileManager

    public init(ledger: DocumentExportStore, exportsBase: URL, originalsDir: URL,
                fileManager: FileManager = .default) {
        self.ledger = ledger
        self.exportsBase = exportsBase
        self.originalsDir = originalsDir
        self.fileManager = fileManager
    }

    /// 写一份副本并记账（幂等：重复导出同文档覆盖同名副本）。
    public func export(_ job: ExportJob, allowSensitive: Bool,
                       now: Date = Date()) async throws -> Outcome {
        if job.isSensitive && !allowSensitive {
            throw MirrorError.sensitiveRequiresExplicitOptIn
        }
        guard let source = MediaRootPaths.resolve(path: job.sourcePath, mediaBase: originalsDir) else {
            throw MirrorError.sourceUnreadable(job.sourcePath)
        }
        guard let bytes = try? Data(contentsOf: source), !bytes.isEmpty else {   // try?-ok: 读失败归 sourceUnreadable 强类型错误
            throw MirrorError.sourceUnreadable(source.path)
        }
        let directory = job.directoryName
        let directoryURL = exportsBase.appendingPathComponent(directory, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Self.excludeFromBackup(directoryURL)
        } catch {
            throw MirrorError.writeFailed(String(describing: error))
        }
        // 去重基准=同一目录已用显示名（按目录取，覆盖无会话的「直接导入」月桶；
        // 旧实现用 conversationID ?? UUID() 查账本，无会话时恒空集，同名文件
        // 会撞 relative_path UNIQUE 使导出失败）。
        let existing = await ledger.records(directoryName: directory)
        let takenStems = Set(existing.map { DocumentExportNaming.normalizeKey($0.displayName) })
        let name = DocumentExportNaming.name(job.nameRequest)
        let fileName = DocumentExportNaming.deduplicatedStem(name.stem, existing: takenStems)
        let extensionPart = name.fileName.hasSuffix(".\(name.stem)") ? "" : String(name.fileName.dropFirst(name.stem.count))
        let finalName = fileName + extensionPart
        let target = directoryURL.appendingPathComponent(finalName)
        do {
            try bytes.write(to: target, options: [.atomic, .completeFileProtection])
            try Self.excludeFromBackup(target)
        } catch {
            throw MirrorError.writeFailed(String(describing: error))
        }
        let attributes = try? fileManager.attributesOfItem(atPath: target.path)   // try?-ok: 属性读取失败不阻断记账
        let size = (attributes?[.size] as? NSNumber)?.int64Value
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
        let relativePath = directory + "/" + finalName
        let record = DocumentExportStore.Record(
            documentID: job.documentID,
            conversationID: job.conversationID,
            directoryName: directory,
            displayName: finalName,
            relativePath: relativePath,
            nameSource: name.source.rawValue,
            state: "active",
            sizeBytes: size,
            mtime: mtime,
            createdAt: now,
            updatedAt: now)
        try await ledger.upsert(record)
        return Outcome(relativePath: relativePath, displayName: finalName, created: true)
    }

    /// 对账（启动/回前台）：active 行核对文件存在性与尺寸漂移。
    /// 返回本次新置 missing 的数量（UI 横幅计数）。
    @discardableResult
    public func reconcile(now: Date = Date()) async -> Int {
        let records = await ledger.activeRecords()
        var drifted = 0
        for record in records {
            let url = exportsBase.appendingPathComponent(record.relativePath)
            guard fileManager.fileExists(atPath: url.path) else {
                try? await ledger.setState(documentID: record.documentID, state: "missing", now: now)   // try?-ok: 对账尽力而为
                drifted += 1
                continue
            }
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)   // try?-ok: 属性不可读按不漂移
            if let size = (attributes?[.size] as? NSNumber)?.int64Value,
               let recorded = record.sizeBytes, size != recorded {
                try? await ledger.setState(documentID: record.documentID, state: "missing", sizeBytes: size, now: now)   // try?-ok: 对账尽力而为
                drifted += 1
            }
        }
        return drifted
    }

    /// 单条副本删除（2026-10-28 业主：记录转敏感时副本必须离开用户面）。
    /// 只删副本文件与账本行（置 removed），绝不触碰 canonical。
    public func removeCopy(documentID: UUID) async {
        guard let record = await ledger.record(documentID: documentID) else { return }
        let url = exportsBase.appendingPathComponent(record.relativePath)
        try? fileManager.removeItem(at: url)   // try?-ok: 副本删除尽力而为
        try? await ledger.setState(documentID: documentID, state: "removed")   // try?-ok: tombstone 尽力而为
    }

    /// 会话删除联动（E2：默认移除导出、可取消）：删除跟踪行 + 会话目录。
    public func removeCopies(conversationID: UUID) async {
        let records = await ledger.records(conversationID: conversationID)
        let directories = Set(records.map(\.directoryName))
        for directory in directories {
            let url = exportsBase.appendingPathComponent(directory, isDirectory: true)
            try? fileManager.removeItem(at: url)   // try?-ok: 副本删除尽力而为；canonical 不受影响
        }
        for record in records {
            try? await ledger.setState(documentID: record.documentID, state: "removed")   // try?-ok: tombstone 尽力而为
        }
    }

    /// 清空全部数据：擦账本 + 删除全部会话目录副本（canonical 由各自链路负责）。
    public func wipeAllCopies() async {
        let records = await ledger.activeRecords()
        let directories = Set(records.map(\.directoryName))
        for directory in directories {
            let url = exportsBase.appendingPathComponent(directory, isDirectory: true)
            try? fileManager.removeItem(at: url)   // try?-ok: 尽力而为
        }
        try? await ledger.wipe()   // try?-ok: 尽力而为
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
    }
}
#endif
