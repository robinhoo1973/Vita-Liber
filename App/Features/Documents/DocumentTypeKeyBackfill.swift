import Foundation
import Domain
import Infrastructure

/// FR5.5 / v27（子项目 J · 原 D3-2）：`document_file.doc_type_key` 首启一次性回填——迁移 v27 无代码回填
///（`SchemaMigrations` v27 注释：「doc_type_key 由 App 层首启任务反查三语标签」），由 App 层把旧行的本地化标签
/// `doc_type` 反查为稳定键：当前语言 27 键精确匹配 → 旧 15 标签键 / 曾用键三语反查（`L10n.legacyDocTypeLabelKey`）
/// → `DocumentTypeKey(legacyLabelKey:)`；未命中 → `custom`（不猜）。
///
/// 结构：纯解析 `resolve(label:)` + 幂等编排 `runIfNeeded`（读/写经注入闭包；成功完成才置 UserDefaults 完成标记，
/// 任一行失败不置标记、下次启动重试；`pending` 只返回 `doc_type_key IS NULL` 的行 = 幂等，已写行不会再被列出）。
///
/// 接线（J4 follow-up）：读面 `DocumentStore.documentsMissingTypeKey(patientId: nil, limit:)`（全成员）+ 写面
/// `DocumentStore.setDocTypeKey(_:documentId:patientId:)`（成员校验、未知键拒绝），经 `runIfNeeded(store:)` 绑定；
/// 启动链唯一调用点 = `VitaLiberApp.mainRoot` 的幂等种子闭包。App 层仍不 import GRDB（只经 Infrastructure 出口）。
/// 新入库文档在 `DocumentsState.commitDraft` / `createManual` 处即带键落库（不进回填清单）。
enum DocumentTypeKeyBackfill {
    /// 完成标记（版本化：再次改分类学时换键重跑）。
    static let doneKey = "docTypeKey.backfill.v27.done"

    struct Row: Equatable, Sendable {
        let id: UUID
        let patientId: UUID
        let docType: String
        init(id: UUID, patientId: UUID, docType: String) { self.id = id; self.patientId = patientId; self.docType = docType }
    }

    enum Outcome: Equatable {
        /// 已回填过（完成标记在），零访问。
        case alreadyDone
        /// 本次回填成功的行数（含 0），完成标记已置。
        case completed(Int)
        /// 读取或某行写入失败：已写 n 行，未置完成标记（下次重试；已写行因 `IS NULL` 谓词不会重写）。
        case failed(written: Int)
    }

    /// 标签 → 稳定键（任一支持语言的历史标签）；未命中 `custom`。
    static func resolve(label: String) -> DocumentTypeKey {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .custom }
        if let raw = DocumentsState.docTypeKey(forLabel: trimmed), let key = DocumentTypeKey(rawValue: raw) { return key }
        if let key = DocumentTypeKey(legacyLabelKey: trimmed) { return key }   // 旧行直接存了键（备份恢复等路径）
        return .custom
    }

    /// 幂等编排：`pending` 返回 `doc_type_key IS NULL` 的行；`apply(id, patientId, key)` 写单行（成功即该行离开 `pending` 集）。
    /// `batchLimit` 非 nil = `pending` 每批最多返回该数：整批写成功后再取下一批，直至返回不足一批（谓词收缩保证终止；
    /// 因此 `apply` 成功必须真正写键——真实仓 `setDocTypeKey` 零行即抛，满足此契约）；nil = 单次取全（注入闭包测试形态）。
    /// 主线程编排（启动 `.task` 调用点即主线程；闭包不跨隔离传递）。
    @MainActor
    @discardableResult
    static func runIfNeeded(defaults: UserDefaults = .standard,
                            batchLimit: Int? = nil,
                            pending: () async throws -> [Row],
                            apply: (UUID, UUID, DocumentTypeKey) async throws -> Void) async -> Outcome {
        guard !defaults.bool(forKey: doneKey) else { return .alreadyDone }
        var written = 0
        var previousBatch: [UUID] = []
        do {
            while true {
                let rows = try await pending()
                let ids = rows.map(\.id)
                // 分批契约守卫：整批写成功后同一批再次出现 = `apply` 没让行离开 `IS NULL` 集——
                // 宁记失败（下次启动重试）不在启动链主线程自旋
                guard rows.isEmpty || ids != previousBatch else { throw NoProgress() }
                previousBatch = ids
                for row in rows {
                    try await apply(row.id, row.patientId, resolve(label: row.docType))
                    written += 1
                }
                guard let batchLimit, batchLimit > 0, rows.count >= batchLimit else { break }
            }
            defaults.set(true, forKey: doneKey)
            return .completed(written)
        } catch {
            return .failed(written: written)
        }
    }

    private struct NoProgress: Error {}

    /// 真实仓绑定（启动链唯一调用点 `VitaLiberApp.mainRoot`）：全成员缺键行分批（`batchLimit`）反查写回。
    /// 归档行同样回填；已删除成员的文档由读面排除（写面必拒，否则回填永不完成）。
    @MainActor
    @discardableResult
    static func runIfNeeded(store: DocumentStore, defaults: UserDefaults = .standard,
                            batchLimit: Int = 500) async -> Outcome {
        await runIfNeeded(defaults: defaults, batchLimit: batchLimit,
            pending: {
                try await store.documentsMissingTypeKey(patientId: nil, limit: batchLimit)
                    .map { Row(id: $0.id, patientId: $0.patientId, docType: $0.docType) }
            },
            apply: { id, patientId, key in
                try await store.setDocTypeKey(key.rawValue, documentId: id, patientId: patientId)
            })
    }
}
