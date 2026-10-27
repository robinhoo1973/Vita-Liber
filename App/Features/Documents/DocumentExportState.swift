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

    init(store: DocumentStore, ledger: DocumentExportStore, mirror: DocumentExportMirror) {
        self.store = store
        self.ledger = ledger
        self.mirror = mirror
    }

    /// 逐项显式导出（菜单点击即显式选择；敏感件调用方须显式传 allowSensitive）。
    @discardableResult
    func exportCopy(documentID: UUID, conversationID: UUID?, conversationTitle: String?,
                    allowSensitive: Bool) async -> ExportFailure? {
        guard !exportingDocumentIds.contains(documentID) else { return nil }
        exportingDocumentIds.insert(documentID)
        defer { exportingDocumentIds.remove(documentID) }
        guard let row = try? await store.fetch(id: documentID) else {   // try?-ok: 读失败按 notFound
            return .notFound
        }
        do {
            _ = try await mirror.export(try await job(for: row, conversationID: conversationID,
                                                      conversationTitle: conversationTitle),
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

    /// 启动/回前台对账（幂等；只置 tombstone，绝不回删 canonical）。
    func reconcile() async {
        driftCount = await mirror.reconcile()
    }

    /// 移除跟踪（用户对 missing 副本的显式处理）：只删账本行，不碰 canonical。
    func removeTracking(documentID: UUID) async {
        try? await ledger.setState(documentID: documentID, state: "removed")   // try?-ok: 尽力而为
        if driftCount > 0 { driftCount -= 1 }
    }

    /// 清空全部数据级联：删副本树 + 擦账本（canonical 由媒体链负责）。
    func wipeAll() async {
        await mirror.wipeAllCopies()
        driftCount = 0
    }

    // MARK: - 组装

    private func job(for row: DocumentStore.DocumentRow,
                     conversationID: UUID?,
                     conversationTitle: String?) async throws -> DocumentExportMirror.ExportJob {
        let meta = (row.metaJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any])   // try?-ok: meta 损坏按缺路径处理
        guard let sourcePath = meta?["original_path"] as? String, !sourcePath.isEmpty else {
            throw DocumentExportMirror.MirrorError.sourceUnreadable("missing original_path")
        }
        let directory: String
        if let existing = await ledger.record(documentID: row.id)?.directoryName, !existing.isEmpty {
            directory = existing                        // D5：目录名首次导出即冻结
        } else if let conversationID {
            directory = DocumentExportNaming.directoryName(conversationTitle: conversationTitle,
                                                           conversationID: conversationID)
        } else {
            directory = DocumentExportNaming.directoryName(
                conversationTitle: Self.directImportDirectory(now: Date()),
                conversationID: row.id)
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

    static func directImportDirectory(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return "直接导入-" + formatter.string(from: now)
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
