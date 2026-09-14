import Foundation
import Domain

/// FR5.5 / v27（子项目 J · 原 D3-2）：`document_file.doc_type_key` 首启一次性回填——迁移 v27 无代码回填
///（`SchemaMigrations` v27 注释：「doc_type_key 由 App 层首启任务反查三语标签」），由 App 层把旧行的本地化标签
/// `doc_type` 反查为稳定键：当前语言 27 键精确匹配 → 旧 15 标签键 / 曾用键三语反查（`L10n.legacyDocTypeLabelKey`）
/// → `DocumentTypeKey(legacyLabelKey:)`；未命中 → `custom`（不猜）。
///
/// 结构：纯解析 `resolve(label:)` + 幂等编排 `runIfNeeded`（读/写经注入闭包；成功完成才置 UserDefaults 完成标记，
/// 任一行失败不置标记、下次启动重试；`apply` 只针对 `doc_type_key IS NULL` 的行 = 幂等）。
///
/// 接线：Infrastructure 目前没有 `doc_type_key` 的读/写出口（`DocumentStore.DocumentRow` 不携带该列、无 setter），
/// 且 App 层按分层纪律不 import GRDB——启动 `.task` 接线待 `DocumentStore.documentsMissingTypeKey(limit:)` /
/// `setDocTypeKey(id:patientId:key:)` 落地后补一行调用（本类型的闭包签名即其契约）。
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

    /// 幂等编排：`pending` 返回 `doc_type_key IS NULL` 的行；`apply(id, patientId, key)` 写单行（须带 `AND doc_type_key IS NULL`）。
    /// 主线程编排（启动 `.task` 调用点即主线程；闭包不跨隔离传递）。
    @MainActor
    @discardableResult
    static func runIfNeeded(defaults: UserDefaults = .standard,
                            pending: () async throws -> [Row],
                            apply: (UUID, UUID, DocumentTypeKey) async throws -> Void) async -> Outcome {
        guard !defaults.bool(forKey: doneKey) else { return .alreadyDone }
        var written = 0
        do {
            for row in try await pending() {
                try await apply(row.id, row.patientId, resolve(label: row.docType))
                written += 1
            }
            defaults.set(true, forKey: doneKey)
            return .completed(written)
        } catch {
            return .failed(written: written)
        }
    }
}
