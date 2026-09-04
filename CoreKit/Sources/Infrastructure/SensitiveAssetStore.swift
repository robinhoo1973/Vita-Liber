#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Domain
import Protocols
#if os(iOS)
import UIKit
#endif

/// §5.10 敏感媒体资产仓（actor）：目录隔离 + 文件保护 + blur 双产物 + asset 表登记。
///
/// - 目录：`<Documents>/MedicalNotes/sensitive/{memberId}/`（测试/预览可注入临时目录），
///   文件保护 `.complete`；
/// - 模糊缩略图：Domain `ThumbnailSpec` + 注入的 `ImageCompressing`（组合根装配，
///   测试可注入 StubImageCompressor）；blur 文件名由 assetId 确定性派生
///   （`{assetId}.blur.jpg`），读取走路径直取 + NSCache，不查表（无 LIKE 全扫）；
/// - **资产行 id = assetId（photo 行）**：observation.media_asset_ids 可直接 join
///   asset.id（审计/删除/原图查看的锚点）；blur 行 id 亦由 assetId 派生
///   （`{assetId}.blur`），blur↔photo 可确定性关联（parent_id 列归 §11 清偿表）；
/// - 原始图与缩略图同事务内先写文件后登记资产行；失败路径清理已写文件（不留半成品）；
/// - 压缩为纯 CPU 密集，`Task.detached` 跳出 actor 执行器，不阻塞列表读取。
public actor SensitiveAssetStore: SensitiveAssetStoring {
    private let writer: any DatabaseWriter
    private let compressor: any ImageCompressing
    private let baseDir: URL
    /// blur 缩略图内存缓存（§5.10 内存警告响应：收到警告即清空）。
    /// 经 CacheBox 供 @Sendable 观察者闭包捕获（NSCache 无 Sendable 标注）。
    private let blurCache: CacheBox
    private var memoryWarningObserver: NSObjectProtocol?

    public init(writer: any DatabaseWriter, compressor: any ImageCompressing,
                baseDir: URL? = nil) {
        self.writer = writer
        self.compressor = compressor
        self.blurCache = CacheBox()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.baseDir = (baseDir ?? docs)
            .appendingPathComponent("MedicalNotes/sensitive", isDirectory: true)
        #if os(iOS)
        let box = blurCache
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { _ in
                box.cache.removeAllObjects()
            }
        #endif
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func savePhoto(_ data: Data, memberId: UUID) async throws -> UUID {
        let assetId = UUID()
        let dir = memberDir(memberId)
        let originalURL = dir.appendingPathComponent("\(assetId.uuidString).jpg")
        let blurURL = dir.appendingPathComponent("\(assetId.uuidString).blur.jpg")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // BR-002 不可变原图：写后即只读语义（overwrite 只在重试同 id 时发生，正常流程一次写入）
            try data.write(to: originalURL, options: [.atomic, .completeFileProtection])
            // §5.10：模糊版 = CIGaussianBlur(radius:12)，锁定 UI 永远只读 blur 版。
            // 压缩为纯 CPU 密集：detached 跳出 actor 执行器，保存期间不阻塞列表读取。
            let blurSpec = ThumbnailSpec(maxDimension: 320, blurRadius: 12, quality: 0.6)
            let blur = try await Task.detached(priority: .userInitiated) {
                try await compressor.generateThumbnail(data, spec: blurSpec)
            }.value
            try blur.write(to: blurURL, options: [.atomic, .completeFileProtection])
            let rel = "MedicalNotes/sensitive/\(memberId.uuidString)/"
            let now = Date().timeIntervalSince1970
            let rows: [(id: String, kind: String, rel: String, size: Int)] = [
                (assetId.uuidString, "photo", rel + "\(assetId.uuidString).jpg", data.count),
                ("\(assetId.uuidString).blur", "blur", rel + "\(assetId.uuidString).blur.jpg", blur.count),
            ]
            try await writer.write { db in
                for row in rows {
                    try db.execute(sql: """
                        INSERT INTO asset (id, kind, relative_path, file_protection, size_bytes, created_at)
                        VALUES (?, ?, ?, 'complete', ?, ?)
                        """, arguments: [row.id, row.kind, row.rel, row.size, now])
                }
            }
            return assetId
        } catch {
            // 失败路径清理半成品（§7 显式降级：不向调用方泄漏部分写入）
            try? FileManager.default.removeItem(at: originalURL)   // try?-ok: 清理路径 best-effort，删除不存在文件与主错误相比可忽略
            try? FileManager.default.removeItem(at: blurURL)       // try?-ok: 同上
            throw error
        }
    }

    public func removePhoto(_ assetId: UUID, memberId: UUID) async {
        let dir = memberDir(memberId)
        do { try FileManager.default.removeItem(at: dir.appendingPathComponent("\(assetId.uuidString).jpg")) } catch { /* 不存在即无事 */ }
        do { try FileManager.default.removeItem(at: dir.appendingPathComponent("\(assetId.uuidString).blur.jpg")) } catch { /* 同上 */ }
        do {
            try await writer.write { db in
                try db.execute(sql: """
                    DELETE FROM asset WHERE id IN (?, ?)
                    """, arguments: [assetId.uuidString, "\(assetId.uuidString).blur"])
            }
        } catch { /* 回滚路径：DB 清理失败不阻断主错误 */ }
        blurCache.cache.removeObject(forKey: assetId.uuidString as NSString)
    }

    public func blurData(for assetId: UUID, memberId: UUID) async throws -> Data? {
        let key = assetId.uuidString as NSString
        if let cached = blurCache.cache.object(forKey: key) { return cached as Data }
        let url = memberDir(memberId).appendingPathComponent("\(assetId.uuidString).blur.jpg")
        guard let data = try? Data(contentsOf: url) else { return nil }   // try?-ok: blur 读取失败降级为「无缩略图」，不阻断列表
        blurCache.cache.setObject(data as NSData, forKey: key)
        return data
    }

    public func reconcileUnreferenced(validAssetIds: Set<String>) async {
        do {
            let orphans: [(id: String, rel: String)] = try await writer.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, relative_path FROM asset WHERE kind = 'photo'
                    """).map { row in
                    (row["id"] as String, row["relative_path"] as String)
                }
            }
            for orphan in orphans where !validAssetIds.contains(orphan.id) {
                // 按 relative_path 删文件（原图 + 派生 blur），再删两行资产
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let url = docs.appendingPathComponent(orphan.rel)
                do { try FileManager.default.removeItem(at: url) } catch { /* 不存在即无事 */ }
                let blurURL = url.deletingPathExtension().appendingPathExtension("blur.jpg")
                do { try FileManager.default.removeItem(at: blurURL) } catch { /* 同上 */ }
                do {
                    try await writer.write { db in
                        try db.execute(sql: "DELETE FROM asset WHERE id IN (?, ?)",
                                       arguments: [orphan.id, orphan.id + ".blur"])
                    }
                } catch { /* 对账路径：DB 清理失败不阻断启动 */ }
                blurCache.cache.removeObject(forKey: orphan.id as NSString)
            }
        } catch {
            // 对账失败不阻断启动：本轮留残，下轮再扫（§7 显式降级）
        }
    }

    private func memberDir(_ memberId: UUID) -> URL {
        baseDir.appendingPathComponent(memberId.uuidString, isDirectory: true)
    }
}

/// NSCache 的 Sendable 载体：观察者闭包捕获本箱而非裸 NSCache
/// （Swift 6 @Sendable 捕获纪律；NSCache 自身线程安全）。
private final class CacheBox: @unchecked Sendable {
    let cache = NSCache<NSString, NSData>()
}
#endif
