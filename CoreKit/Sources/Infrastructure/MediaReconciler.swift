#if os(iOS) || os(macOS)
// linux-blind: （平台守卫：GRDB 仅 iOS/macOS 链接（Package.swift ERR#8 纪律），Linux 编译空单元，改动须经 macOS CI 验证）
import Foundation
import GRDB
import Domain

/// 媒体生命周期执行者（discussions/2026-10-16-local-storage-layout-council.md §8 切片 13）：
/// 对账判定全部走 Domain 纯规则（MediaLifecycleRules），本 actor 只做 IO 编排——
/// 引用集 = DB 有效集**成员判定**（幂等可重跑）；600s 宽限；keep-on-doubt（宁留勿删 BR-002）。
/// 触发面：启动 / 恢复完成 / 成员删除后 / 清空后；与 F8 SensitiveAssetStore.reconcileUnreferenced
/// 分链（本 actor 只管文档原件 sha 形态文件；assetId 照片形态归 F8）。
public actor MediaReconciler {

    private let mediaBase: URL
    private let writer: any DatabaseWriter
    private let fileManager: FileManager

    public init(mediaBase: URL, writer: any DatabaseWriter, fileManager: FileManager = .default) {
        self.mediaBase = mediaBase
        self.writer = writer
        self.fileManager = fileManager
    }

    public struct Report: Sendable, Equatable {
        public var deletedOriginals: Int
        public var deletedSensitive: Int
        public init(deletedOriginals: Int = 0, deletedSensitive: Int = 0) {
            self.deletedOriginals = deletedOriginals
            self.deletedSensitive = deletedSensitive
        }
    }

    // MARK: - 引用集（DB 有效集）

    /// 全库引用集：①全部 original_sha256（含软删成员行——宁留勿删）∪ ②处理版根 sha 白名单。
    private func referencedSets() async throws -> (originals: Set<String>, sensitiveByMember: [UUID: Set<String>]) {
        let rows = try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT patient_id, is_sensitive, original_sha256, sha256 FROM document_file
                """)
        }
        var originals = Set<String>()
        var sensitiveByMember: [UUID: Set<String>] = [:]
        var tokens: [String] = []
        for row in rows {
            tokens.append((row["sha256"] as String?) ?? "")
            guard let sha = (row["original_sha256"] as String?),
                  MediaDestinationRules.isLowercaseHex64(sha) else { continue }
            originals.insert(sha)
            if (row["is_sensitive"] as Int?) == 1,
               let member = (row["patient_id"] as String?).flatMap(UUID.init(uuidString:)) {
                sensitiveByMember[member, default: []].insert(sha)
            }
        }
        originals.formUnion(MediaLifecycleRules.processedRootSHAs(from: tokens))
        return (originals, sensitiveByMember)
    }

    // MARK: - 对账

    /// 孤儿对账（幂等）：扫描 originals/ 与 sensitive/ 两树，规范 sha 形态文件按判定删除。
    /// 仅删「无引用 + 超宽限」；旧布局/未知形态一律保留。
    @discardableResult
    public func reconcile(now: Date = Date(), grace: TimeInterval = 600) async throws -> Report {
        let sets = try await referencedSets()
        var report = Report()
        report.deletedOriginals = try await reconcileOriginals(sets.originals, now: now, grace: grace)
        report.deletedSensitive = try await reconcileSensitive(sets.sensitiveByMember, now: now, grace: grace)
        return report
    }

    private func reconcileOriginals(_ referenced: Set<String>, now: Date, grace: TimeInterval) async throws -> Int {
        let root = mediaBase.appendingPathComponent("originals", isDirectory: true)
        return try await reconcileTree(root: root, referenced: referenced, now: now, grace: grace) { relativePath, mtime in
            MediaLifecycleRules.verdictOriginals(relativePath: relativePath, mtime: mtime,
                                                 referencedSHAs: referenced,
                                                 now: now.timeIntervalSince1970, grace: grace)
        }
    }

    private func reconcileSensitive(_ byMember: [UUID: Set<String>], now: Date, grace: TimeInterval) async throws -> Int {
        let root = mediaBase.appendingPathComponent("sensitive", isDirectory: true)
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        var deleted = 0
        let memberDirs = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] // try?-ok: 目录不可读=按「无可扫」处理，宁留勿删
        for memberName in memberDirs {
            guard let memberId = UUID(uuidString: memberName) else { continue }
            let memberDir = root.appendingPathComponent(memberName)
            let files = (try? fileManager.contentsOfDirectory(atPath: memberDir.path)) ?? [] // try?-ok: 同上
            let referenced = byMember[memberId] ?? []
            for name in files {
                guard let mtime = try? fileManager.attributesOfItem(
                    atPath: memberDir.appendingPathComponent(name).path)[.modificationDate] as? Date // try?-ok: 属性不可读=宁留勿删
                else { continue }
                let verdict = MediaLifecycleRules.verdictSensitive(fileName: name, mtime: mtime.timeIntervalSince1970,
                                                                   referencedSHAs: referenced,
                                                                   now: now.timeIntervalSince1970, grace: grace)
                guard verdict.delete else { continue }
                try? fileManager.removeItem(at: memberDir.appendingPathComponent(name)) // try?-ok: 删除失败下次对账重试，宁留勿删
                deleted += 1
            }
        }
        return deleted
    }

    private func reconcileTree(root: URL, referenced: Set<String>, now: Date,
                               grace: TimeInterval,
                               verdict: (String, TimeInterval) -> MediaLifecycleRules.FileVerdict) async throws -> Int {
        guard fileManager.fileExists(atPath: root.path) else { return 0 }
        var deleted = 0
        let firstLevel = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] // try?-ok: 目录不可读=按「无可扫」处理，宁留勿删
        for first in firstLevel {
            let firstURL = root.appendingPathComponent(first)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: firstURL.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                let mtime = ((try? fileManager.attributesOfItem(atPath: firstURL.path)[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 // try?-ok: 属性不可读=按远古时间计（超宽限仍可删，仅引用集是防线）
                guard verdict(first, mtime).delete else { continue }
                try? fileManager.removeItem(at: firstURL) // try?-ok: 删除失败下次对账重试
                deleted += 1
                continue
            }
            let files = (try? fileManager.contentsOfDirectory(atPath: firstURL.path)) ?? [] // try?-ok: 同上
            for name in files {
                let fileURL = firstURL.appendingPathComponent(name)
                let mtime = ((try? fileManager.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 // try?-ok: 同上
                let relative = "\(first)/\(name)"
                guard verdict(relative, mtime).delete else { continue }
                try? fileManager.removeItem(at: fileURL) // try?-ok: 删除失败下次对账重试
                deleted += 1
            }
        }
        return deleted
    }

    // MARK: - 懒回填（只写列不动文件，幂等可重入）

    /// original_sha256 NULL 的行：经 MediaPathResolver 找文件 → 现场哈希 → 写列。
    /// 文件不可达的行跳过（下次启动重试）；返回回填行数。
    @discardableResult
    public func backfillOriginalSHA() async throws -> Int {
        let rows = try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, is_sensitive, meta_json FROM document_file WHERE original_sha256 IS NULL")
        }
        var updated = 0
        for row in rows {
            guard let id = (row["id"] as String?).flatMap(UUID.init(uuidString:)) else { continue }
            let meta = ((row["meta_json"] as String?).flatMap { json -> [String: Any]? in
                try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] // try?-ok: meta 损坏=无路径候选，跳过该行
            }) ?? [:]
            let candidates = MediaPathResolver.candidates(storedPath: meta["original_path"] as? String,
                                                          originalSha256: nil)
            var data: Data?
            for candidate in candidates {
                let url = candidate.hasPrefix("/") ? URL(fileURLWithPath: candidate) : mediaBase.appendingPathComponent(candidate)
                if let loaded = try? Data(contentsOf: url) { data = loaded; break } // try?-ok: 单候选不可读=试下一候选
            }
            guard let data else { continue }
            let sha = CryptoKitContentHasher().sha256Hex(data)
            try await writer.write { db in
                try db.execute(sql: "UPDATE document_file SET original_sha256 = ? WHERE id = ?",
                               arguments: [sha, id.uuidString])
            }
            updated += 1
        }
        return updated
    }

    // MARK: - 显式删除路径（清空全部 / 成员删除）

    /// 清空全部（FR14.3）：originals/ 与 sensitive/ 两根全删（DB 行由 persistorReset 负责；
    /// 文件先删、行后删——宁孤儿勿悬空）。F8 内存缓存由调用方 wipeMediaFiles 负责。
    public func wipeAllMedia() async {
        for sub in ["originals", "sensitive"] {
            try? fileManager.removeItem(at: mediaBase.appendingPathComponent(sub)) // try?-ok: 目录不存在=已清；删除失败下次清空重试
        }
    }

    /// 成员删除：该成员敏感目录整删（敏感字节不可共享，删除即不可恢复 BR-007）；
    /// 非敏感 CAS 字节可能被其他成员共享——不动文件，行删除后由 reconcile 成员判定回收。
    public func wipeMember(_ memberId: UUID) async {
        try? fileManager.removeItem(at: mediaBase.appendingPathComponent("sensitive/\(memberId.uuidString)")) // try?-ok: 目录不存在=已清
    }
}
#endif
