import Foundation
import Combine
import SwiftUI

/// 聊天导入的「待提交」纯值模型（2026-11-01 业主：拍摄/选文件后不立刻回聊天，
/// 可继续追加、缩略图待提交，最后统一提交）。
///
/// 纪律：
/// - 不占 `DocumentsState.ImportSession`（全局单槽只在提交时才占用）；
/// - 只保存压缩字节（图片 JPEG / PDF Data）与轻量元数据，不持有全分辨率 `UIImage`；
/// - 上限硬拒绝，不静默截断；
/// - 排序就是提交顺序；合并器按此顺序生成页偏移。
final class ChatImportStagingModel: ObservableObject {
    /// 采集来源：提交后映射到聊天气泡的来源图标（拍照/相册/文件）。
    enum Source: String, Equatable {
        case camera
        case photoLibrary
        case fileImport
    }

    struct Item: Identifiable, Equatable {
        let id: UUID
        var filename: String
        var data: Data
        var isPDF: Bool
        var pageCount: Int
        var source: Source
        /// 内容修订号：预览页旋转回写后驱动缩略图重绘（Data 本身不参与 id 计算）。
        var revision: UUID

        init(id: UUID = UUID(), filename: String, data: Data, isPDF: Bool,
             pageCount: Int, source: Source) {
            self.id = id
            self.filename = filename
            self.data = data
            self.isPDF = isPDF
            self.pageCount = max(1, pageCount)
            self.source = source
            self.revision = UUID()
        }
    }

    enum AddResult: Equatable {
        case added
        case tooManyItems
        case tooManyPages
        case tooLarge
        case empty
    }

    /// 纯内存上限（安全席 2026-11-01；mock `chat-import-staging.html` 口径）：
    /// 条目数 / 总页数 / 总字节。超限拒绝，不静默截断。
    static let maxItems = 20
    static let maxPages = 20
    static let maxBytes = 64 * 1024 * 1024

    @Published private(set) var items: [Item] = []
    /// 初始选择超限或读取失败时，由聊天页写入；待提交页出现即弹一次可读提示。
    @Published var notice: String?

    var totalPages: Int { items.reduce(0) { $0 + $1.pageCount } }
    var totalBytes: Int { items.reduce(0) { $0 + $1.data.count } }
    var isEmpty: Bool { items.isEmpty }
    var canSubmit: Bool { !items.isEmpty && totalPages <= Self.maxPages && totalBytes <= Self.maxBytes }

    @discardableResult
    func add(data: Data, filename: String, isPDF: Bool, pageCount: Int,
             source: Source) -> AddResult {
        guard !data.isEmpty else { return .empty }
        guard items.count < Self.maxItems else { return .tooManyItems }
        guard totalPages + max(1, pageCount) <= Self.maxPages else { return .tooManyPages }
        guard totalBytes + data.count <= Self.maxBytes else { return .tooLarge }
        items.append(Item(filename: filename, data: data, isPDF: isPDF,
                          pageCount: pageCount, source: source))
        return .added
    }

    /// 预览页旋转后回写同一项；页数不变。回写后总字节仍受硬上限约束。
    @discardableResult
    func replace(id: UUID, data: Data) -> AddResult {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return .empty }
        guard !data.isEmpty else { return .empty }
        let otherBytes = totalBytes - items[index].data.count
        guard otherBytes + data.count <= Self.maxBytes else { return .tooLarge }
        items[index].data = data
        items[index].revision = UUID()
        return .added
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    func move(from: IndexSet, to: Int) {
        items.move(fromOffsets: from, toOffset: to)
    }

    func moveUp(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), index > 0 else { return }
        items.swapAt(index, index - 1)
    }

    func moveDown(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), index + 1 < items.count else { return }
        items.swapAt(index, index + 1)
    }

    func clear() { items.removeAll() }
}
