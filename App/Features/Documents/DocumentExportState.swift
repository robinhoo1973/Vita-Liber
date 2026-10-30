import Foundation
import Domain
import Infrastructure
import Perception

/// 导出副本用户面状态（2026-10-27 存储边界委员会 D1/D5/D8/E1/E2）。
///
/// App 层唯一出口：设置主开关语义、逐项显式导出、启动/前台对账、清空级联。
/// 依赖面 = DocumentStore（读行）+ DocumentExportStore（账本）+ DocumentExportMirror（写/对账）。
/// 不持有 DocumentsState（避免状态间横连）；媒体锚点由装配层注入。
@MainActor
@Perceptible
final class DocumentExportState {
    enum ExportFailure: Equatable {
        case notFound
        case sensitiveNeedsConsent
        case unreadable
        case writeFailed
    }

    private let store: DocumentStore
    private let ledger: DocumentExportStore
    private let mirror: DocumentExportMirror

    /// 对账发现的漂移数（UI 横幅计数用）。
    private(set) var driftCount = 0
    /// 在途导出（防重复点按；视图据此禁用）。
    private(set) var exportingDocumentIds: Set<UUID> = []
    /// 会话 → 已冻结目录名（D5 首次导出即冻结）。同一会话每份资料原实现
    /// 都扫一次账本取首目录；缓存后只首份查库（2026-10-30 效率批）。
    private var conversationDirectories: [UUID: String] = [:]

    init(store: DocumentStore, ledger: DocumentExportStore, mirror: DocumentExportMirror) {
        self.store = store
        self.ledger = ledger
        self.mirror = mirror
    }

    /// 逐项显式导出（菜单点击即显式选择；敏感件调用方须显式传 allowSensitive）。
    @discardableResult
    func exportCopy(documentID: UUID, conversationID: UUID?, conversationTitle: String?,
                    allowSensitive: Bool, now: Date = Date()) async -> ExportFailure? {
        guard !exportingDocumentIds.contains(documentID) else { return nil }
        exportingDocumentIds.insert(documentID)
        defer { exportingDocumentIds.remove(documentID) }
        guard let row = try? await store.fetch(id: documentID) else {   // try?-ok: 读失败按 notFound
            return .notFound
        }
        do {
            _ = try await mirror.export(try await job(for: row, conversationID: conversationID,
                                                      conversationTitle: conversationTitle, now: now),
                                        allowSensitive: allowSensitive)
            return nil
        } catch DocumentExportMirror.MirrorError.sensitiveRequiresExplicitOptIn {
            return .sensitiveNeedsConsent
        } catch DocumentExportMirror.MirrorError.sourceUnreadable {
            return .unreadable
        } catch {
            return .writeFailed
        }
    }

    /// 已导出的用户面相对路径（聊天详情「存储位置」展示；nil=本机无副本）。
    func exportedRelativePath(documentID: UUID) async -> String? {
        guard let record = await ledger.record(documentID: documentID),
              record.state == "active" else { return nil }
        return record.relativePath.isEmpty ? nil : record.relativePath
    }

    /// 启动/回前台对账（幂等；只置 tombstone，绝不回删 canonical）。
    func reconcile() async {
        driftCount = await mirror.reconcile()
    }

    /// 移除跟踪（用户对 missing 副本的显式处理）：只删账本行，不碰 canonical。
    func removeTracking(documentID: UUID) async {
        try? await ledger.setState(documentID: documentID, state: "removed")   // try?-ok: 尽力而为
        if driftCount > 0 { driftCount -= 1 }
    }

    /// 记录当前敏感态（聊天敏感开关的初值；读失败按未知）。
    /// 注（run 40596667593 修复）：`try?` 对「返回 Optional 的 throwing 调用」
    /// 会扁平化——guard 解包后 row 已是非可选 DocumentRow，不得再可选链。
    func sensitivity(documentID: UUID) async -> Bool? {
        guard let row = try? await store.fetch(id: documentID) else { return nil }   // try?-ok: 读失败按未知
        return row.isSensitive
    }

    /// 逐条「敏感」开关（2026-10-28 业主；默认开=仅内部保存）。
    /// 转敏感：删用户面副本 + tombstone；转非敏感（关）：开关即显式选择，
    /// 立即导出副本（不受全局自动镜像开关限制）；两者都只改本记录。
    @discardableResult
    func setRecordSensitive(documentID: UUID, sensitive: Bool,
                            conversationID: UUID?, conversationTitle: String?) async -> ExportFailure? {
        guard let row = try? await store.fetch(id: documentID) else { return .notFound }   // try?-ok: 读失败按 notFound
        do {
            try await store.setSensitive(id: documentID, patientId: row.patientId, sensitive: sensitive)
        } catch {
            return .writeFailed
        }
        if sensitive {
            await mirror.removeCopy(documentID: documentID)
            // 在途自动导出（导入收尾 allowSensitive:false 路径）可能已取到旧的
            // isSensitive=false 行，正卡在 mirror 内写副本——上面这次删除会先执行，
            // 副本随后重新落盘并 upsert 回 active（BR-007 对外边界竞态）。
            // 等该文档导出退出在途集合后再删一次；最多等约 2 秒，不无限阻塞。
            var waited = false
            for _ in 0..<40 where exportingDocumentIds.contains(documentID) {
                try? await Task.sleep(nanoseconds: 50_000_000)   // try?-ok: 取消时立即重试删除
                waited = true
            }
            if waited {
                await mirror.removeCopy(documentID: documentID)
            }
            return nil
        }
        return await exportCopy(documentID: documentID, conversationID: conversationID,
                                conversationTitle: conversationTitle, allowSensitive: true)
    }

    /// 清空全部数据级联：删副本树 + 擦账本（canonical 由媒体链负责）。
    func wipeAll() async {
        await mirror.wipeAllCopies()
        driftCount = 0
        conversationDirectories.removeAll()
    }

    // MARK: - 组装

    private func job(for row: DocumentStore.DocumentRow,
                     conversationID: UUID?,
                     conversationTitle: String?, now: Date) async throws -> DocumentExportMirror.ExportJob {
        let meta = (row.metaJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any])   // try?-ok: meta 损坏按缺路径处理
        guard let sourcePath = meta?["original_path"] as? String, !sourcePath.isEmpty else {
            throw DocumentExportMirror.MirrorError.sourceUnreadable("missing original_path")
        }
        let directory: String
        if let existing = await ledger.record(documentID: row.id)?.directoryName, !existing.isEmpty {
            directory = existing                        // D5：目录名首次导出即冻结
            if let conversationID { conversationDirectories[conversationID] = existing }
        } else if let conversationID {
            // 同一会话内后续资料复用首条资料的会话目录（日期前缀不随导入次数漂移）。
            // 内存缓存先命中；冷启动首份才回落账本扫描。
            if let cached = conversationDirectories[conversationID] {
                directory = cached
            } else if let existingConversation = await ledger.records(conversationID: conversationID)
                .first(where: { !$0.directoryName.isEmpty })?.directoryName {
                conversationDirectories[conversationID] = existingConversation
                directory = existingConversation
            } else {
                directory = DocumentExportNaming.directoryName(
                    conversationTitle: conversationTitle,
                    conversationID: conversationID,
                    datePrefix: Self.timestampText(now))
                conversationDirectories[conversationID] = directory
            }
        } else {
            // 直接导入归档到「直接导入-YYYY-MM」月桶（不按文档分目录：
            // 资料库入口无会话语义，目录名冻结规则只属于会话）。
            directory = DocumentExportNaming.directImportDirectory(
                monthText: Self.monthText(now))
        }
        let request = DocumentExportNaming.Request(
            preferredTitle: row.title,
            preferredTitleSource: .auto,
            fields: [],
            cardKind: row.docTypeKey,
            dayText: Self.dayText(row.createdAt),
            documentID: row.id,
            fileExtension: Self.fileExtension(forMime: row.mimeType))
        return DocumentExportMirror.ExportJob(
            documentID: row.id, conversationID: conversationID,
            directoryName: directory, nameRequest: request,
            sourcePath: sourcePath, isSensitive: row.isSensitive)
    }

    static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func monthText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    /// 会话目录日期时间前缀（业主 2026-10-30：「文件」App 按时间排序）。
    /// 首次导出即冻结（D5），设备时区本地时间。
    static func timestampText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: date)
    }

    /// MIME → 扩展名白名单（未知 → nil，绝不猜）。
    static func fileExtension(forMime mime: String?) -> String? {
        switch mime?.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/heic", "image/heif": return "heic"
        case "application/pdf": return "pdf"
        default: return nil
        }
    }
}
