#if os(iOS) || os(macOS)
// linux-blind: FileManager 文件协调/Files 面语义在 macOS CI 真跑；Linux 编译空单元
import Foundation
import Domain
import Protocols

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
            // 备份排除是尽力而为：某些容器/文件保护状态下 setResourceValues 会
            // 抛错，但副本已写到用户面，不能因此报「副本未生成」。
            try? Self.excludeFromBackup(directoryURL)   // try?-ok: 备份排除失败不影响副本可用
        } catch {
            throw MirrorError.writeFailed(String(describing: error))
        }
        // 去重基准=同一目录已用显示名（按目录取，覆盖无会话的「直接导入」月桶；
        // 旧实现用 conversationID ?? UUID() 查账本，无会话时恒空集，同名文件
        // 会撞 relative_path UNIQUE 使导出失败）。
        let existing = await ledger.records(directoryName: directory)
        // 同文档重导（自动副本后再点「导出副本」）必须复用原名覆盖，
        // 不能把自己的旧记录算作重名，否则产生 `-2` 孤儿副本（2026-10-30）。
        // 去重比较单位是词干：displayName 含扩展名，直接比较会让同名文件
        // 逃过去重并撞 relative_path UNIQUE（2026-10-30）。
        let takenStems = Set(existing
            .filter { $0.documentID != job.documentID }
            .map {
                DocumentExportNaming.normalizeKey(
                    ($0.displayName as NSString).deletingPathExtension)
            })
        let name = DocumentExportNaming.name(job.nameRequest)
        let fileName = DocumentExportNaming.deduplicatedStem(name.stem, existing: takenStems)
        let extensionPart = name.fileName.hasSuffix(".\(name.stem)") ? "" : String(name.fileName.dropFirst(name.stem.count))
        let finalName = fileName + extensionPart
        let target = directoryURL.appendingPathComponent(finalName)
        do {
            try bytes.write(to: target, options: [.atomic, .completeFileProtection])
            try? Self.excludeFromBackup(target)   // try?-ok: 备份排除失败不影响副本可用
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

    /// 旧「Vita Liber」二级根迁移（2026-11-02 真机：App 容器已显示为
    /// 「青囊书」，会话目录应直接落 Documents 根）。幂等：
    /// - 目标已存在（冲突）→ 保留旧目录，不覆盖；
    /// - 目录搬移成功但账本更新失败 → 尽力搬回，下次启动重试；
    /// - 旧根清空后删除。
    /// 历史副本搬移不是导出语义变更，账本 directory_name/relative_path 同步改写。
    @discardableResult
    public func migrateLegacyExportRootIfNeeded() async -> Bool {
        let legacy = exportsBase.appendingPathComponent(Self.legacyExportFolderName, isDirectory: true)
        let conversationRoot = MediaRootPaths.conversationFolderName
        let conversationPrefix = conversationRoot + "/"
        let legacyPrefix = Self.legacyExportFolderName + "/"
        let directories = await ledger.directories()
        var changed = false
        for (name, conversationID) in directories {
            let desired: String
            if name.hasPrefix(legacyPrefix) {
                let leaf = String(name.dropFirst(legacyPrefix.count))
                guard !leaf.isEmpty, !leaf.contains("/") else { continue }
                desired = conversationID == nil ? leaf : conversationPrefix + leaf
            } else if conversationID != nil, !name.hasPrefix(conversationPrefix) {
                desired = conversationPrefix + name
            } else {
                continue
            }
            if await rebaseDirectory(from: name, to: desired) { changed = true }
        }
        // 无账本行的孤儿目录（导出写盘成功但记账失败）：wrapper 是 App 专用树，
        // 目标不冲突时一并搬到 conversation/ 或根（直接导入月桶），避免旧层残留。
        let known = Set(directories.map(\.name))
        let diskEntries = (try? fileManager.contentsOfDirectory(   // try?-ok: 枚举失败按无孤儿
            at: legacy, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for entry in diskEntries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }   // try?-ok: 资源读取失败跳过
            let name = entry.lastPathComponent
            guard !known.contains("\(legacyPrefix)\(name)") else { continue }
            let isDirectImport = name.hasPrefix(DocumentExportNaming.directImportPrefix)
            let targetName = isDirectImport ? name : conversationPrefix + name
            let target = exportsBase.appendingPathComponent(targetName, isDirectory: true)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            do {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try fileManager.moveItem(at: entry, to: target)
                changed = true
            } catch { continue }
        }
        if let remaining = try? fileManager.contentsOfDirectory(atPath: legacy.path), remaining.isEmpty {   // try?-ok: 读取失败保留旧根
            try? fileManager.removeItem(at: legacy)   // try?-ok: 空旧根删除尽力而为
        }
        return changed
    }

    /// 单目录 rebase：旧在新不在→搬+改账本；旧不在新在→校验后补账；
    /// 新旧同在/皆无→跳过（绝不覆盖/认领用户目录）。返回是否改了账本/文件。
    private func rebaseDirectory(from old: String, to new: String) async -> Bool {
        guard old != new else { return false }
        let oldURL = exportsBase.appendingPathComponent(old, isDirectory: true)
        let newURL = exportsBase.appendingPathComponent(new, isDirectory: true)
        let oldExists = fileManager.fileExists(atPath: oldURL.path)
        let newExists = fileManager.fileExists(atPath: newURL.path)
        if oldExists && !newExists {
            do {
                try fileManager.createDirectory(at: newURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try fileManager.moveItem(at: oldURL, to: newURL)
            } catch { return false }
            do {
                try await ledger.relocateDirectory(from: old, to: new)
                return true
            } catch {
                try? fileManager.moveItem(at: newURL, to: oldURL)   // try?-ok: 回滚尽力而为，下次启动重试
                return false
            }
        }
        if !oldExists && newExists {
            // 上次搬移后账本未改（崩溃/回滚失败）：只有账本登记的每个文件
            // 都能在新目录找到，才认领新目录，绝不吞用户自建目录。
            let records = await ledger.records(directoryName: old)
            let verified = !records.isEmpty && records.allSatisfy {
                fileManager.fileExists(atPath: newURL.appendingPathComponent($0.displayName).path)
            }
            guard verified else { return false }
            do {
                try await ledger.relocateDirectory(from: old, to: new)
                return true
            } catch { return false }
        }
        return false
    }

    public static let legacyExportFolderName = "Vita Liber"

    /// 该用户面目录是否仍存在（迁移/冻结目录复用判定用）。
    public func hasDirectory(named name: String) -> Bool {
        fileManager.fileExists(
            atPath: exportsBase.appendingPathComponent(name, isDirectory: true).path)
    }

    /// 会话目录追加调试日志（2026-11-03 调参批）。
    /// 只写已存在的导出会话目录；不建账本行、不触碰 canonical；敏感件由
    /// 调用方拦截。`.completeFileProtection` + 排除备份。
    public func appendDebugLog(documentID: UUID, fileName: String, contents: String) async {
        // 开关可能在导入收尾后才被关闭；写盘前复查，防「关闭后仍新增」。
        guard OCRShadowDiagnostics.isEnabled,
              let record = await ledger.record(documentID: documentID),
              record.state == "active",
              !record.directoryName.isEmpty,
              let data = contents.data(using: .utf8) else { return }
        let directory = exportsBase.appendingPathComponent(record.directoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let target = directory.appendingPathComponent(fileName)
        do {
            try data.write(to: target, options: [.atomic, .completeFileProtection])
            try? Self.excludeFromBackup(target)   // try?-ok: 调试日志排除备份失败不影响可读
            pruneDebugLogs(in: directory, keeping: 10)
        } catch {
            // 诊断日志是尽力而为，不影响 OCR/导入主链路。
        }
    }

    /// 单条副本删除（2026-10-28 业主：记录转敏感时副本必须离开用户面）。
    /// 只删副本文件与账本行（置 removed），绝不触碰 canonical。
    /// 2026-11-03：同时清理同目录 OCR 调参日志（含识别原文/字段值），
    /// 防止「转敏感只删副本、日志仍留在 Files」。
    public func removeCopy(documentID: UUID) async {
        guard let record = await ledger.record(documentID: documentID) else { return }
        // 先置 removed 再删文件/日志：晚到的 appendDebugLog 见到 removed 即跳过；
        // 若 append 在置位前启动，随后的 removeDebugLogs 会清掉它。
        try? await ledger.setState(documentID: documentID, state: "removed")   // try?-ok: tombstone 尽力而为
        let url = exportsBase.appendingPathComponent(record.relativePath)
        try? fileManager.removeItem(at: url)   // try?-ok: 副本删除尽力而为
        if !record.directoryName.isEmpty {
            removeDebugLogs(in: exportsBase.appendingPathComponent(record.directoryName,
                                                                   isDirectory: true))
        }
    }

    /// 只保留最近 `keeping` 份 `ocr-debug-*.jsonl`，防日志无限增长。
    private func pruneDebugLogs(in directory: URL, keeping: Int) {
        guard keeping > 0 else { return }
        let entries = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] // try?-ok: 清理尽力而为
        let logs = entries.filter { $0.hasPrefix("ocr-debug-") && $0.hasSuffix(".jsonl") }
            .sorted()
        guard logs.count > keeping else { return }
        for entry in logs.prefix(logs.count - keeping) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(entry)) // try?-ok: 清理尽力而为
        }
    }

    private func removeDebugLogs(in directory: URL) {
        let entries = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] // try?-ok: 清理尽力而为
        for entry in entries where entry.hasPrefix("ocr-debug-") && entry.hasSuffix(".jsonl") {
            try? fileManager.removeItem(at: directory.appendingPathComponent(entry)) // try?-ok: 清理尽力而为
        }
    }

    /// 会话目录内识别调试采集（2026-11-04 业主：多模型识别文本后处理调参数据）。
    /// 写入 `<会话目录>/recognition-debug/<采集名>.json`——**一次采集一个文件、只存文本**
    /// （业主 2026-11-04 第二批：调试目录不存录音/图片）。与 `appendDebugLog` 同一开关、
    /// 同一保护（写前复查开关、`.completeFileProtection`、排除备份）。会话目录不存在时
    /// 按需创建（语音采集没有导出副本）。写入后清除旧布局采集目录（曾含录音/原件），
    /// 并只保留最近 `RecognitionDebugCapture.retainedCapturesPerConversation` 份。
    @discardableResult
    public func writeRecognitionDebug(directoryName: String, fileName: String, data: Data) -> Bool {
        guard OCRShadowDiagnostics.isEnabled,
              !directoryName.isEmpty, !directoryName.hasPrefix("/"), !directoryName.contains(".."),
              RecognitionDebugCapture.isCaptureFileName(fileName) else { return false }
        let debugRoot = exportsBase.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(RecognitionDebugCapture.folderName, isDirectory: true)
        let target = debugRoot.appendingPathComponent(fileName)
        do {
            try fileManager.createDirectory(at: debugRoot, withIntermediateDirectories: true)
            try data.write(to: target, options: [.atomic, .completeFileProtection])
        } catch {
            return false
        }
        try? Self.excludeFromBackup(target)   // try?-ok: 调试文件排除备份失败不影响可读
        let names = directoryChildren(of: debugRoot).map(\.lastPathComponent)
        for stale in RecognitionDebugCapture.capturesToPrune(names) {
            try? fileManager.removeItem(at: debugRoot.appendingPathComponent(stale))   // try?-ok: 裁剪尽力而为
        }
        return true
    }

    /// 按会话短 ID 找磁盘上已存在的会话目录（`conversation/*-<id6>[-n]`），
    /// 供无副本的语音采集复用同一会话目录，避免重启后另建一份。
    public func existingConversationDirectory(conversationID: UUID) -> String? {
        let id6 = String(conversationID.uuidString.lowercased().prefix(6))
        let root = exportsBase.appendingPathComponent(MediaRootPaths.conversationFolderName, isDirectory: true)
        let pattern = try? NSRegularExpression(pattern: #"-\#(id6)(?:-\d+)?$"#)   // try?-ok: 静态模式
        let names = directoryChildren(of: root).map(\.lastPathComponent).sorted()
        let match = names.first { name in
            let lower = name.lowercased()
            return pattern?.firstMatch(in: lower, range: NSRange(lower.startIndex..<lower.endIndex, in: lower)) != nil
        }
        return match.map { MediaRootPaths.conversationFolderName + "/" + $0 }
    }

    /// 关闭诊断开关时清除全部会话目录中的 OCR 调试日志（含旧日志），
    /// 避免「关闭后不再新增」但旧 PHI 仍留在 Files 的歧义。
    /// 2026-11-04：同时清除各会话目录下的 `recognition-debug/` 采集（含旧布局目录）。
    public func removeAllDebugLogs() {
        for root in [exportsBase.appendingPathComponent(MediaRootPaths.conversationFolderName, isDirectory: true),
                     exportsBase.appendingPathComponent(Self.legacyExportFolderName, isDirectory: true)] {
            for conversation in directoryChildren(of: root) {
                let debug = conversation.appendingPathComponent(RecognitionDebugCapture.folderName,
                                                                isDirectory: true)
                if fileManager.fileExists(atPath: debug.path) {
                    try? fileManager.removeItem(at: debug)   // try?-ok: 清理尽力而为
                }
            }
        }
        // 递归：日志在 exportsBase/<会话目录> 或旧层 exportsBase/Vita Liber/<会话目录>，
        // 只扫一层会把嵌套目录里的 PHI 日志留在 Files。
        guard let enumerator = fileManager.enumerator(   // try?-ok: 枚举失败跳过
            at: exportsBase, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("ocr-debug-"), name.hasSuffix(".jsonl") else { continue }
            try? fileManager.removeItem(at: url)   // try?-ok: 清理尽力而为
        }
    }

    /// 会话删除前快照（E2）：会话行删除后账本外键 `ON DELETE SET NULL`，
    /// 再按 conversationID 查已查不到——删除方必须先取快照，删行后再调用
    /// `removeCopies(records:)`（2026-10-30 登记项收口：此前副本留在 Files）。
    public func copies(conversationID: UUID) async -> [DocumentExportStore.Record] {
        await ledger.records(conversationID: conversationID)
    }

    /// 会话删除联动（E2：默认移除导出、可取消）：删除会话目录 + 置 tombstone。
    public func removeCopies(conversationID: UUID) async {
        await removeCopies(records: await ledger.records(conversationID: conversationID))
    }

    /// 按删除前快照清理（会话行已删时唯一可用入口）。
    /// 只删副本树与账本行（置 removed），绝不触碰 canonical。
    public func removeCopies(records: [DocumentExportStore.Record]) async {
        let directories = Set(records.map(\.directoryName))
        for directory in directories where !directory.isEmpty {
            let url = exportsBase.appendingPathComponent(directory, isDirectory: true)
            try? fileManager.removeItem(at: url)   // try?-ok: 副本删除尽力而为；canonical 不受影响
        }
        for record in records {
            try? await ledger.setState(documentID: record.documentID, state: "removed")   // try?-ok: tombstone 尽力而为
        }
    }

    /// 删除会话时兜底清理目录（2026-11-03 真机：删历史对话后 Files 目录仍在）。
    /// 账本可能没有行（自动导出写盘后记账失败、tombstone、删除与导出竞态），
    /// 仅凭 `copies(conversationID:)` 删不掉。会话目录名以 `-<会话短ID>` 结尾，
    /// 只在 App 专用的 `conversation/`、旧 `Vita Liber/` 根内按后缀匹配；
    /// 根目录仅接受严格会话名格式，避免误删用户自建目录。canonical 不受影响。
    public func removeConversationArtifacts(conversationID: UUID) async {
        // 先按账本精确删：超长标题目录名在 240B 截断后会丢 `-id6` 后缀，
        // 后缀/扁平正则都扫不到（finding 9），但账本仍记着完整目录名。
        let ownedNames = Set(await ledger.records(conversationID: conversationID).map(\.directoryName))
        for name in ownedNames {
            let url = exportsBase.appendingPathComponent(name, isDirectory: true)
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }   // try?-ok: 非目录跳过
            await removeArtifacts(at: url, ledgerDirectoryName: name, conversationID: conversationID)
        }
        let id6 = String(conversationID.uuidString.lowercased().prefix(6))
        // 同名目录消解会在短 ID 后再加 `-2`/`-3`（DocumentExportNaming），
        // 后缀匹配必须容许该段，否则碰撞过的会话目录会留下。
        let suffixPattern = try? NSRegularExpression(   // try?-ok: 静态模式
            pattern: #"-\#(id6)(?:-\d+)?$"#)
        func matchesSuffix(_ name: String) -> Bool {
            let lower = name.lowercased()
            let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
            return suffixPattern?.firstMatch(in: lower, range: range) != nil
        }
        // 删除目录 + 账本墓碑：账本里可能存在 conversation_id 为 NULL 的重导行
        // （会话内导入后在库页再次导出）——它不在删除前快照里，不墓碑就会在
        // 下次 reconcile 被误报「副本缺失」。短 ID 碰撞（24-bit）时若目录
        // 账本归属另一会话，绝不删除。
        let conversationRoot = exportsBase.appendingPathComponent(
            MediaRootPaths.conversationFolderName, isDirectory: true)
        let legacyRoot = exportsBase.appendingPathComponent(
            Self.legacyExportFolderName, isDirectory: true)
        for root in [conversationRoot, legacyRoot] where fileManager.fileExists(atPath: root.path) {
            let prefix = root.lastPathComponent + "/"
            for entry in (try? fileManager.contentsOfDirectory(   // try?-ok: 枚举失败跳过
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? [] {
                guard matchesSuffix(entry.lastPathComponent),
                      (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true   // try?-ok: 非目录跳过
                else { continue }
                await removeArtifacts(at: entry,
                                      ledgerDirectoryName: prefix + entry.lastPathComponent,
                                      conversationID: conversationID)
            }
        }
        // 11-02 扁平会话目录（迁移前删除的会话）：严格 `yyyyMMdd-HHmm-…-id6[-n]`。
        let flatPattern = try? NSRegularExpression(   // try?-ok: 静态模式
            pattern: #"^\d{8}-\d{4}-.+-\#(id6)(?:-\d+)?$"#)
        for entry in (try? fileManager.contentsOfDirectory(   // try?-ok: 枚举失败跳过
            at: exportsBase, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? [] {
            let name = entry.lastPathComponent
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard flatPattern?.firstMatch(in: name, range: range) != nil,
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true   // try?-ok: 非目录跳过
            else { continue }
            await removeArtifacts(at: entry, ledgerDirectoryName: name,
                                  conversationID: conversationID)
        }
    }

    /// 删除一个已确认属于本会话的目录，并把其账本行置 removed。
    /// 目录短 ID 的账本归属若是另一会话（24-bit 碰撞），跳过不删。
    private func removeArtifacts(at url: URL, ledgerDirectoryName: String,
                                 conversationID: UUID) async {
        let records = await ledger.records(directoryName: ledgerDirectoryName)
        if records.contains(where: {
            $0.conversationID != nil && $0.conversationID != conversationID
        }) { return }
        try? fileManager.removeItem(at: url)   // try?-ok: 尽力而为
        for record in records {
            try? await ledger.setState(documentID: record.documentID, state: "removed", now: Date())   // try?-ok: tombstone 尽力而为
        }
    }

    /// 清空全部数据：擦账本 + 删除全部会话目录副本（canonical 由各自链路负责）。
    /// 除账本目录外，还清扫 App 自有命名空间里的孤儿目录（导出写盘成功但记账
    /// 失败/已墓碑），否则「清空全部数据」后 Files 仍可见医疗副本（finding 19）。
    public func wipeAllCopies() async {
        // 账本内目录（含已墓碑行）：目录名是 App 生成的完整相对路径。
        for name in Set(await ledger.directories().map(\.name)) {
            removeDirectoryIfPresent(named: name)
        }
        // 会话根与旧「Vita Liber」根：App 专用树，整层子目录都属副本。
        let conversationRoot = exportsBase.appendingPathComponent(
            MediaRootPaths.conversationFolderName, isDirectory: true)
        let legacyRoot = exportsBase.appendingPathComponent(
            Self.legacyExportFolderName, isDirectory: true)
        for root in [conversationRoot, legacyRoot] where fileManager.fileExists(atPath: root.path) {
            for entry in directoryChildren(of: root) {
                try? fileManager.removeItem(at: entry)   // try?-ok: 尽力而为
            }
        }
        // Documents 根的 App 命名目录：`直接导入-YYYY-MM` 月桶与扁平会话目录。
        let flatPattern = try? NSRegularExpression(   // try?-ok: 静态模式
            pattern: #"^\d{8}-\d{4}-.+-(?:[0-9a-f]{6})(?:-\d+)?$"#)
        for entry in directoryChildren(of: exportsBase) {
            let name = entry.lastPathComponent
            let isDirectImport = name.hasPrefix(DocumentExportNaming.directImportPrefix)
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            let isFlat = flatPattern?.firstMatch(in: name, range: range) != nil
            guard isDirectImport || isFlat else { continue }
            try? fileManager.removeItem(at: entry)   // try?-ok: 尽力而为
        }
        try? await ledger.wipe()   // try?-ok: 尽力而为
    }

    private func removeDirectoryIfPresent(named name: String) {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("..") else { return }
        let url = exportsBase.appendingPathComponent(name, isDirectory: true)
        try? fileManager.removeItem(at: url)   // try?-ok: 尽力而为
    }

    private func directoryChildren(of root: URL) -> [URL] {
        ((try? fileManager.contentsOfDirectory(   // try?-ok: 枚举失败跳过
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true   // try?-ok: 非目录跳过
        }
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
    }
}
#endif
